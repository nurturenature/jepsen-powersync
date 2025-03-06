import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/causal_checker.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/nemesis.dart';
import 'package:powersync_endpoint/utils.dart' as utils;
import 'package:powersync_endpoint/worker.dart';

void main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.config('args: $args');

  // create a set of worker clients
  log.info('creating ${args["clients"]} clients');
  final List<Future<Worker>> clientFutures = [];
  for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
    clientFutures.add(Worker.spawn(Endpoints.powersync, clientNum));
  }
  Set<Worker> clients = Set.from(await clientFutures.wait);

  // include PostgreSQL client in pool of Workers?
  if (args['postgresql']) {
    clients.add(await Worker.spawn(Endpoints.postgresql, 0));
  }

  // create a causal consistency checker
  final causalChecker = CausalChecker(args['clients'], args['keys']);

  // nemesis to disconnect/connect, partition, Workers from PowerSync service
  final nemesis = Nemesis(args, clients);
  nemesis.start();

  // a Stream of sql txn messages
  log.info('starting stream of sql transactions...');
  final sqlTxnStream = Stream<SplayTreeMap<String, dynamic>>
  // sent every tps rate
  .periodic(
    Duration(milliseconds: (1000 / args['rate']).floor()),
    // using reads/appends against random keys with a sequential value
    (value) => Endpoint.readAllWriteSomeTxnMessage(args['maxTxnLen'], value),
  )
  // for a total # of txns
  .take(args['time'] * args['rate']);

  // each sql txn message from the Stream is individually sent to a random client
  sqlTxnStream
      .listen((sqlTxnMessage) async {
        // may be no active clients due to nemesis activities, if so ignore op
        if (clients.isEmpty) {
          log.fine(
            'SQL txn: no active clients, so ignoring SQL transaction op: $sqlTxnMessage',
          );
          return;
        }

        final op =
            await clients.random().executeTxn(sqlTxnMessage)
                as SplayTreeMap<String, dynamic>;

        if (!await causalChecker.checkOp(op)) {
          log.severe('Causal Consistency check failed for op: $op');
          exit(2);
        }
      })
      .onDone(() async {
        // stop disconnect/connect, partition, nemeses
        await nemesis.stop();

        // quiesce
        log.info('quiesce for 3 seconds...');
        await utils.futureSleep(3000);

        // wait for upload queue to be empty
        log.info('wait for upload queue to be empty in clients');
        final List<Future> uploadQueueFutures = [];
        for (Worker client in clients) {
          uploadQueueFutures.addAll([
            client.executeApi(Endpoint.uploadQueueCountMessage()),
            client.executeApi(Endpoint.uploadQueueWaitMessage()),
          ]);
        }
        await uploadQueueFutures.wait;

        // wait for downloading to be false
        log.info('wait for downloading to be false in clients');
        final List<Future> downloadingWaits = [];
        for (Worker client in clients) {
          downloadingWaits.add(
            client.executeApi(Endpoint.downloadingWaitMessage()),
          );
        }
        await downloadingWaits.wait;

        log.info('check for strong convergence in final reads');
        await checkStrongConvergence(clients);

        // close all client txn/api ports
        for (Worker client in clients) {
          client.closeTxns();
          client.closeApis();
        }
      });
}
