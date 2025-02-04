import 'package:test/test.dart';
import 'package:powersync_endpoint/utils.dart';

void main() {
  test('Suspicious reads are identified', () async {
    final readConsistency = ReadConsistency();
    expect(readConsistency.suspiciousRead(0, null), equals(false));
    expect(readConsistency.suspiciousRead(0, '[0]'), equals(false));
    expect(readConsistency.suspiciousRead(0, '[0 1]'), equals(false));
    expect(readConsistency.suspiciousRead(0, '[2]'), equals(false));
    expect(readConsistency.suspiciousRead(0, '[3]'), equals(false));
    expect(readConsistency.suspiciousRead(1, null), equals(false));
    expect(readConsistency.suspiciousRead(1, '[0]'), equals(false));
    expect(readConsistency.suspiciousRead(1, '[0 1]'), equals(false));
    expect(readConsistency.suspiciousRead(1, '[0]'), equals(true));
    expect(readConsistency.suspiciousRead(1, null), equals(true));
  });
}
