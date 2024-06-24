import 'package:test/test.dart';

import 'package:powersync_endpoint/auth.dart';

void main() {
  test('Generated token can be verified', () async {
    final token = await generateToken();
    expect(await verifyToken(token), equals(true));
  });
}
