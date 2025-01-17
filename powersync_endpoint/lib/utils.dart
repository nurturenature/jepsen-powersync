import 'dart:io';
import 'dart:isolate';

/// sleep in a separate Isolate to avoid long blocking of async in calling Isolate:
/// https://api.dart.dev/dart-io/sleep.html
Future<void> isolateSleep(int sleepMs) {
  return Isolate.run(() => sleep(Duration(milliseconds: sleepMs)));
}
