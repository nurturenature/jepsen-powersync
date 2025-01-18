import 'dart:io';
import 'dart:math';
import 'package:list_utilities/list_utilities.dart';
import 'package:powersync/sqlite3.dart';
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
            throw StateError(
                "Unexpected database state, uninitialized read key ${mop['k']}");
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
            throw StateError(
                "Unexpected database state, uninitialized append key ${mop['k']}");
          }

          return mop;
      }
    }).toList();
  });

  op['type'] = 'ok';
  return op;
}

/// api endpoint for status, connect/disconnect, and upload-queue-count/upload-queue-wait
Future<Map> powersyncApi(Map op) async {
  assert(op['type'] == 'invoke');
  assert(op['f'] == 'api');
  assert(op['value'] != null);

  String newType = 'ok';

  switch (op['value']['f']) {
    case 'connect':
      await db.connect(connector: connector);
      op['value']['v'] = {
        'db.closed': db.closed,
        'db.connected': db.connected,
        'db.currentStatus': '${db.currentStatus}'
      };
      break;

    case 'disconnect':
      await db.disconnect();
      op['value']['v'] = {
        'db.closed': db.closed,
        'db.connected': db.connected,
        'db.currentStatus': '${db.currentStatus}'
      };
      break;

    case 'upload-queue-count':
      final uploadQueueCount = (await db.getUploadQueueStats()).count;
      op['value']['v'] = {'db.upload-queue-count': uploadQueueCount};
      break;

    case 'upload-queue-wait':
      while ((await db.getUploadQueueStats()).count != 0) {
        await isolateSleep(100);
      }
      op['value']['v'] = {'db.upload-queue-wait': 'queue-empty'};
      break;

    case 'downloading-wait':
      int tries = 0;
      const maxTries = 300;
      const waitPerTry = 100;

      while ((db.currentStatus.downloading) == true && tries < maxTries) {
        await isolateSleep(waitPerTry);
        tries++;
      }
      if (tries == maxTries) {
        newType = 'error';
        op['value']['v'] = {
          'error':
              'Tried ${tries - 1} times every ${waitPerTry}ms, db.currentStatus: ${db.currentStatus}'
        };
      } else {
        op['value']['v'] = {'db.currentStatus': '${db.currentStatus}'};
      }
      break;

    default:
      log.severe('Unknown powersyncApi request: $op');
      exit(127);
  }

  op['type'] = newType;
  return op;
}

/// db endpoint to query db
Future<ResultSet> dbApi(Map req, String action) async {
  late ResultSet response;

  log.fine('dbApi: action: $action request: $req');

  switch (action) {
    case 'list':
      response = await db.getAll('SELECT * FROM lww ORDER BY k');
      break;
    default:
      log.severe('Unknown /db request: $req');
      exit(127);
  }

  log.fine('dbApi: action: $action response: $response');

  return response;
}

List<Map> genRandTxn(int num, int value) {
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
