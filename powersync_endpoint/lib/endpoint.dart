import 'dart:collection';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync/sqlite3.dart' as sqlite3;
import 'args.dart';
import 'postgresql.dart' as pg;

final _rng = Random();

abstract class Endpoint {
  /// Execute an sql transaction and return the results:
  /// - request is a Jepsen op value as a Map
  ///   - transaction maps are in value: [{f: r | append, k: key, v: value}...]
  /// - response is an updated Jepsen op value with the txn results
  ///
  /// No Exceptions are expected!
  /// Single user local PowerSync is totally available, strict serializable.
  /// No catching, let Exceptions fail the test
  Future<Map> sqlTxn(Map op);

  /// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
  Future<Map> powersyncApi(Map op);

  /// returns a transaction message that:
  ///   - reads all key/values
  ///   - writes `value` to `count` random keys
  SplayTreeMap<String, dynamic> readAllWriteSomeTxnMessage(
    int count,
    int value,
  ) {
    // placeholder Map for correct typing
    final Map<int, int> reads = {};

    // {k: v} map of k/v to write
    final writes = Map.fromEntries(
      allKeys.getRandom(count).map((k) => MapEntry(k, value)),
    );

    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'txn',
      'value': [
        {'f': 'read-all', 'k': -1, 'v': reads},
        {'f': 'write-some', 'k': -1, 'v': writes},
      ],
      'table': pg.Tables.mww.name,
    });
  }

  Map<String, dynamic> rndTxnMessage(pg.Tables table, int count) {
    return Map.of({
      'type': 'invoke',
      'f': 'txn',
      'value': _genRandTxn(args['maxTxnLen'], count),
      'table': table.name,
    });
  }

  List<Map> _genRandTxn(int num, int value) {
    final List<Map<String, dynamic>> txn = [];
    final Set<int> appendedKeys = {};

    for (var i = 0; i < num; i++) {
      final f = ['r', 'append'].getRandom(1).first;
      final k = _rng.nextInt(args['keys']);
      switch (f) {
        case 'r':
          txn.add({'f': 'r', 'k': k, 'v': null});
          break;
        // only append to a key once
        case 'append' when !appendedKeys.contains(k):
          appendedKeys.add(k);
          txn.add({'f': 'append', 'k': k, 'v': value});
          break;
        // duplicate append key so read it instead
        default:
          txn.add({'f': 'r', 'k': k, 'v': null});
          break;
      }
    }

    return txn;
  }

  Map<String, dynamic> connectMessage() {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'connect', 'v': {}},
    });
  }

  Map<String, dynamic> disconnectMessage() {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'disconnect', 'v': {}},
    });
  }

  SplayTreeMap<String, dynamic> closeMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'close', 'v': {}},
    });
  }

  static Map<String, dynamic> selectAllMessage(pg.Tables table) {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'select-all', 'k': table.name, 'v': <sqlite3.Row>{}},
      'table': table.name,
    });
  }

  Map<String, dynamic> selectAllResultToOpResult(Map<String, dynamic> op) {
    final Iterable<Map<String, dynamic>> value = (op['value']['v']
            as Map<int, int>)
        .entries
        .map((MapEntry<int, int> kv) {
          return {'f': 'r', 'k': kv.key, 'v': kv.value};
        });

    op['f'] = 'txn';
    op['value'] = value.toList(growable: false);

    return op;
  }

  Map<String, dynamic> uploadQueueCountMessage() {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'upload-queue-count', 'v': {}},
    });
  }

  Map<String, dynamic> uploadQueueWaitMessage() {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'upload-queue-wait', 'v': {}},
    });
  }

  Map<String, dynamic> downloadingWaitMessage() {
    return Map.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'downloading-wait', 'v': {}},
    });
  }
}
