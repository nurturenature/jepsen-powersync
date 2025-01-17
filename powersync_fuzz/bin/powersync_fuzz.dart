import 'dart:async';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_fuzz/args.dart';
import 'package:powersync_fuzz/log.dart';
import 'package:powersync_fuzz/utils.dart';
import 'package:powersync_fuzz/worker.dart';

final _rng = Random();

void main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.info('args: $args');

  // create a set of worker clients
  Set<Worker> clients = {};
  for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
    clients.add(await Worker.spawn(clientNum));
  }

  // a Stream of txns
  final streamOfTxns = Stream<Map>
          // sent every rate ms
          .periodic(
          Duration(milliseconds: args['rate']),
          // using random keys and a sequential value
          (value) => {"key": _rng.nextInt(args['keys']), "value": value})
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

    // close all txns in clients
    log.info('txn closing all txn ports in clients');
    for (Worker client in clients) {
      client.closeTxns();
    }
  });

  // a Stream of api calls
  final streamOfApis = Stream<Map>
          // sent every interval ms
          .periodic(
          Duration(milliseconds: args['interval']),
          // using a random API call
          (count) => {
                'count': count,
                'api': ['disconnect', 'connect'].getRandom(1).first
              })
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
      await client.executeApi({'count': 'final', 'api': 'connect'});
    }

    // close all clients
    log.info('api closing all api ports in clients');
    for (Worker worker in clients) {
      worker.closeApis();
    }
  });
}
