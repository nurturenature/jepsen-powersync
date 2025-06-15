import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import '../errors.dart';
import '../log.dart';
import '../utils.dart' as utils;

enum _PartitionStates { none, inbound, outbound, bidirectional }

/// Partition nemesis.
class PartitionNemesis {
  late final Stream<_PartitionStates> Function() _partitionStream;
  late final StreamSubscription<_PartitionStates> _partitionSubscription;

  final _rng = Random();
  final _lock = Lock();

  PartitionNemesis(int interval) {
    final maxInterval = interval * 1000 * 2;
    final partitionState = _PartitionState();

    // Stream of PartitionStates, flip flops between none and inbound or outbound or bidirectional
    // Stream will not emit messages until listened to
    _partitionStream = () async* {
      while (true) {
        await utils.futureDelay(_rng.nextInt(maxInterval + 1));
        yield await _lock.synchronized<_PartitionStates>(() {
          return partitionState._flipFlop();
        });
      }
    };
  }

  // start injecting partition messages
  void startPartition() {
    const powerSyncHost = 'powersync';
    const postgreSQLHost = 'pg-db';

    log.info(
      'nemesis: partition: start listening to stream of partition messages',
    );

    _partitionSubscription = _partitionStream().listen((
      partitionStateMessage,
    ) async {
      log.info('nemesis: partition: starting: ${partitionStateMessage.name}');

      late final Set<String> partitionedHosts;
      await _lock.synchronized(() async {
        switch (partitionStateMessage) {
          case _PartitionStates.none:
            await _partitionNone();
            partitionedHosts = {};
            break;
          case _PartitionStates.inbound:
            await _partitionInbound(powerSyncHost);
            await _partitionInbound(postgreSQLHost);
            partitionedHosts = {powerSyncHost, postgreSQLHost};
            break;
          case _PartitionStates.outbound:
            await _partitionOutbound(powerSyncHost);
            await _partitionOutbound(postgreSQLHost);
            partitionedHosts = {powerSyncHost, postgreSQLHost};
            break;
          case _PartitionStates.bidirectional:
            await _partitionBidirectional(powerSyncHost);
            await _partitionBidirectional(postgreSQLHost);
            partitionedHosts = {powerSyncHost, postgreSQLHost};
            break;
        }
      });

      log.info(
        'nemesis: partition: current: ${partitionStateMessage.name}, hosts: $partitionedHosts',
      );
    });
  }

  // stop injecting partition messages
  Future<void> stopPartition() async {
    log.info(
      'nemesis: partition: stop listening to stream of partition messages',
    );

    // stop Stream of partition messages
    await _partitionSubscription.cancel();

    // let apis catch up
    await utils.futureDelay(1000);

    // insure no partition
    log.info('nemesis: partition: starting: ${_PartitionStates.none.name}');
    await _partitionNone();
    log.info(
      'nemesis: partition: current: ${_PartitionStates.none.name}, hosts: ${{}}',
    );
  }

  /// Partition inbound traffic.
  static Future<void> _partitionInbound(String host) async {
    final result = await Process.run('/usr/sbin/iptables', [
      '-A',
      'INPUT',
      '-s',
      host,
      '-j',
      'DROP',
      '-w',
    ]);
    if (result.exitCode != 0) {
      log.severe(
        'nemesis: partition: unexpected result from iptables: $result',
      );
      errorExit(ErrorReasons.codingError);
    }
  }

  /// Partition outbound traffic.
  static Future<void> _partitionOutbound(String host) async {
    final result = await Process.run('/usr/sbin/iptables', [
      '-A',
      'OUTPUT',
      '-d',
      host,
      '-j',
      'DROP',
      '-w',
    ]);
    if (result.exitCode != 0) {
      log.severe(
        'nemesis: partition: unexpected result from iptables: $result',
      );
      errorExit(ErrorReasons.codingError);
    }
  }

  /// Partition bidirectional traffic.
  static Future<void> _partitionBidirectional(String host) async {
    await _partitionInbound(host);
    await _partitionOutbound(host);
  }

  /// Partition no traffic
  static Future<void> _partitionNone() async {
    final resultF = await Process.run('/usr/sbin/iptables', ['-F', '-w']);
    if (resultF.exitCode != 0) {
      log.severe(
        'nemesis: partition: unexpected result from iptables: $resultF',
      );
      errorExit(ErrorReasons.codingError);
    }

    final resultX = await Process.run('/usr/sbin/iptables', ['-X', '-w']);
    if (resultX.exitCode != 0) {
      log.severe(
        'nemesis: partition: unexpected result from iptables: $resultX',
      );
      errorExit(ErrorReasons.codingError);
    }
  }
}

/// Maintains the partition state.
/// Flip flops between none, initial state, and inbound or outbound or bidirectional.
class _PartitionState {
  _PartitionStates _state = _PartitionStates.none;

  // Flip flop the current state.
  _PartitionStates _flipFlop() {
    _state = switch (_state) {
      _PartitionStates.none => {
        _PartitionStates.inbound,
        _PartitionStates.outbound,
        _PartitionStates.bidirectional,
      }.getRandom(1).first,

      _PartitionStates.inbound ||
      _PartitionStates.outbound ||
      _PartitionStates.bidirectional => _PartitionStates.none,
    };

    return _state;
  }
}
