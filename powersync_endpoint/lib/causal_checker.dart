import 'log.dart';

/// Check a key/value, Max Write Wins, database
class CausalChecker {
  late final int _numClients;
  late final int _numKeys;
  late Map<int, List<int>> _clientStates; // map of  fixed lists
  late Map<(int, int), List<int>> _mwWfrStates; // map of fixed lists

  CausalChecker(this._numClients, this._numKeys) {
    _clientStates = {};
    // clientNum 0 reserved for pseudo client PG
    for (var clientNum = 0; clientNum <= _numClients; clientNum++) {
      _clientStates.addEntries([
        MapEntry(clientNum, List.filled(_numKeys, -1)),
      ]);
    }
    _mwWfrStates = {};
  }

  // check if op has valid reads/writes
  bool checkOp(Map<String, dynamic> op) {
    final {
      'type': String type,
      'f': String f,
      'value': List<Map<String, dynamic>> value,
      'table': String table,
      'clientType': String clientType,
      'clientNum': int clientNum,
    } = op;

    // ok for PostgreSQL, clientType pg, to have an error op, e.g. concurrent access
    // if so, it's a no-op re updating any state
    if (clientType == 'pg' && type == 'error') {
      log.info('CausalChecker ignoring PostgreSQL error op: $op');
      return true;
    }

    // must be an op of interest
    if (type != 'ok' || f != 'txn' || value.isEmpty || table != 'mww') {
      throw StateError('Invalid request to check op: $op');
    }

    // act on each mop, read/write, in value
    for (final {'f': String f, 'v': dynamic v} in value) {
      switch (f) {
        case 'read-all':
          // check each read k/v in mop['v'] map
          for (final kv in v.entries) {
            if (!_checkSingleRead(clientNum, kv.key, kv.value, op)) {
              return false;
            }
          }
          break;

        case 'write-some':
          // check each k/v written
          for (final MapEntry kv in v.entries) {
            if (!_checkSingleWrite(clientNum, kv.key, kv.value, op)) {
              return false;
            }
          }
          break;

        default:
          throw StateError('Invalid f: $f, in value: $value, in op: $op');
      }
    }

    return true;
  }

  bool _checkSingleRead(int clientNum, int k, int v, Map<String, dynamic> op) {
    // must read a null, -1, or a value that was written
    if (v != -1 && _mwWfrStates[(k, v)] == null) {
      debug(k, [v]);
      log.severe('{k: $k, v: $v} was never written, yet reading it in op: $op');
      return false;
    }

    // monotonic reads, monotonic writes, read your writes, writes follow reads
    //   - read value must be >= prev value
    if (v < _clientStates[clientNum]![k]) {
      debug(k, [v, _clientStates[clientNum]![k]]);
      log.severe(
        'read of {k: $k, v: $v} is less than expected read of {k: $k, v: ${_clientStates[clientNum]![k]}} in op: $op',
      );
      return false;
    } else {
      // update client state with current read value
      _clientStates[clientNum]![k] = v;
    }

    // reading a null, -1, is a no-op
    if (v == -1) {
      return true;
    }

    // monotonic writes, writes follow reads
    //   - clients now have to read at least the state at the time of the write that was read
    //   - update client state
    //     - with state at time of write that was read
    //     - if mr/wfr state > client state
    for (var onK = 0; onK < _numKeys; onK++) {
      if (_clientStates[clientNum]![onK] < _mwWfrStates[(k, v)]![onK]) {
        _clientStates[clientNum]![onK] = _mwWfrStates[(k, v)]![onK];
      }
    }

    return true;
  }

  bool _checkSingleWrite(int clientNum, int k, int v, Map<String, dynamic> op) {
    // writes must be unique
    if (_mwWfrStates[(k, v)] != null) {
      debug(k, [v]);
      log.severe(
        '{k: $k, v: $v} was already written yet trying to write it in op: $op',
      );
      return false;
    }

    // monotonic reads, monotonic writes, read your writes, writes follow reads
    //   - write value must be > prev value
    if (v <= _clientStates[clientNum]![k]) {
      debug(k, [v, _clientStates[clientNum]![k]]);
      log.severe(
        'write of {k: $k, v: $v} is less than or equal to previous write of {k: $k, v: ${_clientStates[clientNum]![k]}} in op: $op',
      );
      return false;
    } else {
      // update client state with current write value
      _clientStates[clientNum]![k] = v;
    }

    // monotonic writes, read your writes, writes follow reads
    //   - any future reads of this write must also include all of current client state
    //   - store current client state for this write
    _mwWfrStates[(k, v)] = List.from(
      _clientStates[clientNum]!,
      growable: false,
    );

    return true;
  }

  void debug(int k, Iterable<int> vs) {
    log.info('CausalChecker client states:');
    for (var clientNum = 0; clientNum <= _numClients; clientNum++) {
      log.info('\tclient $clientNum: ${_clientStates[clientNum]}');
    }

    log.info('CausalChecker Monotonic Read/Write Follows Reads states:');
    for (final v in vs) {
      log.info('\t{k: $k, v: $v}: ${_mwWfrStates[(k, v)]}');
    }
  }
}
