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

/// track reads looking for suspicious reads,
/// e.g. reading previous versions, not reading your own writes
class ReadConsistency {
  final Map<int, String> _prevReads = {};

  bool suspiciousRead(int k, String? currRead) {
    if (currRead == null) {
      // a null read is interpreted as ''
      currRead = '';
    } else {
      // trim []'s
      if (currRead.length <= 2) {
        throw StateError('Invalid value \'$currRead\' for key $k');
      }
      currRead = currRead.substring(1, currRead.length - 1);
    }

    final prevRead = (_prevReads[k] == null) ? '' : _prevReads[k]!;
    _prevReads[k] = currRead;

    // if no previous read, current read cannot be suspicious
    if (prevRead.isEmpty) {
      return false;
    }

    // if current read is the same length or longer than previous read, cannot be suspicious
    if (currRead.length >= prevRead.length) {
      return false;
    }

    // if current read is not a prefix of previous read, cannot be suspicious
    if (!prevRead.startsWith(currRead)) {
      return false;
    }

    // it's suspicious!
    return true;
  }
}
