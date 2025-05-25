import 'package:test/test.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/causal_checker.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';

void main() {
  parseArgs(['--clients', '3', '--keys', '3']);
  initLogging('causal');

  test('Causal Consistency', () async {
    CausalChecker causalChecker;
    final Map<String, dynamic> baseOp = {
      'type': 'ok',
      'f': 'txn',
      'clientType': 'ps',
      'clientNum': 1,
    };

    // read of unwritten value
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> readOfUnwritten = Map.from(baseOp);
    readOfUnwritten.addAll({
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: -2},
        },
      ],
    });
    expect(await causalChecker.checkOp(readOfUnwritten), false);

    // duplicate write
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> duplicateWrite = Map.from(baseOp);
    duplicateWrite.addAll({
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(duplicateWrite), true);
    duplicateWrite.addAll({
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0, 1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(duplicateWrite), false);

    // reading your own writes
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> readYourWrites = Map.from(baseOp);
    readYourWrites.addAll({
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0, 1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(readYourWrites), true);
    readYourWrites.addAll({
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 0, 1: 0, 2: -1},
        },
      ],
    });
    expect(await causalChecker.checkOp(readYourWrites), true);

    // not reading your own writes
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> failReadYourWrites = Map.from(baseOp);
    failReadYourWrites.addAll({
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0, 1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(failReadYourWrites), true);
    failReadYourWrites.addAll({
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 0, 1: -1, 2: -1},
        },
      ],
    });
    expect(await causalChecker.checkOp(failReadYourWrites), false);

    // monotonic writes
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> monotonicWrites = Map.from(baseOp);
    monotonicWrites.addAll({
      'clientNum': 1,
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(monotonicWrites), true);
    monotonicWrites.addAll({
      'clientNum': 1,
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 1, 1: 0},
        },
      ],
    });
    monotonicWrites.addAll({
      'clientNum': 1,
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 2, 1: 1, 2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(monotonicWrites), true);
    monotonicWrites.addAll({
      'clientNum': 2,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 2, 1: 1, 2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(monotonicWrites), true);
    monotonicWrites.addAll({
      'clientNum': 2,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 1, 1: 0, 2: -1},
        },
      ],
    });
    expect(await causalChecker.checkOp(monotonicWrites), false);

    // writes follow reads
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> writesFollowReads = Map.from(baseOp);
    writesFollowReads.addAll({
      'clientNum': 1,
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0, 1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(writesFollowReads), true);
    writesFollowReads.addAll({
      'clientNum': 2,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 0, 1: 0, 2: -1},
        },
        {
          'f': SQLTransactions.writeSome.name,
          'v': {2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(writesFollowReads), true);
    writesFollowReads.addAll({
      'clientNum': 3,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 0, 1: 0, 2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(writesFollowReads), true);

    // not writes follow reads
    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> failWritesFollowReads = Map.from(baseOp);
    failWritesFollowReads.addAll({
      'clientNum': 1,
      'value': [
        {
          'f': SQLTransactions.writeSome.name,
          'v': {0: 0, 1: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(failWritesFollowReads), true);
    failWritesFollowReads.addAll({
      'clientNum': 2,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: 0, 1: 0, 2: -1},
        },
        {
          'f': SQLTransactions.writeSome.name,
          'v': {2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(failWritesFollowReads), true);
    failWritesFollowReads.addAll({
      'clientNum': 3,
      'value': [
        {
          'f': SQLTransactions.readAll.name,
          'v': {0: -1, 1: 0, 2: 0},
        },
      ],
    });
    expect(await causalChecker.checkOp(failWritesFollowReads), false);
  });
}
