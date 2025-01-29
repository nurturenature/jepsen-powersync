import 'dart:io';
import 'dart:isolate';

/// sleep in a separate Isolate to avoid long blocking of async in calling Isolate:
/// https://api.dart.dev/dart-io/sleep.html
Future<void> isolateSleep(int sleepMs) {
  return Isolate.run(() => sleep(Duration(milliseconds: sleepMs)));
}

/// sleep in a Future, internally uses a timer
Future<void> futureSleep(int sleepMs) {
  return Future.delayed(Duration(milliseconds: sleepMs));
}

/// returns a map of diffs {k: {map1: v, map2: v}}, or an empty map if all k/v ==
/// map1 is assumed to be the source of truth, contains all keys, etc
Map<int, Map<String, String?>> mapDiff(String name1, Map<int, String?> map1,
    String name2, Map<int, String?> map2) {
  final Map<int, Map<String, String?>> diffs = {};

  for (int k in map1.keys) {
    final String? v1 = map1[k];
    final String? v2 = map2[k];
    if (v1 != v2) {
      diffs[k] = {name1: v1, name2: v2};
    }
  }
  return diffs;
}
