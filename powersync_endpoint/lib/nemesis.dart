import 'dart:async';
import 'nemesis/disconnect.dart';
import 'nemesis/kill.dart';
import 'nemesis/partition.dart';
import 'nemesis/pause.dart';
import 'nemesis/stop.dart';
import 'worker.dart';

/// Fault injection.
/// Disconnect, connect, Workers from PowerSync Service:
///   - --disconnect [none | orderly | random] db.disconnect()/connect
///   - --interval, 0 <= random <= 2 * interval
/// Stop, start, Worker Isolates:
///   - --stop, db.close(), Isolate.kill()
///   - --interval, 0 <= random <= 2 * interval
/// Kill, start, Worker Isolates:
///   - --stop, Isolate.terminate(immediate), no warning/interaction w/Powersync
///   - --interval, 0 <= random <= 2 * interval
/// Partition Workers from PowerSync Service:
///   - --partition, random inbound or outbound or bidirectional
///   - --interval, 0 <= random <= 2 * interval
/// Pause, resume, Worker Isolates:
///   - --pause, Isolate.pause()/resume()
///   - --interval, 0 <= random <= 2 * interval
class Nemesis {
  final Set<int> _allClientNums = {};
  final Set<Worker> _clients;
  late final int _interval;

  // disconnect/connect
  late final DisconnectNemeses _disconnect;
  late final DisconnectNemesis _disconnectNemesis;

  // stop/start
  late final bool _stopStart;
  late final StopStartNemesis _stopStartNemesis;

  // kill/start
  late final bool _killStart;
  late final KillStartNemesis _killStartNemesis;

  // partition
  late final bool _partition;
  late final PartitionNemesis _partitionNemesis;

  // pause/resume
  late final bool _pauseResume;
  late final PauseResumeNemesis _pauseResumeNemesis;

  Nemesis(Map<String, dynamic> args, this._clients) {
    // set of all possible client nums
    for (var clientNum = 1; clientNum <= args['clients']; clientNum++) {
      _allClientNums.add(clientNum);
    }
    if (args['postgresql']) _allClientNums.add(0);

    // CLI args
    _disconnect = args['disconnect'] as DisconnectNemeses;
    _stopStart = args['stop'] as bool;
    _killStart = args['kill'] as bool;
    _partition = args['partition'] as bool;
    _pauseResume = args['pause'] as bool;
    _interval = args['interval'] as int;

    // only create a DisconnectNemesis if needed
    if (_disconnect != DisconnectNemeses.none) {
      _disconnectNemesis = DisconnectNemesis(_disconnect, _clients, _interval);
    }

    // only create a StopStartNemesis if needed
    if (_stopStart) {
      _stopStartNemesis = StopStartNemesis(_clients, _interval);
    }

    // only create a PartitionNemesis if needed
    if (_partition) {
      _partitionNemesis = PartitionNemesis(_interval);
    }

    // only create a PauseResumeNemesis if needed
    if (_pauseResume) {
      _pauseResumeNemesis = PauseResumeNemesis(_clients, _interval);
    }

    // only create a KillStartNemesis if needed
    if (_killStart) {
      _killStartNemesis = KillStartNemesis(_clients, _interval);
    }
  }

  /// start injecting faults
  void start() {
    if (_disconnect != DisconnectNemeses.none) {
      _disconnectNemesis.startDisconnect();
    }
    if (_stopStart) _stopStartNemesis.startStopStart();
    if (_killStart) _killStartNemesis.startKillStart();
    if (_partition) _partitionNemesis.startPartition();
    if (_pauseResume) _pauseResumeNemesis.startPause();
  }

  /// stop injecting faults
  Future<void> stop() async {
    if (_disconnect != DisconnectNemeses.none) {
      await _disconnectNemesis.stopDisconnect();
    }
    if (_stopStart) await _stopStartNemesis.stopStopStart();
    if (_killStart) await _killStartNemesis.stopKillStart();
    if (_partition) await _partitionNemesis.stopPartition();
    if (_pauseResume) await _pauseResumeNemesis.stopPause();
  }
}
