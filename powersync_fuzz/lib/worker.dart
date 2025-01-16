import 'dart:async';
import 'dart:isolate';
import 'package:powersync_fuzz/args.dart';
import 'package:powersync_fuzz/log.dart';

class Worker {
  final int _clientNum;
  final SendPort _txnRequests;
  final ReceivePort _txnResponses;
  final Map<int, Completer<Object?>> _activeTxnRequests = {};
  int _txnCounter = 0;
  bool _txnsClosed = false;

  Worker._(this._clientNum, this._txnResponses, this._txnRequests) {
    _txnResponses.listen(_handleTxnResponsesFromIsolate);
  }

  static Future<Worker> spawn(int clientNum) async {
    // Create a receive port and its initial message handler to receive the send port, e.g. a connection
    final initTxnReceivePort = RawReceivePort();
    final txnConnection = Completer<(ReceivePort, SendPort)>.sync();
    initTxnReceivePort.handler = (initialMessage) {
      final commandPort = initialMessage as SendPort;
      txnConnection.complete((
        ReceivePort.fromRawReceivePort(initTxnReceivePort),
        commandPort,
      ));
    };

    // Spawn the isolate.
    try {
      await Isolate.spawn(
          _startRemoteIsolate, (clientNum, args, initTxnReceivePort.sendPort));
    } on Object {
      initTxnReceivePort.close();
      rethrow;
    }

    final (ReceivePort txnReceivePort, SendPort txnSendPort) =
        await txnConnection.future;

    return Worker._(clientNum, txnReceivePort, txnSendPort);
  }

  static void _startRemoteIsolate(message) {
    final (int clientNum, Map<String, dynamic> mainArgs, SendPort txnSendPort) =
        message as (int, Map<String, dynamic>, SendPort);

    // initialize worker environment, state
    args = mainArgs;
    initLogging('client-$clientNum');

    // Isolate needs to be able to receive messages, and message Worker how to send to Isolate's receive port
    final txnReceivePort = ReceivePort();
    txnSendPort.send(txnReceivePort.sendPort);

    // setup Isolate to handle incoming commands, send responses
    _handleTxnRequestsToIsolate(txnReceivePort, txnSendPort);
  }

  static void _handleTxnRequestsToIsolate(
      ReceivePort receivePort, SendPort sendPort) {
    // listen for commands sent to the Isolate
    receivePort.listen((message) {
      // shutdown?
      if (message == 'shutdown') {
        receivePort.close();
        return;
      }

      // txn
      final (int id, Map txn) = message as (int, Map);
      try {
        // TODO: execute txn in db
        // FOR NOW: assume ok
        log.fine('txn ($id) request: $txn');
        txn.addAll({'type': 'ok'});
        log.fine('txn ($id) response: $txn');
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
  }

  Future<Object?> executeTxn(Map txn) async {
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

  void close() {
    if (!_txnsClosed) {
      _txnsClosed = true;
      _txnRequests.send('shutdown');
      if (_activeTxnRequests.isEmpty) _txnResponses.close();
      log.info('client ($_clientNum) txn ports closed');
    }
  }
}
