import 'dart:collection';
import 'package:list_utilities/list_utilities.dart';
import 'args.dart';

/// types of Endpoints
enum Endpoints { powersync, postgresql }

/// lookup Map for Endpoints
final endpointLookup = Endpoints.values.asNameMap();

/// types of SQL transactions
enum SQLTransactions { readAll, writeSome }

/// lookup Map for SQL Transactions
final sqlTransactionLookup = SQLTransactions.values.asNameMap();

/// types of API calls
enum APICalls {
  connect,
  disconnect,
  close,
  selectAll,
  uploadQueueCount,
  uploadQueueWait,
  downloadingWait,
}

/// lookup Map for API Calls
final apiCallLookup = APICalls.values.asNameMap();

abstract class Endpoint {
  /// initialize the database
  Future<void> init({String filePath = '', bool preserveData = false});

  /// Execute an sql transaction and return the results:
  /// - request is an operation styled as a  Jepsen op as a SplayTreeMap
  ///   - transaction maps are in value: [{f: readAll | writeSome, k: -1, v: {k: v}}...]
  /// - response is an updated op with the txn results
  ///
  /// No Exceptions are expected!
  /// Single user local PowerSync is totally available, strict serializable.
  /// No catching, let Exceptions fail the test
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op);

  /// api endpoint, will use the underlying db api for connect/disconnect, upload-queue-count/upload-queue-wait, select-all, etc
  Future<SplayTreeMap> dbApi(SplayTreeMap op);

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
        {'f': SQLTransactions.readAll.name, 'v': reads},
        {'f': SQLTransactions.writeSome.name, 'v': writes},
      ],
    });
  }

  static SplayTreeMap<String, dynamic> connectMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.connect.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> disconnectMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.disconnect.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> closeMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.close.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> selectAllMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.selectAll.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> uploadQueueCountMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.uploadQueueCount.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> uploadQueueWaitMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.uploadQueueWait.name, 'v': {}},
    });
  }

  static SplayTreeMap<String, dynamic> downloadingWaitMessage() {
    return SplayTreeMap.of({
      'type': 'invoke',
      'f': 'api',
      'value': {'f': APICalls.downloadingWait.name, 'v': {}},
    });
  }
}
