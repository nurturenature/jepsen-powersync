import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync/sqlite3.dart' as sqlite3;
import 'args.dart';
import 'db.dart';
import 'log.dart';
import 'utils.dart';

final _rng = Random();

/// Execute an sql transaction and return the results:
/// - request is a Jepsen op value as a Map
///   - transaction maps are in value: [{f: r | append, k: key, v: value}...]
/// - response is an updated Jepsen op value with the txn results
///
/// No Exceptions are expected!
/// Single user local PowerSync is totally available, strict serializable.
/// No catching, let Exceptions fail the test
Future<Map> sqlTxn(Map op) async {
  assert(op['type'] == 'invoke');
  assert(op['f'] == 'txn');
  assert(op['value'].length >= 1);

  await db.writeTransaction((tx) async {
    op['value'].map((mop) async {
      switch (mop['f']) {
        case 'r':
          final select = await tx
              .getOptional('SELECT k,v from lww where k = ?', [mop['k']]);
          // result row expected as db is pre-seeded
          if (select == null) {
            log.severe(
                "Unexpected database state, uninitialized read key ${mop['k']} for op: $op");
            exit(127);
          }

          // v == '' is a  null read
          if ((select['v'] as String) == '') {
            return mop;
          } else {
            // trim leading space that was created on first UPDATE
            final v = (select['v'] as String).trimLeft();
            mop['v'] = "[$v]";
            return mop;
          }

        case 'append':
          // note: creates leading space on first update, upsert isn't supported
          final update = await tx.execute(
              'UPDATE lww SET v = lww.v || \' \' || ? WHERE k = ? RETURNING *',
              [mop['v'], mop['k']]);
          // result set expected as db is pre-seeded
          if (update.isEmpty) {
            log.severe(
                "Unexpected database state, uninitialized append key ${mop['k']} for op: $op");
            exit(127);
          }

          return mop;
      }
    }).toList();
  });

  op['type'] = 'ok';
  return op;
}

/// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
Future<Map> powersyncApi(Map op) async {
  assert(op['type'] == 'invoke');
  assert(op['f'] == 'api');
  assert(op['value'] != null);

  String newType = 'ok';

  switch (op['value']['f']) {
    case 'connect':
      await db.connect(connector: connector);
      final closed = db.closed;
      final connected = db.connected;
      final currentStatus = db.currentStatus;
      final v = {
        'db.closed': closed,
        'db.connected': connected,
        'db.currentStatus': currentStatus
      };
      if (!connected) {
        log.warning('expected db.connected to be true after db.connect(): $v');
      }
      op['value']['v'] = v;
      break;

    case 'disconnect':
      await db.disconnect();
      final closed = db.closed;
      final connected = db.connected;
      final currentStatus = db.currentStatus;
      final v = {
        'db.closed': closed,
        'db.connected': connected,
        'db.currentStatus': currentStatus
      };
      if (connected) {
        log.warning(
            'expected db.connected to be false after db.disconnect(): $v');
      }
      op['value']['v'] = v;
      break;

    case 'upload-queue-count':
      final uploadQueueCount = (await db.getUploadQueueStats()).count;
      op['value']['v'] = {'db.uploadQueueStats.count': uploadQueueCount};
      break;

    case 'upload-queue-wait':
      while ((await db.getUploadQueueStats()).count != 0) {
        log.info(
            'still waiting for db.uploadQueueStats.count == 0, currently ${(await db.getUploadQueueStats()).count}...');
        await futureSleep(1000);
      }
      op['value']['v'] = {'db.uploadQueueStats.count': 'queue-empty'};
      break;

    case 'downloading-wait':
      int onTry = 1;
      const maxTries = 30;
      const waitPerTry = 1000;

      while ((db.currentStatus.downloading) == true && onTry <= maxTries) {
        log.info(
            'still waiting after try $onTry for db.currentStatus.downloading == false...');
        await futureSleep(waitPerTry);
        onTry++;
      }
      if (onTry > maxTries) {
        newType = 'error';
        op['type'] = newType; // update op now for better error message
        op['value']['v'] = {
          'error':
              'Tried ${onTry - 1} times every ${waitPerTry}ms, db.currentStatus: ${db.currentStatus}'
        };
        log.severe(op);
      } else {
        op['value']['v'] = {'db.currentStatus': '${db.currentStatus}'};
      }
      break;

    case 'select-all':
      op['value']['v'] = await selectAll('lww');
      break;

    default:
      log.severe('Unknown powersyncApi request: $op');
      exit(127);
  }

  op['type'] = newType;
  return op;
}

List<Map> _genRandTxn(int num, int value) {
  final List<Map> txn = [];
  final Set<int> appendedKeys = {};

  for (var i = 0; i < num; i++) {
    final f = ['r', 'append'].getRandom(1).first;
    final k = _rng.nextInt(args['keys']);
    switch (f) {
      case 'r':
        txn.add({'f': 'r', 'k': k, 'v': null});
        break;
      // only append to a key once
      case 'append' when !appendedKeys.contains(k):
        appendedKeys.add(k);
        txn.add({'f': 'append', 'k': k, 'v': value});
        break;
      // duplicate append key so read it instead
      default:
        txn.add({'f': 'r', 'k': k, 'v': null});
        break;
    }
  }

  return txn;
}

Map<String, dynamic> rndTxnMessage(int count) {
  return Map.of({
    'type': 'invoke',
    'f': 'txn',
    'value': _genRandTxn(args['maxTxnLen'], count)
  });
}

enum ConnectionStates { connected, disconnected }

class ConnectionState {
  ConnectionStates _state = ConnectionStates.connected;

  // Flip flop the current state.
  ConnectionStates flipFlop() {
    _state = switch (_state) {
      ConnectionStates.connected => ConnectionStates.disconnected,
      ConnectionStates.disconnected => ConnectionStates.connected
    };
    return _state;
  }
}

Map<String, dynamic> connectMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'connect', 'v': {}}
  });
}

Map<String, dynamic> disconnectMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'disconnect', 'v': {}}
  });
}

Map<String, dynamic> rndConnectOrDisconnectMessage() {
  if (_rng.nextBool()) {
    return connectMessage();
  } else {
    return disconnectMessage();
  }
}

Map<String, dynamic> selectAllMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'select-all', 'v': <sqlite3.Row>{}}
  });
}

Map<String, dynamic> uploadQueueCountMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'upload-queue-count', 'v': {}}
  });
}

Map<String, dynamic> uploadQueueWaitMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'upload-queue-wait', 'v': {}}
  });
}

Map<String, dynamic> downloadingWaitMessage() {
  return Map.of({
    'type': 'invoke',
    'f': 'api',
    'value': {'f': 'downloading-wait', 'v': {}}
  });
}
