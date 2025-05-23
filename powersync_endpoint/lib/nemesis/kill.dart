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

enum _KillStartStates { started, killed }

class KillStartNemesis {
  final Set<Worker> _allClients;
  final Set<int> _availableClientNums = {};
  final Set<int> _killedClientNums = {};

  late final Stream<_KillStartStates> Function() _killStartStream;
  late final StreamSubscription<_KillStartStates> _killStartSubscription;

  final _rng = Random();
  final _lock = Lock();

  KillStartNemesis(this._allClients, int interval) {
    final maxInterval = interval * 1000 * 2;
    final killStartState = _KillStartState();

    // all available clientNums except PostgreSQL client
    _availableClientNums.addAll(
      _allClients
          .map((client) => client.clientNum)
          .where((clientNum) => clientNum != 0),
    );

    // Stream of _KillStartStates, flip flops between started and killed
    // Stream will not emit messages until listened to
    _killStartStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(maxInterval + 1));
        yield await _lock.synchronized<_KillStartStates>(() {
          return killStartState._flipFlop();
        });
      }
    };
  }

  // start injecting kill/start
  void startKillStart() {
    log.info(
      'nemesis: kill/start: start listening to stream of kill/start messages',
    );

    _killStartSubscription = _killStartStream().listen((
      killStartMessage,
    ) async {
      await _lock.synchronized(() async {
        Set<int> affectedClientNums;
        switch (killStartMessage) {
          case _KillStartStates.killed:
            affectedClientNums = await _killClients();
            break;
          case _KillStartStates.started:
            affectedClientNums = await _startClients();
            break;
        }

        log.info(
          'nemesis: kill/start: ${killStartMessage.name}: clients: $affectedClientNums',
        );
      });
    });
  }

  // kill a random subset of clients
  //   - client must not have active transactions
  Future<Set<int>> _killClients() async {
    utils.alwaysAssert(_killedClientNums.isEmpty);

    // act on 0 to majority clients
    final int numRandomClients = _rng.nextInt(
      (_availableClientNums.length / 2).ceil() + 1,
    );
    final possibleClientNums = _availableClientNums.getRandom(numRandomClients);

    log.info(
      'nemesis: kill/start: attempting to ${_KillStartStates.killed.name}: clients: $possibleClientNums',
    );

    // kill all clients in parallel
    final List<Future<int>> killedClientFutures = [];
    for (final clientNum in possibleClientNums) {
      final client = _allClients.firstWhere(
        (client) => client.clientNum == clientNum,
      );

      // preemptively remove client so it doesn't receive any more sql txn messages
      _allClients.remove(client);

      // don't interrupt if active transactions
      if (client.activeTxnRequests.isNotEmpty) {
        log.info(
          'nemesis: kill/start: client $clientNum not killed due to active transaction requests: ${client.activeTxnRequests}',
        );

        // re-add to active clients
        _allClients.add(client);

        continue;
      }

      killedClientFutures.add(_killClient(client));
    }

    _killedClientNums.addAll(await killedClientFutures.wait);

    return _killedClientNums;
  }

  // kill an individual client returning its clientNum
  Future<int> _killClient(Worker client) async {
    client.closeTxns();
    client.closeApis();

    final killed = client.killIsolate();
    if (!killed) {
      log.severe(
        'nemesis: kill/start: unable to kill client ${client.clientNum} Isolate',
      );
      exit(errorCodes[ErrorReasons.codingError]!);
    }

    return client.clientNum;
  }

  // start clients that were killed
  //   - preserve existing SQLite3 db files
  Future<Set<int>> _startClients() async {
    log.info(
      'nemesis: kill/start: attempting to ${_KillStartStates.started.name}: clients: $_killedClientNums',
    );

    final Set<int> affectedClientNums = {};

    // start all clients in parallel
    final List<Future<Worker>> affectedClientFutures = [];
    for (final clientNum in _killedClientNums) {
      affectedClientFutures.add(
        Worker.spawn(Endpoints.powersync, clientNum, preserveData: true),
      );

      affectedClientNums.add(clientNum);
    }

    // add started clients to all clients
    _allClients.addAll(await affectedClientFutures.wait);

    // no clients are killed anymore
    _killedClientNums.removeAll(affectedClientNums);

    return affectedClientNums;
  }

  // stop injecting kill/start
  Future<void> stopKillStart() async {
    log.info(
      'nemesis: kill/start: stop listening to stream of kill/start messages',
    );

    // stop Stream of kill/start messages
    await _killStartSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // insure all clients are started
    final affectedClientNums = await _startClients();

    log.info(
      'nemesis: kill/start: ${_KillStartStates.started.name}: clients: $affectedClientNums',
    );
  }
}

/// Maintains the kill/start state.
/// Flip flops between started and killed.
class _KillStartState {
  _KillStartStates _state = _KillStartStates.started;

  // Flip flop the current state.
  _KillStartStates _flipFlop() {
    _state = switch (_state) {
      _KillStartStates.started => _KillStartStates.killed,
      _KillStartStates.killed => _KillStartStates.started,
    };

    return _state;
  }
}
