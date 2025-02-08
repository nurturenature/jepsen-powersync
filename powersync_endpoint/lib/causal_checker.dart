import 'log.dart';

/// Check a key/value, Max Write Wins, database
class CausalChecker {
  late final int _numClients;
  late final int _numKeys;
  late Map<int, List<int>> _clientStates; // map of  fixed lists
  late Map<(int, int), List<int>> _mwWfrStates; // map of fixed lists

  CausalChecker(this._numClients, this._numKeys) {
    _clientStates = {};
    for (var clientNum = 1; clientNum <= _numClients; clientNum++) {
      _clientStates
          .addEntries([MapEntry(clientNum, List.filled(_numKeys, -1))]);
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
      'clientNum': int clientNum
    } = op;

    // must be an op of interest
    if (type != 'ok' || f != 'txn' || value.isEmpty || table != 'mww') {
      throw StateError('Invalid request to check op: $op');
    }

    // act on each mop, read/write, in value
    for (final {'f': String f, 'k': int k, 'v': int v} in value) {
      switch (f) {
        case 'r':
          // must read a null, -1, or a value that was written
          if (v != -1 && _mwWfrStates[(k, v)] == null) {
            _debug();
            log.severe(
                'reading a k/v: $k/$v that was never written in op: $op');
            return false;
          }

          // monotonic reads, monotonic writes, read your writes, writes follow reads
          //   - read value must be >= prev value
          if (v < _clientStates[clientNum]![k]) {
            _debug();
            log.severe(
                'value of read k/v: $k/$v is less than expected value: ${_clientStates[clientNum]![k]} in op: $op');
            return false;
          } else {
            // update client state with current read value
            _clientStates[clientNum]![k] = v;
          }

          // reading a null, -1, is a no-op
          if (v == -1) break;

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
          break;

        case 'append':
          // writes must be unique
          if (_mwWfrStates[(k, v)] != null) {
            _debug();
            log.severe(
                'writing a k/v: $k/$v that was already written in op: $op');
            return false;
          }

          // monotonic reads, monotonic writes, read your writes, writes follow reads
          //   - write value must be > prev value
          if (v <= _clientStates[clientNum]![k]) {
            _debug();
            log.severe(
                'value of write: $v is less than or equal previous value: ${_clientStates[clientNum]![k]} in op: $op');
            return false;
          } else {
            // update client state with current write value
            _clientStates[clientNum]![k] = v;
          }

          // monotonic writes, read your writes, writes follow reads
          //   - any future reads of this write must also include all of current client state
          //   - store current client state for this write
          _mwWfrStates[(k, v)] =
              List.from(_clientStates[clientNum]!, growable: false);
          break;

        default:
          throw StateError('Invalid f: $f, in value: $value, in op: $op');
      }
    }

    return true;
  }

  void _debug() {
    log.info('causal client states:');
    for (var clientNum = 1; clientNum <= _numClients; clientNum++) {
      log.info('\t$clientNum: ${_clientStates[clientNum]}');
    }

    log.info('causal mr/wfr states:');
    for (final kv in _mwWfrStates.keys) {
      log.info('\t$kv: ${_mwWfrStates[kv]}');
    }
  }
}
