import 'dart:async';
import 'dart:io';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_fuzz/args.dart';
import 'package:powersync_fuzz/endpoint.dart';
import 'package:powersync_fuzz/log.dart';
import 'package:powersync_fuzz/postgresql.dart' as pg;
import 'package:powersync_fuzz/utils.dart';
import 'package:powersync_fuzz/worker.dart';

void main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.info('args: $args');

  // initialize PostgreSQL
  await pg.init();
  log.info(
      'PostgreSQL connection and database initialized, connection: ${pg.postgreSQL}');

  // create a set of worker clients
  Set<Worker> clients = {};
  for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
    clients.add(await Worker.spawn(clientNum));
  }

  // a Stream of txns
  final streamOfTxns = Stream<Map<String, dynamic>>
          // sent every rate ms
          .periodic(
          Duration(milliseconds: args['rate']),
          // using random keys and a sequential value
          (count) => rndTxnMessage(count))
      // for a total # of txns
      .take(args['txns']);

  // each txn from the Stream is individually sent to a random client
  streamOfTxns.listen((txn) async {
    await clients.random().executeTxn(txn);
  }).onDone(() async {
    // let txns catch up, TODO: why necessary?
    await isolateSleep(1000);

    // quiesce
    log.info('txn quiesce for 3 seconds...');
    await isolateSleep(3000);

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

  // a Stream of api calls
  final streamOfApis = Stream<Map<String, dynamic>>
          // sent every interval ms
          .periodic(
          Duration(milliseconds: args['interval']),
          // using a random API call
          (_) => rndConnectOrDisconnectMessage())
      // for a total # of api calls, should finish before txn stream
      .take(((args['txns'] * args['rate'] / args['interval']) - 1).floor());

  // each api call from the Stream is individually sent to a random majority of clients
  streamOfApis.listen((api) async {
    final majorityClients = clients.getRandom((args['clients'] / 2).ceil());
    for (Worker client in majorityClients) {
      await client.executeApi(api);
    }
  }).onDone(() async {
    // let api catch up, TODO: why necessary?
    await isolateSleep(1000);

    // insure all clients connected
    log.info('api connecting all clients');
    for (Worker client in clients) {
      await client.executeApi(connectMessage());
    }
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
