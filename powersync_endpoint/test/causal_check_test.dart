import 'package:test/test.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/causal_checker.dart';
import 'package:powersync_endpoint/log.dart';

void main() {
  parseArgs(['--table', 'mww']);
  initLogging('causal');

  test('Causal Consistency', () async {
    final causalChecker = CausalChecker(3, 100);
    final Map<String, dynamic> baseOp = {
      'type': 'ok',
      'f': 'txn',
      'table': 'mww',
      'clientNum': 1
    };

    // invalid read of unwritten value
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(false));

    // valid null read
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': -1}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));

    // read of own write 0/0 in same txn
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': -1},
        {'f': 'append', 'k': 0, 'v': 0},
        {'f': 'r', 'k': 0, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));

    // read of own write 0/1 in next txn
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': 0},
        {'f': 'append', 'k': 0, 'v': 1}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': 1}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));

    // failure to read own write 0/2 in next txn
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': 1},
        {'f': 'append', 'k': 0, 'v': 2},
        {'f': 'r', 'k': 0, 'v': 2}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
    baseOp.addAll({
      'value': [
        {'f': 'r', 'k': 0, 'v': 1}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(false));

    // invalid writes follow reads
    baseOp.addAll({
      'clientNum': 2,
      'value': [
        {'f': 'r', 'k': 0, 'v': 2},
        {'f': 'append', 'k': 1, 'v': 0},
        {'f': 'r', 'k': 1, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
    baseOp.addAll({
      'clientNum': 3,
      'value': [
        {'f': 'r', 'k': 1, 'v': 0},
        {'f': 'r', 'k': 0, 'v': 1}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(false));

    // valid writes follow reads
    baseOp.addAll({
      'clientNum': 1,
      'value': [
        {'f': 'append', 'k': 2, 'v': 0},
        {'f': 'r', 'k': 2, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
    baseOp.addAll({
      'clientNum': 2,
      'value': [
        {'f': 'r', 'k': 2, 'v': 0},
        {'f': 'append', 'k': 3, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
    baseOp.addAll({
      'clientNum': 3,
      'value': [
        {'f': 'r', 'k': 3, 'v': 0},
        {'f': 'r', 'k': 2, 'v': 0}
      ]
    });
    expect(causalChecker.checkOp(baseOp), equals(true));
  });
}
