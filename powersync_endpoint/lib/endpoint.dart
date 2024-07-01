import 'dart:convert';
import 'dart:io';
import 'package:powersync/sqlite3.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'config.dart';
import 'db.dart';
import 'log.dart';

/// Global Jepsen endpoint.
late HttpServer endpoint;

final _ip = InternetAddress.anyIPv4;
final _port = int.parse(config['ENDPOINT_PORT'] ?? '8089');

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
  log.fine('invocation: $op');

  assert(op['value'].length >= 1);

  await db.writeTransaction((tx) async {
    op['value'].map((mop) async {
      switch (mop['f']) {
        case 'r':
          final select = await tx
              .getOptional('SELECT k,v from lww where k = ?', [mop['k']]);
          // expected to be a result row as db is pre-seeded, so !null check
          // v == '' is a  null read
          if ((select!['v'] as String) == '') {
            return mop;
          } else {
            // trim leading space that was created on first UPDATE
            final v = (select['v'] as String).trimLeft();
            mop['v'] = "[$v]";
            return mop;
          }

        case 'append':
          // note: creates leading space on first update, upsert isn't supported
          await tx.execute('UPDATE lww SET v = lww.v || \' \' || ? WHERE k = ?',
              [mop['v'], mop['k']]);
          return mop;
      }
    }).toList();
  });

  op['type'] = 'ok';
  final resStr = jsonEncode(op);
  log.fine('completion: $op');

  return Response.ok(resStr);
}

/// `/powersync` endpoint for status information
Future<Response> _powersync(Request req) async {
  final status = db.currentStatus;
  final response = jsonEncode({
    'env.LOCAL_ONLY': config['LOCAL_ONLY'],
    'db.closed': db.closed,
    'db.connected': db.connected,
    'db.runtimeType': db.runtimeType.toString(),
    'status.connected': status.connected,
    'status.lastSyncedAt': status.lastSyncedAt?.toIso8601String()
  });

  return Response.ok(response);
}

/// `/db` endpoint to query db
Future<Response> _db(Request req, String action) async {
  late ResultSet response;

  switch (action) {
    case 'list':
      response = await db.getAll('SELECT * FROM lww ORDER BY k');
      break;
    default:
      log.severe('Unknown /db request: $req');
      exit(127);
  }
  final resStr = jsonEncode(response);
  return Response.ok(resStr);
}

final _router = Router()
  ..post('/sql-txn', _sqlTxn)
  ..get('/powersync', _powersync)
  ..get('/db/<action>', _db);

// configure a pipeline that logs requests
final handler =
    Pipeline().addMiddleware(logRequests()).addHandler(_router.call);

Future<void> initEndpoint() async {
  endpoint = await serve(handler, _ip, _port);
}
