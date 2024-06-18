import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:sqlite3_endpoint/env.dart';
import 'package:sqlite3_endpoint/db.dart';

late HttpServer endpoint;

final ip = InternetAddress.anyIPv4;
final port = int.parse(env['PORT'] ?? "8089");

// Request is a Jepsen op value as a JSON string
// transaction maps are in value: [{f: r | append, k: key, v: value}...]
// Response is an updated Jepsen op value with the txn results
//
// No Exceptions are expected!
// Single user local SQLite3 is totally available, strict serializable.
// No catching, let Exceptions fail the test
Future<Response> _sqlTxn(Request req) async {
  final reqStr = await req.readAsString();
  final op = jsonDecode(reqStr);
  print('invocation: $op');

  assert(op['value'].length >= 1);

  await db.writeTransaction((tx) async {
    op['value'].map((mop) async {
      switch (mop['f']) {
        case 'r':
          final select =
              await tx.getOptional('SELECT * from lww where k = ?', [mop['k']]);
          if (select == null) {
            return mop;
          } else {
            mop['v'] = "[${select['v']}]";
            return mop;
          }

        case 'append':
          await tx.execute(
              'INSERT OR REPLACE INTO lww (k,v) VALUES (?,?) ON CONFLICT (k) DO UPDATE SET v = lww.v || \' \' || ?',
              [mop['k'], mop['v'], mop['v']]);
          return mop;
      }
    }).toList();
  });

  final resStr = jsonEncode(op);
  print('completion: $op');

  return Response.ok(resStr);
}

final _router = Router()..post('/sql-txn', _sqlTxn);

// configure a pipeline that logs requests
final handler =
    Pipeline().addMiddleware(logRequests()).addHandler(_router.call);

Future<HttpServer> initEndpoint() async {
  endpoint = await serve(handler, ip, port);
  return endpoint; // required to pass non nullable
}
