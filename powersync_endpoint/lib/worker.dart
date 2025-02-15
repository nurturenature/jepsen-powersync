import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/db.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/postgresql.dart' as pg;
import 'package:powersync_endpoint/utils.dart';

class Worker {
  final int _clientNum;

  // transaction instance variables
  final SendPort _txnRequests;
  final ReceivePort _txnResponses;
  final Map<int, Completer<Object?>> _activeTxnRequests = {};
  int _txnCounter = 0;
  bool _txnsClosed = false;

  // api instance variables
  final SendPort _apiRequests;
  final ReceivePort _apiResponses;
  final Map<int, Completer<Object?>> _activeApiRequests = {};
  int _apiCounter = 0;
  bool _apisClosed = false;

  // consistency checker instance variables
  final _readConsistency = ReadConsistency();

  Worker._(this._clientNum, this._txnResponses, this._txnRequests,
      this._apiResponses, this._apiRequests) {
    _txnResponses.listen(_handleTxnResponsesFromIsolate);
    _apiResponses.listen(_handleApiResponsesFromIsolate);
  }

  static Future<Worker> spawn(
      pg.Tables table, int clientNum, Endpoint endpoint) async {
    // Create a txn receive port and its initial message handler to receive the send port, e.g. a txn connection
    final initTxnReceivePort = RawReceivePort();
    final txnConnection = Completer<(ReceivePort, SendPort)>.sync();
    initTxnReceivePort.handler = (initialMessage) {
      final commandPort = initialMessage as SendPort;
      txnConnection.complete((
        ReceivePort.fromRawReceivePort(initTxnReceivePort),
        commandPort,
      ));
    };

    // Create an api receive port and its initial message handler to receive the send port, e.g. a api connection
    final initApiReceivePort = RawReceivePort();
    final apiConnection = Completer<(ReceivePort, SendPort)>.sync();
    initApiReceivePort.handler = (initialMessage) {
      final commandPort = initialMessage as SendPort;
      apiConnection.complete((
        ReceivePort.fromRawReceivePort(initApiReceivePort),
        commandPort,
      ));
    };

    // Spawn the isolate.
    try {
      await Isolate.spawn(
          _startRemoteIsolate,
          (
            table,
            clientNum,
            args,
            initTxnReceivePort.sendPort,
            initApiReceivePort.sendPort,
            endpoint
          ),
          debugName: 'ps-$clientNum');
    } on Object {
      initTxnReceivePort.close();
      initApiReceivePort.close();
      rethrow;
    }

    final (ReceivePort txnReceivePort, SendPort txnSendPort) =
        await txnConnection.future;

    final (ReceivePort apiReceivePort, SendPort apiSendPort) =
        await apiConnection.future;

    return Worker._(
        clientNum, txnReceivePort, txnSendPort, apiReceivePort, apiSendPort);
  }

  static Future<void> _startRemoteIsolate(message) async {
    final (
      pg.Tables table,
      int clientNum,
      Map<String, dynamic> mainArgs,
      SendPort txnSendPort,
      SendPort apiSendPort,
      Endpoint endpoint
    ) = message as (
      pg.Tables,
      int,
      Map<String, dynamic>,
      SendPort,
      SendPort,
      Endpoint
    );

    // initialize worker environment, state
    args = mainArgs; // args must be set first in Isolate
    initLogging('ps-$clientNum');

    // initialize PostgreSQL
    await pg.init(
        table, false); // database table was initialized in main Isolate
    log.info('PostgreSQL connection initialized, connection: ${pg.postgreSQL}');

    // initialize PowerSync db
    await initDb(table, '${Directory.current.path}/ps-$clientNum.sqlite3');
    log.info('db initialized: $db');

    // Isolate needs to be able to receive txn messages, and message Worker how to send to Isolate's txn receive port
    final txnReceivePort = ReceivePort();
    txnSendPort.send(txnReceivePort.sendPort);

    // Isolate needs to be able to receive txn messages, and message Worker how to send to Isolate's txn receive port
    final apiReceivePort = ReceivePort();
    apiSendPort.send(apiReceivePort.sendPort);

    // setup Isolate to handle incoming commands, send responses
    _handleTxnRequestsToIsolate(txnReceivePort, txnSendPort, endpoint);
    _handleApiRequestsToIsolate(apiReceivePort, apiSendPort, endpoint);
  }

  static void _handleTxnRequestsToIsolate(
      ReceivePort receivePort, SendPort sendPort, Endpoint endpoint) {
    // listen for commands sent to the Isolate
    receivePort.listen((message) async {
      // shutdown?
      if (message == 'shutdown') {
        receivePort.close();
        return;
      }

      // txn
      final (int id, Map txn) = message as (int, Map);
      try {
        log.fine('txn request: $txn');

        await endpoint.sqlTxn(txn);

        log.fine('txn response: $txn');
        sendPort.send((id, txn));
      } catch (e) {
        sendPort.send((id, RemoteError(e.toString(), '')));
      }
    });
  }

  void _handleTxnResponsesFromIsolate(dynamic message) {
    final (int id, Object? response) = message as (int, Object?);
    final completer = _activeTxnRequests.remove(id)!;

    if (response is RemoteError) {
      completer.completeError(response);
    } else {
      completer.complete(response);
    }

    if (_txnsClosed && _activeTxnRequests.isEmpty) _txnResponses.close();

    // check lww reads for consistency
    final op = response as Map<String, dynamic>;
    if (op['table'] == 'lww' && op['type'] == 'ok' && op['f'] == 'txn') {
      final List<Map> value = op['value'];
      value // List of {f: k: v:}
          .where((mop) => mop['f'] == 'r') // only reads
          .forEach((mop) {
        final k = mop['k'] as int;
        final v = mop['v'] as String?;
        if (_readConsistency.suspiciousRead(k, v)) {
          log.severe('ERROR: suspicious read: $mop, for $op');
          exit(127);
        }
      });
    }
  }

  static void _handleApiRequestsToIsolate(
      ReceivePort receivePort, SendPort sendPort, Endpoint endpoint) {
    // listen for commands sent to the Isolate
    receivePort.listen((message) async {
      // shutdown?
      if (message == 'shutdown') {
        receivePort.close();
        return;
      }

      // api call
      final (int id, Map api) = message as (int, Map);
      try {
        log.fine('api request: $api');

        await endpoint.powersyncApi(api);

        log.fine('api response: $api');
        sendPort.send((id, api));
      } catch (e) {
        sendPort.send((id, RemoteError(e.toString(), '')));
      }
    });
  }

  void _handleApiResponsesFromIsolate(dynamic message) {
    final (int id, Object? response) = message as (int, Object?);
    final completer = _activeApiRequests.remove(id)!;

    if (response is RemoteError) {
      completer.completeError(response);
    } else {
      completer.complete(response);
    }

    if (_apisClosed && _activeApiRequests.isEmpty) _apiResponses.close();
  }

  Future<Object?> executeTxn(Map<String, dynamic> txn) async {
    // must not be closed
    if (_txnsClosed) throw StateError('Closed');

    // insure ordering, request/response id's match
    final completer = Completer<Object?>.sync();
    final id = _txnCounter++;
    _activeTxnRequests[id] = completer;

    // augment message with meta data re client and state
    txn.addAll({'clientNum': _clientNum, 'id': id});

    // send txn request to isolate, await and return txn response
    _txnRequests.send((id, txn));
    return await completer.future;
  }

  Future<Map> executeApi(Map<String, dynamic> api) async {
    // must not be closed
    if (_apisClosed) {
      throw StateError(
          'APIs already closed! clientNum: $_clientNum, api: $api');
    }

    // insure ordering, request/response id's match
    final completer = Completer<Object?>.sync();
    final id = _apiCounter++;
    _activeApiRequests[id] = completer;

    // augment message with meta data re client and state
    api.addAll({'clientNum': _clientNum, 'id': id});

    // send api request to isolate, await and return api response
    _apiRequests.send((id, api));
    return (await completer.future) as Map;
  }

  void closeTxns() {
    if (!_txnsClosed) {
      _txnsClosed = true;
      _txnRequests.send('shutdown');
      if (_activeTxnRequests.isEmpty) _txnResponses.close();
    }
  }

  void closeApis() {
    if (!_apisClosed) {
      _apisClosed = true;
      _apiRequests.send('shutdown');
      if (_activeApiRequests.isEmpty) _apiResponses.close();
    }
  }

  int getClientNum() {
    return _clientNum;
  }
}
