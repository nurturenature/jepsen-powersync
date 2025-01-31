import 'dart:convert';
import 'dart:io';
import 'package:powersync/sqlite3.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'args.dart';
import 'db.dart';
import 'log.dart';
import 'utils.dart';

/// Global Jepsen endpoint.
late HttpServer endpoint;

final _ip = InternetAddress.anyIPv4;
final int _port = args['httpPort'];

/// Execute an sql transaction and return the results:
/// - request is a Jepsen op value as a JSON string
///   - transaction maps are in value: [{f: r | append, k: key, v: value}...]
/// - response is an updated Jepsen op value with the txn results
///
/// No Exceptions are expected!
/// Single user local PowerSync is totally available, strict serializable.
/// No catching, let Exceptions fail the test
Future<Response> _sqlTxn(Request req) async {
  final reqStr = await req.readAsString();
  final op = jsonDecode(reqStr);

  log.fine('/sql-txn: request: $op');

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

  log.fine('/sql-txn: response: $op');

  final resStr = jsonEncode(op);
  return Response.ok(resStr);
}

/// `/powersync` endpoint for status, connect/disconnect, and upload-queue-count/upload-queue-wait
Future<Response> _powersync(Request req, String action) async {
  Map response;

  log.fine('/powersync/$action: request');

  switch (action) {
    case 'status':
      response = {
        'db.closed': db.closed,
        'db.connected': db.connected,
        'db.runtimeType': db.runtimeType.toString(),
        'db.currentStatus': '${db.currentStatus}'
      };
      break;

    case 'connect':
      await db.connect(connector: connector);
      response = {
        'db.closed': db.closed,
        'db.connected': db.connected,
        'db.currentStatus': '${db.currentStatus}'
      };
      break;

    case 'disconnect':
      await db.disconnect();
      response = {
        'db.closed': db.closed,
        'db.connected': db.connected,
        'db.currentStatus': '${db.currentStatus}'
      };
      break;

    case 'upload-queue-count':
      final uploadQueueCount = (await db.getUploadQueueStats()).count;
      response = {'db.upload-queue-count': uploadQueueCount};
      break;

    case 'upload-queue-wait':
      while ((await db.getUploadQueueStats()).count != 0) {
        await futureSleep(100);
      }
      response = {'db.upload-queue-wait': 'queue-empty'};
      break;

    case 'downloading-wait':
      int tries = 0;
      const maxTries = 300;
      const waitPerTry = 100;

      while ((db.currentStatus.downloading) == true && tries < maxTries) {
        await futureSleep(waitPerTry);
        tries++;
      }
      if (tries == maxTries) {
        response = {
          'ERROR':
              'Tried ${tries - 1} times every ${waitPerTry}ms, db.currentStatus: ${db.currentStatus}'
        };
      } else {
        response = {'db.currentStatus': '${db.currentStatus}'};
      }
      break;

    default:
      log.severe('Unknown /powersync request: $req');
      exit(127);
  }

  log.fine('/powersync/$action: response: $response');

  final resStr = jsonEncode(response);
  return Response.ok(resStr);
}

/// `/db` endpoint to query db
Future<Response> _db(Request req, String action) async {
  late ResultSet response;

  log.fine('/db/$action: request');

  switch (action) {
    case 'list':
      response = await db.getAll('SELECT * FROM lww ORDER BY k');
      break;
    default:
      log.severe('Unknown /db request: $req');
      exit(127);
  }

  log.fine('/db/$action: response: $response');

  final resStr = jsonEncode(response);
  return Response.ok(resStr);
}

final _router = Router()
  ..post('/sql-txn', _sqlTxn)
  ..get('/powersync/<action>', _powersync)
  ..get('/db/<action>', _db);

// configure a pipeline that logs requests
final handler =
    Pipeline().addMiddleware(logRequests()).addHandler(_router.call);

Future<void> initEndpoint() async {
  endpoint = await serve(handler, _ip, _port);
}
