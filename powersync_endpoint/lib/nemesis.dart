import 'dart:async';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import 'endpoint.dart';
import 'log.dart';
import 'nemesis/disconnect.dart';
import 'nemesis/partition.dart';
import 'nemesis/pause.dart';
import 'nemesis/stop.dart';
import 'utils.dart' as utils;
import 'worker.dart';

// synchronize generation of nemesis stream events and their actual execution in the stream subscription
// prevents overlapping of start/stop, flip flopped, states
enum Nemeses { disconnect, stop, kill, partition, pause }

final _locks = Map.fromEntries(
  Nemeses.values.map((nemesis) => MapEntry(nemesis, Lock())),
);

/// Fault injection.
/// Disconnect, connect, Workers from PowerSync Service:
///   - --disconnect [none | orderly | random] db.disconnect()/connect
///   - --interval, 0 <= random <= 2 * interval
/// Stop, start, Worker Isolates:
///   - --stop, db.close(), Isolate.kill()
///   - --interval, 0 <= random <= 2 * interval
/// Kill, start, Worker Isolates:
///   - --stop, Isolate.terminate(immediate), no warning/interaction w/Powersync
///   - --interval, 0 <= random <= 2 * interval
/// Partition Workers from PowerSync Service:
///   - --partition, random inbound or outbound or bidirectional
///   - --interval, 0 <= random <= 2 * interval
/// Pause, resume, Worker Isolates:
///   - --pause, Isolate.pause()/resume()
///   - --interval, 0 <= random <= 2 * interval
class Nemesis {
  final Set<int> _allClientNums = {};
  final Set<Worker> _clients;
  late final int _interval;
  late final int _maxInterval;

  // disconnect/connect
  late final DisconnectNemeses _disconnect;
  late final DisconnectNemesis _disconnectNemesis;

  // stop/start
  late final bool _stopStart;
  late final StopStartNemesis _stopStartNemesis;

  // kill/start
  late final bool _killStart;
  final KillStartState _killStartState = KillStartState();
  late final Stream<KillStartStates> Function() _killStartStream;
  late final StreamSubscription<KillStartStates> _killStartSubscription;

  // partition
  late final bool _partition;
  late final PartitionNemesis _partitionNemesis;

  // pause/resume
  late final bool _pauseResume;
  late final PauseResumeNemesis _pauseResumeNemesis;

  // source of randomness
  final _rng = Random();

  Nemesis(Map<String, dynamic> args, this._clients) {
    // set of all possible client nums
    for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
      _allClientNums.add(clientNum);
    }
    if (args['postgresql']) _allClientNums.add(0);

    // CLI args
    _disconnect = args['disconnect'] as DisconnectNemeses;
    _stopStart = args['stop'] as bool;
    _killStart = args['kill'] as bool;
    _partition = args['partition'] as bool;
    _pauseResume = args['pause'] as bool;
    _interval = args['interval'] as int;
    _maxInterval = _interval * 1000 * 2;

    // only create a DisconnectNemesis if needed
    if (_disconnect != DisconnectNemeses.none) {
      _disconnectNemesis = DisconnectNemesis(_disconnect, _clients, _interval);
    }

    // only create a StopStartNemesis if needed
    if (_stopStart) {
      _stopStartNemesis = StopStartNemesis(_clients, _interval);
    }

    // only create a PartitionNemesis if needed
    if (_partition) {
      _partitionNemesis = PartitionNemesis(_interval);
    }

    // only create a PauseResumeNemesis if needed
    if (_pauseResume) {
      _pauseResumeNemesis = PauseResumeNemesis(_clients, _interval);
    }

    // Stream of KillStartStates, flip flops between started and killed
    // Stream will not emit messages until listened to
    _killStartStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(_maxInterval + 1));
        yield await _locks[Nemeses.kill]!.synchronized<KillStartStates>(() {
          return _killStartState.flipFlop();
        });
      }
    };
  }

  /// start injecting faults
  void start() {
    if (_disconnect != DisconnectNemeses.none) {
      _disconnectNemesis.startDisconnect();
    }
    if (_stopStart) _stopStartNemesis.startStopStart();
    if (_killStart) _startKillStart();
    if (_partition) _partitionNemesis.startPartition();
    if (_pauseResume) _pauseResumeNemesis.startPause();
  }

  /// stop injecting faults
  Future<void> stop() async {
    if (_disconnect != DisconnectNemeses.none) {
      await _disconnectNemesis.stopDisconnect();
    }
    if (_stopStart) await _stopStartNemesis.stopStopStart();
    if (_killStart) await _stopKillStart();
    if (_partition) await _partitionNemesis.stopPartition();
    if (_pauseResume) await _pauseResumeNemesis.stopPause();
  }

  // start injecting kill/start
  void _startKillStart() {
    log.info(
      'nemesis: kill/start: start listening to stream of kill/start messages',
    );

    _killStartSubscription = _killStartStream().listen((
      killStartMessage,
    ) async {
      await _locks[Nemeses.kill]!.synchronized(() async {
        // what clients to act on
        final Set<int> actOnClientNums = {};
        switch (killStartMessage) {
          case KillStartStates.killed:
            // act on 0 to all clients
            final int numRandomClients = _rng.nextInt(_clients.length + 1);
            actOnClientNums.addAll(
              _clients
                  .getRandom(numRandomClients)
                  .map((client) => client.clientNum),
            );
            break;
          case KillStartStates.started:
            actOnClientNums.addAll(
              _allClientNums.getRandom(_allClientNums.length),
            );
            break;
        }

        // act on clients in parallel
        final List<Future<bool>> affectedClientFutures = [];
        final List<int> affectedClientNums = [];
        for (final clientNum in actOnClientNums) {
          affectedClientFutures.add(
            KillStart.killOrStart(_clients, clientNum, killStartMessage),
          );
          affectedClientNums.add(clientNum);
        }

        // find client nums that were actually acted on
        Set<int> actuallyAffectedClientNums = {};
        for (final (index, result)
            in (await affectedClientFutures.wait).indexed) {
          if (result) {
            actuallyAffectedClientNums.add(affectedClientNums[index]);
          }
        }

        log.info(
          'nemesis: kill/start: ${killStartMessage.name}: clients: $actuallyAffectedClientNums',
        );
      });
    });
  }

  // stop injecting kill/start
  Future<void> _stopKillStart() async {
    // stop Stream of kill/start messages
    await _killStartSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // insure all clients are started, act on clients in parallel
    final List<Future<bool>> affectedClientFutures = [];
    final List<int> affectedClientNums = [];
    for (final clientNum in _allClientNums) {
      // conditionally, not in _clients, start new client as clientNum
      affectedClientFutures.add(
        KillStart.killOrStart(_clients, clientNum, KillStartStates.started),
      );
      affectedClientNums.add(clientNum);
    }

    // find client nums that were actually started
    Set<int> actuallyAffectedClientNums = {};
    for (final (index, result) in (await affectedClientFutures.wait).indexed) {
      if (result) {
        actuallyAffectedClientNums.add(affectedClientNums[index]);
      }
    }

    log.info(
      'nemesis: kill/start: ${KillStartStates.started.name}: clients: $actuallyAffectedClientNums',
    );
  }
}

/// Kill/start

enum KillStartStates { started, killed }

/// Maintains the kill/start state.
/// Flip flops between started and killed.
class KillStartState {
  KillStartStates _state = KillStartStates.started;

  // Flip flop the current state.
  KillStartStates flipFlop() {
    _state = switch (_state) {
      KillStartStates.started => KillStartStates.killed,
      KillStartStates.killed => KillStartStates.started,
    };

    return _state;
  }
}

/// Static kill or start function.
class KillStart {
  /// Kill or start client per killStartType.
  /// Removes or adds client to clients as appropriate.
  static Future<bool> killOrStart(
    Set<Worker> clients,
    int clientNum,
    KillStartStates killStartType,
  ) async {
    switch (killStartType) {
      case KillStartStates.killed:
        // leave PostgreSQL client as is
        if (clientNum == 0) return false;

        // selects client by num or throws if not present
        final client = clients.firstWhere(
          (client) => client.clientNum == clientNum,
        );

        // preemptively remove client so it doesn't receive any more sql txn messages
        clients.remove(client);

        // don't interrupt if active txns
        if (client.activeTxnRequests.isNotEmpty) {
          clients.add(client);
          return false;
        }

        client.closeTxns();
        client.closeApis();

        if (!client.killIsolate()) {
          throw StateError('Not able to terminate client: $clientNum!');
        }

        return true;

      case KillStartStates.started:
        // clientNum may already exist in clients, i.e. be started
        if (clients.any((client) => client.clientNum == clientNum)) {
          return true;
        }

        clients.add(
          await Worker.spawn(
            Endpoints.powersync,
            clientNum,
            preserveData: true,
          ),
        );

        return true;
    }
  }
}
