import 'dart:async';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'log.dart';
import 'ps_endpoint.dart' as pse;
import 'utils.dart' as utils;
import 'worker.dart';

/// Fault injection.
/// Disconnect, connect Workers from PowerSync Service:
///   - --disconnect, db.disconnect()/connect
///   - --interval, 0 <= random <= 2 * interval
class Nemesis {
  final Set<Worker> _clients;
  late final bool _disconnect;
  late final int _interval;
  late final int _maxInterval;

  // disconnect/connect stream
  final ConnectionState _connectionState = ConnectionState();
  late final Stream<ConnectionStates> Function() _disconnectConnectStream;
  late final StreamSubscription<ConnectionStates>
  _disconnectConnectSubscription;

  // Endpoint knows what messages to send
  final pse.PSEndpoint _pse = pse.PSEndpoint();

  final _rng = Random();

  Nemesis(Map<String, dynamic> args, this._clients) {
    _disconnect = args['disconnect'] as bool;
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
  }

  /// start injecting faults
  void start() {
    if (!_disconnect) return;

    log.info('start listening to stream of disconnected/connected messages');

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

      log.info(
        '$connectionStateMessage\'ing clients: ${affectedClients.map((client) => client.clientNum)}',
      );

      final List<Future<Map>> apiFutures = [];
      for (Worker client in affectedClients) {
        apiFutures.add(client.executeApi(disconnectConnectMessage));
      }
      await apiFutures.wait;

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

  /// stop injecting faults
  Future<void> stop() async {
    if (!_disconnect) return;

    // stop Stream of disconnected/connected messages
    await _disconnectConnectSubscription.cancel();

    // let apis catch up
    await utils.futureSleep(1000);

    // insure all clients are connected
    log.info('insuring all clients are connected');
    final List<Future> connectingClients = [];
    for (Worker client in _clients) {
      connectingClients.add(client.executeApi(_pse.connectMessage()));
    }
    await connectingClients.wait;
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
