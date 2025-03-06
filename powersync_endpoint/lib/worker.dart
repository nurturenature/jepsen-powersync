import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/pg_endpoint.dart';
import 'package:powersync_endpoint/ps_endpoint.dart';

class Worker {
  final Isolate _isolate;
  Capability? _resumeCapability;

  final int clientNum;

  // transaction instance variables
  final SendPort _txnRequests;
  final ReceivePort _txnResponses;
  final Map<int, Completer<Object?>> activeTxnRequests = {};
  int _txnCounter = 0;
  bool _txnsClosed = false;

  // api instance variables
  final SendPort _apiRequests;
  final ReceivePort _apiResponses;
  final Map<int, Completer<Object?>> _activeApiRequests = {};
  int _apiCounter = 0;
  bool _apisClosed = false;

  Worker._(
    this._isolate,
    this.clientNum,
    this._txnResponses,
    this._txnRequests,
    this._apiResponses,
    this._apiRequests,
  ) {
    _txnResponses.listen(_handleTxnResponsesFromIsolate);
    _apiResponses.listen(_handleApiResponsesFromIsolate);
  }

  static Future<Worker> spawn(
    Endpoints endpoint,
    int clientNum, {
    bool preserveData = false,
  }) async {
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
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(_startRemoteIsolate, (
        endpoint,
        clientNum,
        args,
        initTxnReceivePort.sendPort,
        initApiReceivePort.sendPort,
        preserveData,
      ), debugName: 'ps-$clientNum');
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
      isolate,
      clientNum,
      txnReceivePort,
      txnSendPort,
      apiReceivePort,
      apiSendPort,
    );
  }

  static Future<void> _startRemoteIsolate(message) async {
    final (
      Endpoints endpoint,
      int clientNum,
      Map<String, dynamic> mainArgs,
      SendPort txnSendPort,
      SendPort apiSendPort,
      bool preserveData,
    ) = message
            as (Endpoints, int, Map<String, dynamic>, SendPort, SendPort, bool);

    // initialize worker environment, state
    args = mainArgs; // args must be set first in Isolate
    initLogging('ps-$clientNum');

    final endpointDb = switch (endpoint) {
      Endpoints.powersync => PSEndpoint(),
      Endpoints.postgresql => PGEndpoint(),
    };
    await endpointDb.init(
      filePath: '${Directory.current.path}/ps-$clientNum.sqlite3',
      preserveData: preserveData,
    );

    // Isolate needs to be able to receive txn messages, and message Worker how to send to Isolate's txn receive port
    final txnReceivePort = ReceivePort();
    txnSendPort.send(txnReceivePort.sendPort);

    // Isolate needs to be able to receive txn messages, and message Worker how to send to Isolate's txn receive port
    final apiReceivePort = ReceivePort();
    apiSendPort.send(apiReceivePort.sendPort);

    // setup Isolate to handle incoming commands, send responses
    _handleTxnRequestsToIsolate(txnReceivePort, txnSendPort, endpointDb);
    _handleApiRequestsToIsolate(apiReceivePort, apiSendPort, endpointDb);
  }

  static void _handleTxnRequestsToIsolate(
    ReceivePort receivePort,
    SendPort sendPort,
    Endpoint endpoint,
  ) {
    // listen for commands sent to the Isolate
    receivePort.listen((message) async {
      // shutdown?
      if (message == 'shutdown') {
        receivePort.close();
        await endpoint.close();
        return;
      }

      // txn
      final (int id, SplayTreeMap txn) = message as (int, SplayTreeMap);
      try {
        log.fine('SQL txn: request: $txn');

        await endpoint.sqlTxn(txn);

        log.fine('SQL txn: response: $txn');

        sendPort.send((id, txn));
      } catch (e) {
        sendPort.send((id, RemoteError(e.toString(), '')));
      }
    });
  }

  void _handleTxnResponsesFromIsolate(dynamic message) {
    final (int id, Object? response) = message as (int, Object?);
    final completer = activeTxnRequests.remove(id)!;

    if (response is RemoteError) {
      completer.completeError(response);
    } else {
      completer.complete(response);
    }

    if (_txnsClosed && activeTxnRequests.isEmpty) _txnResponses.close();
  }

  static void _handleApiRequestsToIsolate(
    ReceivePort receivePort,
    SendPort sendPort,
    Endpoint endpoint,
  ) {
    // listen for commands sent to the Isolate
    receivePort.listen((message) async {
      // shutdown?
      if (message == 'shutdown') {
        receivePort.close();
        return;
      }

      // api call
      final (int id, SplayTreeMap api) = message as (int, SplayTreeMap);
      try {
        log.fine('database api: request: $api');

        await endpoint.powersyncApi(api);

        log.fine('database api: response: $api');
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
    activeTxnRequests[id] = completer;

    // augment message with meta data re client and state
    txn.addAll({'clientNum': clientNum, 'id': id});

    // send txn request to isolate, await and return txn response
    _txnRequests.send((id, txn));
    return await completer.future;
  }

  Future<Map> executeApi(Map<String, dynamic> api) async {
    // must not be closed
    if (_apisClosed) {
      throw StateError('APIs already closed! clientNum: $clientNum, api: $api');
    }

    // insure ordering, request/response id's match
    final completer = Completer<Object?>.sync();
    final id = _apiCounter++;
    _activeApiRequests[id] = completer;

    // augment message with meta data re client and state
    api.addAll({'clientNum': clientNum, 'id': id});

    // send api request to isolate, await and return api response
    _apiRequests.send((id, api));
    return (await completer.future) as Map;
  }

  void closeTxns() {
    if (!_txnsClosed) {
      _txnsClosed = true;
      _txnRequests.send('shutdown');
      if (activeTxnRequests.isEmpty) _txnResponses.close();
    }
  }

  void closeApis() {
    if (!_apisClosed) {
      _apisClosed = true;
      _apiRequests.send('shutdown');
      if (_activeApiRequests.isEmpty) _apiResponses.close();
    }
  }

  /// Pauses this client isolate if there are no active transaction requests pending.
  /// Error to try and pause an already paused client isolate.
  bool pauseIsolate() {
    if (_resumeCapability != null) {
      throw StateError(
        'Trying to pause client $clientNum which is an already paused isolate!',
      );
    }

    if (activeTxnRequests.isNotEmpty) {
      return false;
    }

    _resumeCapability = _isolate.pause();

    return true;
  }

  /// Resume this client isolate.
  /// Requests to resume an unpaused client isolate are ignored.
  bool resumeIsolate() {
    if (_resumeCapability == null) {
      return true;
    }

    _isolate.resume(_resumeCapability!);
    _resumeCapability = null;

    return true;
  }

  /// Kill this client isolate.
  bool killIsolate() {
    if (_isolate.terminateCapability == null) {
      return false;
    }

    _isolate.kill(priority: Isolate.immediate);

    return true;
  }
}
