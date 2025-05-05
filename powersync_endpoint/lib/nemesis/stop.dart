import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import '../endpoint.dart';
import '../error_codes.dart';
import '../log.dart';
import '../utils.dart' as utils;
import '../worker.dart';

enum _StopStartStates { stopped, started }

class StopStartNemesis {
  final Set<Worker> _allClients;
  final Set<int> _availableClientNums = {};
  final Set<int> _stoppedClientNums = {};

  late final Stream<_StopStartStates> Function() _stopStartStream;
  late final StreamSubscription<_StopStartStates> _stopStartSubscription;

  final _rng = Random();
  final _lock = Lock();

  StopStartNemesis(this._allClients, int interval) {
    final maxInterval = interval * 1000 * 2;
    final stopStartState = _StopStartState();

    // all available clientNums except PostgreSQL client
    _availableClientNums.addAll(
      _allClients
          .map((client) => client.clientNum)
          .where((clientNum) => clientNum != 0),
    );

    // Stream of StopStartStates, flip flops between stopped and started
    // Stream will not emit messages until listened to
    _stopStartStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(maxInterval + 1));
        yield await _lock.synchronized<_StopStartStates>(() {
          return stopStartState._flipFlop();
        });
      }
    };
  }

  // start injecting stop/start messages
  void startStopStart() {
    log.info(
      'nemesis: stop/start: start listening to stream of stop/start messages',
    );

    _stopStartSubscription = _stopStartStream().listen((
      stopStateMessage,
    ) async {
      await _lock.synchronized(() async {
        Set<int> affectedClientNums;
        switch (stopStateMessage) {
          case _StopStartStates.stopped:
            affectedClientNums = await _stopClients();
            break;
          case _StopStartStates.started:
            affectedClientNums = await _startClients();
            break;
        }

        log.info(
          'nemesis: stop/start: ${stopStateMessage.name}: clients: $affectedClientNums',
        );
      });
    });
  }

  // stop a random subset of clients
  //   - client must not have active transactions
  Future<Set<int>> _stopClients() async {
    assert(_stoppedClientNums.isEmpty);

    // act on 0 to all clients
    final int numRandomClients = _rng.nextInt(_availableClientNums.length + 1);
    final possibleClientNums = _availableClientNums.getRandom(numRandomClients);

    // stop all clients in parallel
    final List<Future<int>> stoppedClientFutures = [];
    for (final clientNum in possibleClientNums) {
      final client = _allClients.firstWhere(
        (client) => client.clientNum == clientNum,
      );

      // preemptively remove client so it doesn't receive any more sql txn messages
      _allClients.remove(client);

      // don't interrupt if active transactions
      if (client.activeTxnRequests.isNotEmpty) {
        log.info(
          'nemesis: stop/start: client $clientNum not stopped due to active transaction requests: ${client.activeTxnRequests}',
        );

        // re-add to active clients
        _allClients.add(client);

        continue;
      }

      stoppedClientFutures.add(_stopClient(client));
    }

    _stoppedClientNums.addAll(await stoppedClientFutures.wait);

    return _stoppedClientNums;
  }

  // stop an individual client returning its clientNum
  Future<int> _stopClient(Worker client) async {
    final result = await client.executeApi(Endpoint.closeMessage());
    if (result['type'] != 'ok') {
      log.severe(
        'nemesis: stop/start: unable to close client: ${client.clientNum}, result: $result',
      );
      exit(errorCodes[ErrorReasons.codingError]!);
    }

    client.closeTxns();
    client.closeApis();

    final killed = client.killIsolate();
    if (!killed) {
      log.severe(
        'nemesis: stop/start: unable to kill client ${client.clientNum} Isolate',
      );
      exit(errorCodes[ErrorReasons.codingError]!);
    }

    return client.clientNum;
  }

  // start clients that were stopped
  //   - preserve existing SQLite3 db files
  Future<Set<int>> _startClients() async {
    final Set<int> affectedClientNums = {};

    // start all clients in parallel
    final List<Future<Worker>> affectedClientFutures = [];
    for (final clientNum in _stoppedClientNums) {
      affectedClientFutures.add(
        Worker.spawn(Endpoints.powersync, clientNum, preserveData: true),
      );

      affectedClientNums.add(clientNum);
    }

    // add started clients to all clients
    _allClients.addAll(await affectedClientFutures.wait);

    _stoppedClientNums.removeAll(affectedClientNums);

    return affectedClientNums;
  }

  // stop injecting stop/start messages
  Future<void> stopStopStart() async {
    log.info(
      'nemesis: stop/start: stop listening to stream of stop/start messages',
    );

    // stop Stream of stop/start messages
    await _stopStartSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    final affectedClientNums = await _startClients();

    log.info(
      'nemesis: stop/start: ${_StopStartStates.started.name}: clients: $affectedClientNums',
    );
  }
}

/// Maintains the stop/start state.
/// Flip flops between stopped and started StopStartStates
class _StopStartState {
  _StopStartStates _state = _StopStartStates.started;

  // Flip flop the current state.
  _StopStartStates _flipFlop() {
    _state = switch (_state) {
      _StopStartStates.started => _StopStartStates.stopped,
      _StopStartStates.stopped => _StopStartStates.started,
    };

    return _state;
  }
}
