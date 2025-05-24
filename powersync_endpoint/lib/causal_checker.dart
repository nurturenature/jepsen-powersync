import 'dart:collection';
import 'package:synchronized/synchronized.dart';
import 'endpoint.dart';
import 'errors.dart';
import 'log.dart';
import 'pg_endpoint.dart';
import 'worker.dart';

// TODO: add a possible writes state
//  - txn requests may be interrupted by a nemesis before the txn response is sent or received
//  - check/maintain state as part of checking for the read of an unwritten value

// serialize access to preserve integrity of checks
// e.g. multiple independent mutations would be a problem
final _lock = Lock();

// reasons why a clientState[key] value is what it is
enum _Reasons {
  initialValue,
  myPreviousRead,
  myPreviousWrite,
  writesFollowsRead,
}

/// Check a key/value, Max Write Wins, database
class CausalChecker {
  late final int _numClients;
  late final int _numKeys;
  final Map<int, List<int>> _clientStates = {};
  final Map<int, List<_Reasons>> _clientReasons = {};
  final Map<(int, int), List<int>> _mwWfrStates = {};

  CausalChecker(this._numClients, this._numKeys) {
    // clientNum 0 reserved for pseudo client PG
    for (var clientNum = 0; clientNum <= _numClients; clientNum++) {
      _clientStates.addEntries([
        MapEntry(clientNum, List.filled(_numKeys, -1)),
      ]);
      _clientReasons.addEntries([
        MapEntry(clientNum, List.filled(_numKeys, _Reasons.initialValue)),
      ]);
    }
  }

  /// Check if op has valid reads/writes.
  /// Update client and mw/wfr state.
  Future<bool> checkOp(Map<String, dynamic> op) async {
    return await _lock.synchronized<bool>(() {
      final {
        'type': String type,
        'f': String f,
        'value': List<Map<String, dynamic>> value,
        'clientType': String clientType,
        'clientNum': int clientNum,
      } = op;

      final clientState = _clientStates[clientNum]!;
      final clientReasons = _clientReasons[clientNum]!;

      // ok for PostgreSQL, clientType pg, to have an fail op, e.g. concurrent access
      if (clientType == 'pg' && type == 'fail') {
        log.info('CausalChecker: ignoring PostgreSQL fail op: $op');
        return true;
      }

      // must be an op of interest
      if (type != 'ok' || f != 'txn' || value.isEmpty) {
        throw StateError('Invalid request to check op: $op');
      }

      // act on each mop, read/write, in value
      for (final mop in value) {
        final f = sqlTransactionLookup[mop['f']]!;
        switch (f) {
          case SQLTransactions.readAll:
            final reads = mop['v'] as Map<int, int>;

            // transactions are atomic and repeatable read
            //   - update client state with mw/wfr state for all reads
            //   - before checking individual reads
            _updateClientStateWithReadMwWfrState(
              clientState,
              clientReasons,
              reads,
            );

            // check each read k/v
            for (final kv in reads.entries) {
              if (!_checkSingleRead(
                clientState,
                clientReasons,
                kv.key,
                kv.value,
                op,
              )) {
                return false;
              }

              // update client state with current read value
              clientState[kv.key] = kv.value;
              clientReasons[kv.key] = _Reasons.myPreviousRead;
            }

            break;

          case SQLTransactions.writeSome:
            final writes = mop['v'] as Map<int, int>;

            // check each write k/v
            for (final kv in writes.entries) {
              if (!_checkSingleWrite(
                clientState,
                clientReasons,
                kv.key,
                kv.value,
                op,
              )) {
                return false;
              }
            }

            // update state to include these writes
            _updateClientAndMwWfrStatesWithClientWrites(
              clientState,
              clientReasons,
              writes,
            );

            break;
        }
      }

      return true;
    });
  }

  // only checks, does not update state
  bool _checkSingleRead(
    List<int> clientState,
    List<_Reasons> clientReasons,
    int k,
    int v,
    Map<String, dynamic> op,
  ) {
    // must read a null, -1, or a value that was written
    if (v != -1 && !_mwWfrStates.containsKey((k, v))) {
      log.severe('{$k: $v} was never written, yet reading it in op: $op');
      _debug(k, [v]);
      return false;
    }

    // monotonic reads, monotonic writes, read your writes, writes follow reads
    //   - read value must be >= prev value
    if (v < clientState[k]) {
      log.severe(
        'read of {$k: $v} is less than expected read of {$k: ${clientState[k]}}, expected because ${clientReasons[k].name}, in op: $op',
      );
      _debug(k, [v, clientState[k]]);
      return false;
    }

    return true;
  }

  // only checks, does not update state
  bool _checkSingleWrite(
    List<int> clientState,
    List<_Reasons> clientReasons,
    int k,
    int v,
    Map<String, dynamic> op,
  ) {
    // writes must be unique
    if (_mwWfrStates.containsKey((k, v))) {
      log.severe(
        '{$k: $v} was already written yet trying to write it in op: $op',
      );
      _debug(k, [v]);
      return false;
    }

    // monotonic reads, monotonic writes, read your writes, writes follow reads
    //   - write value must be > prev value
    if (v <= clientState[k]) {
      log.severe(
        'write of {$k: $v} is less than or equal to previous client state of {$k: ${clientState[k]}}, previous state due to ${clientReasons[k]}, in op: $op',
      );
      _debug(k, [v, clientState[k]]);
      return false;
    }

    return true;
  }

  // transactions are atomic and repeatable read
  //   - so the mw/wfr state for each read must be reflected in the entire transaction
  //   - so add mw/wfr state for all the reads to the client state
  // only updates, does not check state for errors
  void _updateClientStateWithReadMwWfrState(
    List<int> clientState,
    List<_Reasons> clientReasons,
    Map<int, int> reads,
  ) {
    for (final readKv in reads.entries) {
      // a null, -1, read is a no-op
      if (readKv.value == -1) {
        continue;
      }

      final mwWfrState = _mwWfrStates[(readKv.key, readKv.value)];

      // read an unwritten value?
      if (mwWfrState == null) {
        continue;
      }

      // test each mw/wfr value for this read against the client
      for (var k = 0; k < _numKeys; k++) {
        if (mwWfrState[k] > clientState[k]) {
          clientState[k] = mwWfrState[k];
          clientReasons[k] = _Reasons.writesFollowsRead;
        }
      }
    }
  }

  // monotonic writes, read your writes, writes follow reads
  //   - any future reads of this write must also include all of current client state
  //   - update and store current client state for this write
  // only updates, does not check state for errors
  void _updateClientAndMwWfrStatesWithClientWrites(
    List<int> clientState,
    List<_Reasons> clientReasons,
    Map<int, int> writes,
  ) {
    // transactions are atomic
    //   - so update client state with all writes
    //   - before updating mw/wfr states
    for (final writeKv in writes.entries) {
      clientState[writeKv.key] = writeKv.value;
      clientReasons[writeKv.key] = _Reasons.myPreviousWrite;
    }

    // all mw/wfr for these writes have the same immutable client state
    final List<int> newClientState = List.unmodifiable(clientState);

    // update mw/wfr states
    for (final writeKv in writes.entries) {
      _mwWfrStates[(writeKv.key, writeKv.value)] = newClientState;
    }
  }

  // log clients that have {k: v} in their state
  // log mw/wfr states that were a {k: v} write
  // log at severe level as only used when Causal Consistency violation
  void _debug(int k, Iterable<int> vs) {
    log.severe('CausalChecker client states with {$k: $vs}:');
    for (var clientNum = 0; clientNum <= _numClients; clientNum++) {
      // only log client if its state for k is in vs
      final v = _clientStates[clientNum]![k];
      if (vs.contains(v)) {
        log.severe(
          '\t{$k: $v}: in client $clientNum: reason: ${_clientReasons[clientNum]![k].name}',
        );
      }
    }

    log.severe('CausalChecker Monotonic Read/Write Follows Reads states:');
    for (final v in vs) {
      log.severe('\t{$k: $v}: written when: ${_mwWfrStates[(k, v)]}');
    }
  }
}

/// Do a final read of all keys on PostgreSQL and all clients.
/// Treat PostgreSQL as the source of truth and look for differences with each client.
/// Any differences are errors.
Future<void> checkStrongConvergence(Set<Worker> clients) async {
  // use our own independent PostgreSQL connection to make a final read
  final pg = PGEndpoint();
  await pg.init();
  final Map<int, int> finalPgRead =
      (await pg.dbApi(Endpoint.selectAllMessage()))['value']['v']
          as Map<int, int>;
  await pg.dbApi(Endpoint.closeMessage());

  // build a divergent map:
  // {pg:   {k: v}   k/v for any diffs in any ps-#
  //  ps-#: {k: v}}  k/v for this ps-# diff than pg
  final Map<String, Map<int, int>> divergent = SplayTreeMap();

  for (Worker client in clients) {
    final Map<int, int> finalPsRead =
        (await client.executeApi(Endpoint.selectAllMessage()))['value']['v'];
    for (final int k in finalPgRead.keys) {
      final pgV = finalPgRead[k]!;
      final psV = finalPsRead[k]!;
      if (pgV != psV) {
        divergent.update('pg', (inner) {
          inner.addAll({k: pgV});
          return inner;
        }, ifAbsent: () => SplayTreeMap.from({k: pgV}));
        divergent.update('ps-${client.clientNum}', (inner) {
          inner.addAll({k: psV});
          return inner;
        }, ifAbsent: () => SplayTreeMap.from({k: psV}));
      }
    }
  }

  if (divergent.isEmpty) {
    log.info('Strong Convergence on final reads! :)');
  } else {
    log.severe('Divergent final reads!:');
    final pgKv = divergent.remove('pg');
    log.severe('PostgreSQL {k: v} for client diversions:');
    log.severe('pg: $pgKv');
    for (final client in divergent.entries) {
      log.severe('${client.key} {k: v} that diverged from PostgreSQL');
      log.severe('${client.key} ${client.value}');
    }
    log.severe(':(');
    errorExit(ErrorReasons.strongConvergence);
  }
}
