import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/isolate_endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/postgresql.dart' as pg;
import 'package:powersync_endpoint/utils.dart' as utils;
import 'package:powersync_endpoint/worker.dart';

final _rng = Random();

void main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.info('args: $args');

  // initialize PostgreSQL
  await pg.init(pg.Tables.lww, true);
  log.config(
      'PostgreSQL connection and database initialized, connection: ${pg.postgreSQL}');
  log.config('PostgreSQL lww table: ${await pg.selectAllLWW()}');

  // create a set of worker clients
  log.info('creating ${args["clients"]} clients');
  final List<Future<Worker>> clientFutures = [];
  for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
    clientFutures.add(Worker.spawn(clientNum));
  }
  Set<Worker> clients = Set.from(await clientFutures.wait);

  // Stream of disconnect/connect messages
  final ConnectionState connectionState = ConnectionState();
  Stream<ConnectionStates> disconnectConnectStream() async* {
    final maxInterval = args['interval'] * 1000 * 2; // in ms
    while (true) {
      await utils.futureSleep(_rng.nextInt(maxInterval));
      yield connectionState.flipFlop();
    }
  }

  // each disconnect message from the Stream is individually sent to a random majority of clients
  // each connect message from the Stream is individually sent to all clients
  late StreamSubscription<ConnectionStates> disconnectConnectSubscription;
  if (args['disconnect']) {
    log.info('starting stream of disconnect/connect messages...');
    disconnectConnectSubscription =
        disconnectConnectStream().listen((connectionStateMessage) async {
      late Set<Worker> affectedClients;
      late Map<String, dynamic> disconnectConnectMessage;
      switch (connectionStateMessage) {
        case ConnectionStates.disconnected:
          affectedClients = clients.getRandom((clients.length / 2).ceil());
          disconnectConnectMessage = disconnectMessage();
          break;
        case ConnectionStates.connected:
          affectedClients = clients;
          disconnectConnectMessage = connectMessage();
          break;
      }

      log.info(
          '$connectionStateMessage\'ing clients: ${affectedClients.map((client) => client.getClientNum())}');

      final List<Future<Map>> apiFutures = [];
      for (Worker client in affectedClients) {
        apiFutures.add(
          client.executeApi(disconnectConnectMessage),
        );
      }
      await apiFutures.wait;

      // upload queue count for debugging
      final List<Future<Map>> uploadQueueCountFutures = [];
      for (Worker client in affectedClients) {
        uploadQueueCountFutures
            .add(client.executeApi(uploadQueueCountMessage()));
      }
      await uploadQueueCountFutures.wait;
    });
  }

  // a Stream of sql txn messages
  log.info('starting stream of sql transactions...');
  final sqlTxnStream = Stream<Map<String, dynamic>>
          // sent every tps rate
          .periodic(
          Duration(milliseconds: (1000 / args['rate']).floor()),
          // using reads/appends against random keys with a sequential value
          (value) => rndTxnMessage(value))
      // for a total # of txns
      .take(args['time'] * args['rate']);

  // each sql txn message from the Stream is individually sent to a random client
  sqlTxnStream.listen((sqlTxnMessage) async {
    await clients.random().executeTxn(sqlTxnMessage);
  }).onDone(() async {
    // stop disconnecting/connection
    if (args['disconnect']) {
      await disconnectConnectSubscription.cancel();
    }

    // let txns/apis catch up, TODO: why necessary?
    await utils.futureSleep(1000);

    // insure all clients connected
    if (args['disconnect']) {
      log.info('insuring all clients are connected');
      final List<Future> connectingClients = [];
      for (Worker client in clients) {
        connectingClients.add(client.executeApi(connectMessage()));
      }
      await connectingClients.wait;
    }

    // quiesce
    log.info('quiesce for 3 seconds...');
    await utils.futureSleep(3000);

    // wait for upload queue to be empty
    log.info('wait for upload queue to be empty in clients');
    final List<Future> uploadQueueFutures = [];
    for (Worker client in clients) {
      uploadQueueFutures.addAll([
        client.executeApi(uploadQueueCountMessage()),
        client.executeApi(uploadQueueWaitMessage())
      ]);
    }
    await uploadQueueFutures.wait;

    // wait for downloading to be false
    log.info('wait for downloading to be false in clients');
    final List<Future> downloadingWaits = [];
    for (Worker client in clients) {
      downloadingWaits.add(client.executeApi(downloadingWaitMessage()));
    }
    await downloadingWaits.wait;

    log.info('check for strong convergence in final reads');
    await _checkStrongConvergence(clients);

    // close all client txn/api ports
    for (Worker client in clients) {
      client.closeTxns();
      client.closeApis();
    }

    // done with PostgreSQL
    await pg.close();
  });
}

/// Do a final read of all keys on PostgreSQL and all clients.
/// Treat PostgreSQL as the source of truth and look for differences with each client.
/// Any differences are errors.
Future<void> _checkStrongConvergence(Set<Worker> clients) async {
  // {pg: {k: v}    k/v for any diffs in any ps-#
  //  ps-#: {k: v}}  k/v for this ps-# diff than pg
  final Map<String, Map<int, String>> divergent = SplayTreeMap();
  final Map<int, String> finalPgRead = await pg.selectAllLWW();
  for (Worker client in clients) {
    final Map<int, String> finalPsRead =
        (await client.executeApi(selectAllMessage()))['value']['v'];
    for (final int k in finalPgRead.keys) {
      final pgV = finalPgRead[k]!;
      final psV = finalPsRead[k]!;
      if (pgV != psV) {
        divergent.update(
          'pg',
          (inner) {
            inner.addAll({k: pgV});
            return inner;
          },
          ifAbsent: () => SplayTreeMap.from({k: pgV}),
        );
        divergent.update('ps-${client.getClientNum()}', (inner) {
          inner.addAll({k: psV});
          return inner;
        }, ifAbsent: () => SplayTreeMap.from({k: psV}));
      }
    }
  }

  if (divergent.isEmpty) {
    log.info('Strong Convergence on final reads! :)');
  } else {
    log.severe('Divergent final reads!:');
    for (final node in divergent.entries) {
      log.severe(node.key);
      for (final kv in node.value.entries) {
        final k = kv.key;
        final v = kv.value;
        log.severe('\t{$k: $v}');
      }
    }
    log.severe(':(');
    exit(127);
  }
}
