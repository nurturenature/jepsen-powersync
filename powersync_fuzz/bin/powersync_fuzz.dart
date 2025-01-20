import 'dart:async';
import 'dart:io';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_fuzz/args.dart';
import 'package:powersync_fuzz/endpoint.dart';
import 'package:powersync_fuzz/log.dart';
import 'package:powersync_fuzz/postgresql.dart' as pg;
import 'package:powersync_fuzz/utils.dart' as utils;
import 'package:powersync_fuzz/worker.dart';

void main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.config('args: $args');

  // initialize PostgreSQL
  await pg.init();
  log.config(
      'PostgreSQL connection and database initialized, connection: ${pg.postgreSQL}');
  log.config('PostgreSQL lww table: ${await pg.selectAll('lww')}');

  // create a set of worker clients
  log.info('creating ${args["clients"]} clients');
  final List<Future<Worker>> clientFutures = [];
  for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
    clientFutures.add(Worker.spawn(clientNum));
  }
  Set<Worker> clients = Set.from(await clientFutures.wait);

  // Stream of disconnect/connect messages
  final disconnectConnectStream = Stream<Map<String, dynamic>>
      // sent every interval seconds
      .periodic(
      Duration(seconds: args['interval']),
      // with a random disconnect/connect message
      (_) => rndConnectOrDisconnectMessage());

  // each disconnect/connect message from the Stream is individually sent to a random majority of clients
  final disconnectConnectSubscription =
      disconnectConnectStream.listen((disconnectOrConnectMessage) async {
    final majorityClients = clients.getRandom((clients.length / 2).ceil());
    final List<Future<Map>> apiFutures = [];
    for (Worker client in majorityClients) {
      apiFutures.addAll([
        client.executeApi(
            disconnectOrConnectMessage), // random disconnect or connect
        client.executeApi(
            uploadQueueCountMessage()) // upload queue count for debugging
      ]);
    }
    await apiFutures.wait;
  });

  // a Stream of sql txn messages
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
    await disconnectConnectSubscription.cancel();

    // let txns/apis catch up, TODO: why necessary?
    await utils.isolateSleep(1000);

    // insure all clients connected
    log.info('insuring all clients are connected');
    final List<Future> connectingClients = [];
    for (Worker client in clients) {
      connectingClients.add(client.executeApi(connectMessage()));
    }
    await connectingClients.wait;

    // quiesce
    log.info('quiesce for 3 seconds...');
    await utils.isolateSleep(3000);

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
    log.info('closing all txn/api ports in clients');
    for (Worker client in clients) {
      client.closeTxns();
      client.closeApis();
    }

    // done with PostgreSQL
    log.info('closing PostgreSQL');
    await pg.close();
  });
}

/// Do a final read of all keys on PostgreSQL and all clients.
/// Treat PostgreSQL as the source of truth and look for differences with each client.
/// Any differences are errors.
Future<void> _checkStrongConvergence(Set<Worker> clients) async {
  final finalPgRead = await pg.selectAll('lww');
  final Map<int, Map<int, String>> finalPsReads = {};
  for (Worker client in clients) {
    finalPsReads.addAll({
      client.getClientNum():
          (await client.executeApi(selectAllMessage()))['value']['v']
    });
  }
  log.info('finalPgRead: $finalPgRead');
  log.info('finalPsReads: $finalPsReads');

  // {clientNum: {k: {pg: 'pg value', ps: 'ps value'}}}
  final divergent = {};
  for (var client in clients) {
    final clientNum = client.getClientNum();
    final ps = finalPsReads[clientNum]!;
    final diffs = {};
    for (var k = 0; k < args['keys']; k++) {
      final pgV = finalPgRead[k];
      final psV = ps[k];
      if (pgV != psV) {
        diffs.addAll({
          k: {'pg': pgV, 'ps': psV}
        });
      }
    }
    if (diffs.isNotEmpty) {
      divergent[clientNum] = diffs;
    }
  }

  if (divergent.isEmpty) {
    log.info('strong convergence on final reads! :)');
  } else {
    log.severe('divergent final reads!: $divergent :(');
    exit(127);
  }
}
