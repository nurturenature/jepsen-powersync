/// sleep in a Future, internally uses a timer
Future<void> futureSleep(int sleepMs) {
  return Future.delayed(Duration(milliseconds: sleepMs));
}

/// returns a map of diffs {k: {map1: v, map2: v}}, or an empty map if all k/v ==
/// map1 is assumed to be the source of truth, contains all keys, etc
Map<int, Map<String, dynamic>> mapDiff(
  String name1,
  Map<int, dynamic> map1,
  String name2,
  Map<int, dynamic> map2,
) {
  final Map<int, Map<String, dynamic>> diffs = {};

  for (int k in map1.keys) {
    final v1 = map1[k];
    final v2 = map2[k];
    if (v1 != v2) {
      diffs[k] = {name1: v1, name2: v2};
    }
  }
  return diffs;
}
