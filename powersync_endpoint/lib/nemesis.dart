import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import 'endpoint.dart';
import 'log.dart';
import 'nemesis/disconnect.dart';
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
  static const powerSyncHost = 'powersync';
  final PartitionState _partitionState = PartitionState();
  late final Stream<PartitionStates> Function() _partitionStream;
  late final StreamSubscription<PartitionStates> _partitionSubscription;

  // pause/resume
  late final bool _pause;
  final PauseState _pauseState = PauseState();
  late final Stream<PauseStates> Function() _pauseStream;
  late final StreamSubscription<PauseStates> _pauseSubscription;

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
    _pause = args['pause'] as bool;
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

    // Stream of PartitionStates, flip flops between none and inbound or outbound or bidirectional
    // Stream will not emit messages until listened to
    _partitionStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(_maxInterval + 1));
        yield await _locks[Nemeses.partition]!.synchronized<PartitionStates>(
          () {
            return _partitionState.flipFlop();
          },
        );
      }
    };

    // Stream of PauseStates, flip flops between running and paused
    // Stream will not emit messages until listened to
    _pauseStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(_maxInterval + 1));
        yield await _locks[Nemeses.pause]!.synchronized<PauseStates>(() {
          return _pauseState.flipFlop();
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
    if (_partition) _startPartition();
    if (_pause) _startPause();
  }

  /// stop injecting faults
  Future<void> stop() async {
    if (_disconnect != DisconnectNemeses.none) {
      await _disconnectNemesis.stopDisconnect();
    }
    if (_stopStart) await _stopStartNemesis.stopStopStart();
    if (_killStart) await _stopKillStart();
    if (_partition) await _stopPartition();
    if (_pause) await _stopPause();
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

  // start injecting partition
  void _startPartition() {
    log.info(
      'nemesis: partition: start listening to stream of partition messages',
    );

    _partitionSubscription = _partitionStream().listen((
      partitionStateMessage,
    ) async {
      await _locks[Nemeses.partition]!.synchronized(() async {
        await Partition.partition(powerSyncHost, partitionStateMessage);

        log.info('nemesis: partition: ${partitionStateMessage.name}');
      });
    });
  }

  // stop injecting partition
  Future<void> _stopPartition() async {
    // stop Stream of partition messages
    await _partitionSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // insure no partition
    await Partition.partition(powerSyncHost, PartitionStates.none);

    log.info('nemesis: partition: ${PartitionStates.none.name}');
  }

  // start injecting pause/resume
  void _startPause() {
    log.info(
      'nemesis: pause/resume: start listening to stream of pause/resume messages',
    );

    _pauseSubscription = _pauseStream().listen((pauseMessage) async {
      await _locks[Nemeses.pause]!.synchronized(() {
        final Set<Worker> affectedClients;
        switch (pauseMessage) {
          case PauseStates.paused:
            // act on 0 to all clients
            final int numRandomClients = _rng.nextInt(_clients.length + 1);
            affectedClients = _clients.getRandom(numRandomClients);
            break;
          case PauseStates.running:
            affectedClients = _clients;
            break;
        }

        Set<int> affectedClientNums = {};
        for (Worker client in affectedClients) {
          if (Pause.pauseOrResume(client, pauseMessage)) {
            affectedClientNums.add(client.clientNum);
          }
        }

        log.info(
          'nemesis: pause/resume: ${pauseMessage.name}: clients: $affectedClientNums',
        );
      });
    });
  }

  // stop injecting pause/resume
  Future<void> _stopPause() async {
    // stop Stream of pause/resume messages
    await _pauseSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // insure all clients are running
    Set<int> affectedClientNums = {};
    for (Worker client in _clients) {
      if (Pause.pauseOrResume(client, PauseStates.running)) {
        affectedClientNums.add(client.clientNum);
      }
    }

    log.info(
      'nemesis: pause/resume: ${PauseStates.running.name}: clients: $affectedClientNums',
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

/// Partition

enum PartitionStates { none, inbound, outbound, bidirectional }

/// Maintains the partition state.
/// Flip flops between none, initial state, and inbound or outbound or bidirectional.
class PartitionState {
  PartitionStates _state = PartitionStates.none;

  // Flip flop the current state.
  PartitionStates flipFlop() {
    _state = switch (_state) {
      PartitionStates.none =>
        {
          PartitionStates.inbound,
          PartitionStates.outbound,
          PartitionStates.bidirectional,
        }.getRandom(1).first,
      PartitionStates.inbound ||
      PartitionStates.outbound ||
      PartitionStates.bidirectional => PartitionStates.none,
    };

    return _state;
  }
}

/// Static partition traffic functions.
class Partition {
  /// Partition host with partitionType
  static Future<void> partition(
    String host,
    PartitionStates partitionType,
  ) async {
    switch (partitionType) {
      case PartitionStates.none:
        await none();
        break;
      case PartitionStates.inbound:
        await inbound(host);
        break;
      case PartitionStates.outbound:
        await outbound(host);
        break;
      case PartitionStates.bidirectional:
        await bidirectional(host);
        break;
    }
  }

  /// Partition inbound traffic.
  static Future<void> inbound(String host) async {
    final result = await Process.run('/usr/sbin/iptables', [
      '-A',
      'INPUT',
      '-s',
      host,
      '-j',
      'DROP',
      '-w',
    ]);
    if (result.exitCode != 0) {
      throw Exception('Unexpect result from iptables partition: $result');
    }
  }

  /// Partition outbound traffic.
  static Future<void> outbound(String host) async {
    final result = await Process.run('/usr/sbin/iptables', [
      '-A',
      'OUTPUT',
      '-d',
      host,
      '-j',
      'DROP',
      '-w',
    ]);
    if (result.exitCode != 0) {
      throw Exception('Unexpect result from iptables partition: $result');
    }
  }

  /// Partition bidirectional traffic.
  static Future<void> bidirectional(String host) async {
    await inbound(host);
    await outbound(host);
  }

  /// Partition no traffic
  static Future<void> none() async {
    final resultF = await Process.run('/usr/sbin/iptables', ['-F', '-w']);
    if (resultF.exitCode != 0) {
      throw Exception('Unexpect result from iptables -F: $resultF');
    }

    final resultX = await Process.run('/usr/sbin/iptables', ['-X', '-w']);
    if (resultX.exitCode != 0) {
      throw Exception('Unexpect result from iptables -X: $resultX');
    }
  }

  Future<bool> ping(String host) async {
    final result = await Process.run('/usr/bin/ping', [
      '-c',
      '1',
      '-w',
      '1',
      host,
    ]);
    if (result.exitCode == 0) {
      return true;
    } else {
      return false;
    }
  }
}

/// Pause/resume

enum PauseStates { running, paused }

/// Maintains the pause state.
/// Flip flops between running and paused.
class PauseState {
  PauseStates _state = PauseStates.running;

  // Flip flop the current state.
  PauseStates flipFlop() {
    _state = switch (_state) {
      PauseStates.running => PauseStates.paused,
      PauseStates.paused => PauseStates.running,
    };

    return _state;
  }
}

/// Static pause or resume function.
class Pause {
  /// Pause or resume client per pauseType
  static bool pauseOrResume(Worker client, PauseStates pauseType) {
    switch (pauseType) {
      case PauseStates.running:
        return client.resumeIsolate();

      case PauseStates.paused:
        return client.pauseIsolate();
    }
  }
}
