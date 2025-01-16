import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync_fuzz/args.dart';
import 'package:powersync_fuzz/log.dart';
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
  }).onDone(() {
    // quiesce
    log.info('quiesce for 3 seconds...');
    sleep(Duration(seconds: 3));

    // close all clients
    for (Worker worker in clients) {
      worker.close();
    }
  });
}
