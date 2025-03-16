import 'package:test/test.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/auth.dart';
import 'package:powersync_endpoint/log.dart';

void main() {
  parseArgs([]);
  initLogging('auth');

  test('Generated token can be verified', () async {
    final token = await generateToken();
    expect(await verifyToken(token), equals(true));
  });
}
