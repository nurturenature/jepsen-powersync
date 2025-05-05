import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:synchronized/synchronized.dart';
import '../error_codes.dart';
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
    log.info(
      'nemesis: partition: start listening to stream of partition messages',
    );

    _partitionSubscription = _partitionStream().listen((
      partitionStateMessage,
    ) async {
      log.info('nemesis: partition: starting: ${partitionStateMessage.name}');

      await _lock.synchronized(() async {
        const powerSyncHost = 'powersync';

        switch (partitionStateMessage) {
          case _PartitionStates.none:
            await _partitionNone();
            break;
          case _PartitionStates.inbound:
            await _partitionInbound(powerSyncHost);
            break;
          case _PartitionStates.outbound:
            await _partitionOutbound(powerSyncHost);
            break;
          case _PartitionStates.bidirectional:
            await _partitionBidirectional(powerSyncHost);
            break;
        }
      });

      log.info('nemesis: partition: current: ${partitionStateMessage.name}');
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
    log.info('nemesis: partition: current: ${_PartitionStates.none.name}');
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
      exit(errorCodes[ErrorReasons.codingError]!);
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
      exit(errorCodes[ErrorReasons.codingError]!);
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
      exit(errorCodes[ErrorReasons.codingError]!);
    }

    final resultX = await Process.run('/usr/sbin/iptables', ['-X', '-w']);
    if (resultX.exitCode != 0) {
      log.severe(
        'nemesis: partition: unexpected result from iptables: $resultX',
      );
      exit(errorCodes[ErrorReasons.codingError]!);
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
      _PartitionStates.none =>
        {
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
