import 'dart:collection';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync/sqlite3.dart' as sqlite3;
import 'args.dart';
import 'schema.dart';

/// types of Endpoints
enum Endpoints { powersync, postgresql }

abstract class Endpoint {
  /// initialize the database
  Future<void> init({String filePath = '', bool preserveData = false});

  /// close the database
  Future<void> close();

  /// Execute an sql transaction and return the results:
  /// - request is an operation styled as a  Jepsen op as a SplayTreeMap
  ///   - transaction maps are in value: [{f: read-all | write-some, k: -1, v: {k: v}}...]
  /// - response is an updated op with the txn results
  ///
  /// No Exceptions are expected!
  /// Single user local PowerSync is totally available, strict serializable.
  /// No catching, let Exceptions fail the test
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op);

  /// api endpoint, will use the underlying db api for connect/disconnect, upload-queue-count/upload-queue-wait, select-all, etc
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
      (args['allKeys'] as Set<int>)
          .getRandom(count)
          .map((k) => MapEntry(k, value)),
    );

    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'txn',
      'value': [
        {'f': 'read-all', 'k': -1, 'v': reads},
        {'f': 'write-some', 'k': -1, 'v': writes},
      ],
      'table': Tables.mww.name,
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

  static SplayTreeMap<String, dynamic> selectAllMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {
        'f': 'select-all',
        'k': -1,
        'v': <sqlite3.Row>{},
        'table': Tables.mww.name,
      },
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
