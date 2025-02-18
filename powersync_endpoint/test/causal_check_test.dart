import 'package:test/test.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/causal_checker.dart';
import 'package:powersync_endpoint/log.dart';

void main() {
  parseArgs(['--table', 'mww', '--clients', '3', '--keys', '3']);
  initLogging('causal');

  test('Causal Consistency', () async {
    CausalChecker causalChecker;
    final Map<String, dynamic> baseOp = {
      'type': 'ok',
      'f': 'txn',
      'table': 'mww',
      'clientType': 'ps',
      'clientNum': 1,
    };

    causalChecker = CausalChecker(args['clients'], args['keys']);
    final Map<String, dynamic> readOfUnwritten = Map.from(baseOp);
    readOfUnwritten.addAll({
      'value': [
        {
          'f': 'read-all',
          'k': -1,
          'v': {0: 0},
        },
      ],
    });

    expect(causalChecker.checkOp(readOfUnwritten), false);
  });
}
