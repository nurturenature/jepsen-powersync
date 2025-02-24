import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:list_utilities/list_utilities.dart';
import 'log.dart';
import 'ps_endpoint.dart' as pse;
import 'utils.dart' as utils;
import 'worker.dart';

/// Fault injection.
/// Disconnect, connect, Workers from PowerSync Service:
///   - --disconnect, db.disconnect()/connect
///   - --interval, 0 <= random <= 2 * interval
/// Partition Workers from PowerSync Service:
///   - --partition, random inbound or outbound or bidirectional
///   - --interval, 0 <= random <= 2 * interval
/// Pause, resume, Worker Isolates:
///   - --pause, Isolate.pause()/resume()
///   - --interval, 0 <= random <= 2 * interval
class Nemesis {
  final Set<Worker> _clients;
  late final int _interval;
  late final int _maxInterval;

  // disconnect/connect
  late final bool _disconnect;
  final ConnectionState _connectionState = ConnectionState();
  late final Stream<ConnectionStates> Function() _disconnectConnectStream;
  late final StreamSubscription<ConnectionStates>
  _disconnectConnectSubscription;

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

  // Endpoint knows what messages to send
  final pse.PSEndpoint _pse = pse.PSEndpoint();

  // source of randomness
  final _rng = Random();

  Nemesis(Map<String, dynamic> args, this._clients) {
    _disconnect = args['disconnect'] as bool;
    _partition = args['partition'] as bool;
    _pause = args['pause'] as bool;
    _interval = args['interval'] as int;
    _maxInterval = _interval * 1000 * 2;

    // Stream of ConnectionStates, flip flops between disconnected and connected
    // Stream will not emit messages until listened to
    _disconnectConnectStream = () async* {
      while (true) {
        await utils.futureSleep(_rng.nextInt(_maxInterval + 1));
        yield _connectionState.flipFlop();
      }
    };

    // Stream of PartitionStates, flip flops between none and inbound or outbound or bidirectional
    // Stream will not emit messages until listened to
    _partitionStream = () async* {
      while (true) {
        await utils.futureSleep(_rng.nextInt(_maxInterval + 1));
        yield _partitionState.flipFlop();
      }
    };

    // Stream of PauseStates, flip flops between running and paused
    // Stream will not emit messages until listened to
    _pauseStream = () async* {
      while (true) {
        await utils.futureSleep(_rng.nextInt(_maxInterval + 1));
        yield _pauseState.flipFlop();
      }
    };
  }

  /// start injecting faults
  void start() {
    if (_disconnect) _startDisconnect();
    if (_partition) _startPartition();
    if (_pause) _startPause();
  }

  /// stop injecting faults
  Future<void> stop() async {
    if (_disconnect) await _stopDisconnect();
    if (_partition) await _stopPartition();
    if (_pause) await _stopPause();
  }

  // start injecting disconnect/connect
  void _startDisconnect() {
    log.info(
      'nemesis: disconnect/connect: start listening to stream of disconnected/connected messages',
    );

    _disconnectConnectSubscription = _disconnectConnectStream().listen((
      connectionStateMessage,
    ) async {
      late final Set<Worker> affectedClients;
      late final Map<String, dynamic> disconnectConnectMessage;
      switch (connectionStateMessage) {
        case ConnectionStates.disconnected:
          // act on 0 to all clients
          final int numRandomClients = _rng.nextInt(_clients.length + 1);
          affectedClients = _clients.getRandom(numRandomClients);
          disconnectConnectMessage = _pse.disconnectMessage();
          break;
        case ConnectionStates.connected:
          affectedClients = _clients;
          disconnectConnectMessage = _pse.connectMessage();
          break;
      }

      final List<Future<Map>> apiFutures = [];
      for (Worker client in affectedClients) {
        apiFutures.add(client.executeApi(disconnectConnectMessage));
      }
      await apiFutures.wait;

      log.info(
        'nemesis: disconnect/connect: ${connectionStateMessage.name}: clients: ${affectedClients.map((client) => client.clientNum)}',
      );

      // log upload queue count for debugging
      final List<Future<Map>> uploadQueueCountFutures = [];
      for (Worker client in affectedClients) {
        uploadQueueCountFutures.add(
          client.executeApi(_pse.uploadQueueCountMessage()),
        );
      }
      await uploadQueueCountFutures.wait;
    });
  }

  // stop injecting disconnect/connect
  Future<void> _stopDisconnect() async {
    // stop Stream of disconnected/connected messages
    await _disconnectConnectSubscription.cancel();

    // let apis catch up
    await utils.futureSleep(1000);

    // insure all clients are connected
    final List<Future> connectingClients = [];
    for (Worker client in _clients) {
      connectingClients.add(client.executeApi(_pse.connectMessage()));
    }
    await connectingClients.wait;

    log.info(
      'nemesis: disconnect/connect: ${ConnectionStates.connected.name}: clients: all',
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
      await Partition.partition(powerSyncHost, partitionStateMessage);

      log.info('nemesis: partition: ${partitionStateMessage.name}');
    });
  }

  // stop injecting partition
  Future<void> _stopPartition() async {
    // stop Stream of partition messages
    await _partitionSubscription.cancel();

    // let apis catch up
    await utils.futureSleep(1000);

    // insure no partition
    await Partition.partition(powerSyncHost, PartitionStates.none);

    log.info('nemesis: partition: ${PartitionStates.none.name}');
  }

  // start injecting pause/resume
  void _startPause() {
    log.info(
      'nemesis: pause/resume: start listening to stream of pause/resume messages',
    );

    _pauseSubscription = _pauseStream().listen((pauseMessage) {
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
  }

  // stop injecting pause/resume
  Future<void> _stopPause() async {
    // stop Stream of pause/resume messages
    await _pauseSubscription.cancel();

    // let apis catch up
    await utils.futureSleep(1000);

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

/// Disconnected/connected

enum ConnectionStates { connected, disconnected }

class ConnectionState {
  ConnectionStates _state = ConnectionStates.connected;

  // Flip flop the current state.
  ConnectionStates flipFlop() {
    _state = switch (_state) {
      ConnectionStates.connected => ConnectionStates.disconnected,
      ConnectionStates.disconnected => ConnectionStates.connected,
    };
    return _state;
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
