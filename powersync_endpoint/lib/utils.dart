/// Graceful way to delay execution. Use of sleep in an Isolate is problematic.
Future<void> futureDelay(int delayMs) {
  return Future.delayed(Duration(milliseconds: delayMs));
}

/// PowerSync DB API timeout value.
const powerSyncTimeoutDuration = Duration(seconds: 3);
