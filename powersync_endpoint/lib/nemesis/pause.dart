import 'dart:async';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import '../log.dart';
import '../utils.dart' as utils;
import '../worker.dart';

enum _PauseStates { running, paused }

class PauseResumeNemesis {
  late final Set<Worker> _possibleClients;
  late final Stream<_PauseStates> Function() _pauseStream;
  late final StreamSubscription<_PauseStates> _pauseSubscription;

  final _rng = Random();
  final _lock = Lock();

  PauseResumeNemesis(Set<Worker> allClients, int interval) {
    // all but PostgreSQL client
    _possibleClients = allClients
        .where((client) => client.clientNum != 0)
        .toSet();

    final maxInterval = interval * 1000 * 2;

    final _PauseState pauseState = _PauseState();

    // Stream of PauseStates, flip flops between running and paused
    // Stream will not emit messages until listened to
    _pauseStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(maxInterval + 1));
        yield await _lock.synchronized<_PauseStates>(() {
          return pauseState._flipFlop();
        });
      }
    };
  }

  // start injecting pause/resume messages
  void startPause() {
    log.info(
      'nemesis: pause/resume: start listening to stream of pause/resume messages',
    );

    _pauseSubscription = _pauseStream().listen((pauseMessage) async {
      await _lock.synchronized(() {
        log.info(
          'nemesis: pause/resume: ${pauseMessage.name}: beginning action ...',
        );

        final Set<Worker> affectedClients;
        switch (pauseMessage) {
          case _PauseStates.paused:
            // act on 0 to all clients
            final int numRandomClients = _rng.nextInt(
              _possibleClients.length + 1,
            );
            affectedClients = _possibleClients.getRandom(numRandomClients);
            break;
          case _PauseStates.running:
            affectedClients = _possibleClients;
            break;
        }

        Set<int> affectedClientNums = {};
        for (Worker client in affectedClients) {
          if (_pauseOrResume(client, pauseMessage)) {
            affectedClientNums.add(client.clientNum);
          }
        }

        log.info(
          'nemesis: pause/resume: ${pauseMessage.name}: clients: $affectedClientNums',
        );
      });
    });
  }

  // stop injecting pause/resume messages
  Future<void> stopPause() async {
    log.info(
      'nemesis: pause/resume: stop listening to stream of pause/resume messages',
    );

    // stop Stream of pause/resume messages
    await _pauseSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    log.info(
      'nemesis: pause/resume: ${_PauseStates.running.name}: beginning action ...',
    );

    // insure all clients are running
    Set<int> affectedClientNums = {};
    for (Worker client in _possibleClients) {
      if (_pauseOrResume(client, _PauseStates.running)) {
        affectedClientNums.add(client.clientNum);
      }
    }

    log.info(
      'nemesis: pause/resume: ${_PauseStates.running.name}: clients: $affectedClientNums',
    );
  }

  // Pause or resume client per pauseType
  static bool _pauseOrResume(Worker client, _PauseStates pauseType) {
    switch (pauseType) {
      case _PauseStates.running:
        return client.resumeIsolate();

      case _PauseStates.paused:
        return client.pauseIsolate();
    }
  }
}

// Maintains the pause state.
// Flip flops between running and paused.
class _PauseState {
  _PauseStates _state = _PauseStates.running;

  // Flip flop the current state.
  _PauseStates _flipFlop() {
    _state = switch (_state) {
      _PauseStates.running => _PauseStates.paused,
      _PauseStates.paused => _PauseStates.running,
    };

    return _state;
  }
}
