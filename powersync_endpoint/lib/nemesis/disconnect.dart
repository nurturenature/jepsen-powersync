import 'dart:async';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import '../endpoint.dart';
import '../log.dart';
import '../utils.dart' as utils;
import '../worker.dart';

/// Types of disconnect nemeses:
/// - orderly: disconnect and then connect specific clients
/// - random: disconnect or connect random clients
enum DisconnectNemeses { none, orderly, random }

final disconnectNemesesLookup = DisconnectNemeses.values.asNameMap();

class DisconnectNemesis {
  final DisconnectNemeses _nemesisType;
  final Set<Worker> _allClients;
  final Set<int> _disconnectedClientNums = {};

  late final Stream<DisconnectStates> Function() _disconnectConnectStream;
  late final StreamSubscription<DisconnectStates>
  _disconnectConnectSubscription;

  final _rng = Random();
  final _lock = Lock();

  DisconnectNemesis(this._nemesisType, this._allClients, interval) {
    final maxInterval = interval * 1000 * 2;
    final DisconnectState disconnectState = DisconnectState();

    // Stream of DisconnectedStates, flip flops between disconnected and connected
    // Stream will not emit messages until listened to
    _disconnectConnectStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(maxInterval + 1));
        yield await _lock.synchronized<DisconnectStates>(() {
          return disconnectState.flipFlop();
        });
      }
    };
  }

  Set<Worker> _selectClientsToDisconnect(
    DisconnectNemeses nemesisType,
    Set<Worker> clients,
  ) {
    // for now, everyone behaves the same
    switch (nemesisType) {
      case DisconnectNemeses.orderly || DisconnectNemeses.random:
        // act on 0 to all clients
        final int numRandomClients = _rng.nextInt(clients.length + 1);
        return clients.getRandom(numRandomClients);

      case DisconnectNemeses.none:
        throw StateError(
          'DisconnectNemesis type is ${DisconnectNemeses.none.name} yet attempting nemesis activity',
        );
    }
  }

  Set<Worker> _selectClientsToConnect(
    DisconnectNemeses nemesisType,
    Set<Worker> clients,
    Set<int> disconnectedClientNums,
  ) {
    switch (nemesisType) {
      case DisconnectNemeses.orderly:
        // only act on disconnected clients
        return clients
            .where(
              (client) => disconnectedClientNums.contains(client.clientNum),
            )
            .toSet();

      case DisconnectNemeses.random:
        // act on 0 to all clients
        final int numRandomClients = _rng.nextInt(clients.length + 1);
        return clients.getRandom(numRandomClients);

      case DisconnectNemeses.none:
        throw StateError(
          'DisconnectNemesis type is ${DisconnectNemeses.none.name} yet attempting nemesis activity',
        );
    }
  }

  // start injecting disconnect/connect
  void startDisconnect() {
    log.info(
      'nemesis: disconnect/connect: start listening to stream of disconnected/connected messages',
    );

    _disconnectConnectSubscription = _disconnectConnectStream().listen((
      connectionStateMessage,
    ) async {
      await _lock.synchronized(() async {
        // what clients to act on?
        final Set<Worker> actOnClients = switch (connectionStateMessage) {
          DisconnectStates.disconnected => _selectClientsToDisconnect(
            _nemesisType,
            _allClients,
          ),
          DisconnectStates.connected => _selectClientsToConnect(
            _nemesisType,
            _allClients,
            _disconnectedClientNums,
          ),
        };

        // act on clients
        final Set<int> affectedClientNums =
            await DisconnectConnect.disconnectOrConnect(
              actOnClients,
              connectionStateMessage,
            );

        // keep track of disconnected clients
        switch (connectionStateMessage) {
          case DisconnectStates.disconnected:
            _disconnectedClientNums.addAll(affectedClientNums);
            break;
          case DisconnectStates.connected:
            _disconnectedClientNums.removeAll(affectedClientNums);
            break;
        }

        log.info(
          'nemesis: disconnect/connect: ${connectionStateMessage.name}: clients: $affectedClientNums',
        );
      });
    });
  }

  // stop injecting disconnect/connect
  Future<void> stopDisconnect() async {
    log.info(
      'nemesis: disconnect/connect: stop listening to stream of disconnected/connected messages',
    );

    // stop Stream of disconnected/connected messages
    await _disconnectConnectSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // only act on disconnected clients
    final actOnClients =
        _allClients
            .where(
              (client) => _disconnectedClientNums.contains(client.clientNum),
            )
            .toSet();

    // act on clients
    final Set<int> affectedClientNums =
        await DisconnectConnect.disconnectOrConnect(
          actOnClients,
          DisconnectStates.connected,
        );

    log.info(
      'nemesis: disconnect/connect: ${DisconnectStates.connected.name}: clients: $affectedClientNums',
    );
  }
}

enum DisconnectStates { connected, disconnected }

/// flip flops between connected and disconnected DisconnectStates
class DisconnectState {
  DisconnectStates _state = DisconnectStates.connected;

  // Flip flop the current state.
  DisconnectStates flipFlop() {
    _state = switch (_state) {
      DisconnectStates.connected => DisconnectStates.disconnected,
      DisconnectStates.disconnected => DisconnectStates.connected,
    };

    return _state;
  }
}

/// Static disconnect or connect function.
class DisconnectConnect {
  /// Disconnect or connect clients per disconnectState.
  /// Returns Set of affected clientNums.
  static Future<Set<int>> disconnectOrConnect(
    Set<Worker> clients,
    DisconnectStates disconnectState,
  ) async {
    final disconnectConnectMessage = switch (disconnectState) {
      DisconnectStates.disconnected => Endpoint.disconnectMessage(),
      DisconnectStates.connected => Endpoint.connectMessage(),
    };

    // act on clients in parallel
    final List<Future<Map>> apiFutures = [];
    for (final client in clients) {
      // leave PostgreSQL client as is
      if (client.clientNum == 0) continue;

      apiFutures.add(client.executeApi(disconnectConnectMessage));
    }
    await apiFutures.wait;

    // client nums of clients actually acted on
    final Set<int> affectedClientNums = {};
    for (final apiFuture in apiFutures) {
      final result = await apiFuture;
      if (result['type'] == 'ok') {
        affectedClientNums.add(result['clientNum']);
      } else {
        log.severe(
          'nemesis: disconnect/connect: ${disconnectState.name}: error: $result',
        );
      }
    }

    return affectedClientNums;
  }
}
