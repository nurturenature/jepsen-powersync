import 'dart:collection';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync/sqlite3.dart' as sqlite3;
import 'args.dart';
import 'postgresql.dart' as pg;

abstract class Endpoint {
  /// Execute an sql transaction and return the results:
  /// - request is a Jepsen op value as a Map
  ///   - transaction maps are in value: [{f: r | append, k: key, v: value}...]
  /// - response is an updated Jepsen op value with the txn results
  ///
  /// No Exceptions are expected!
  /// Single user local PowerSync is totally available, strict serializable.
  /// No catching, let Exceptions fail the test
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op);

  /// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
  Future<SplayTreeMap> powersyncApi(SplayTreeMap op);

  /// returns a transaction message that:
  ///   - reads all key/values
  ///   - writes `value` to `count` random keys
  static SplayTreeMap<String, dynamic> readAllWriteSomeTxnMessage(
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

  static SplayTreeMap<String, dynamic> connectMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'connect', 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> disconnectMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'disconnect', 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> closeMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'close', 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> selectAllMessage(pg.Tables table) {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'select-all', 'k': table.name, 'v': <sqlite3.Row>{}},
      'table': table.name,
    });
  }

  static SplayTreeMap<String, dynamic> uploadQueueCountMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'upload-queue-count', 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> uploadQueueWaitMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'upload-queue-wait', 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> downloadingWaitMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': 'downloading-wait', 'v': {}},
    });
  }
}
