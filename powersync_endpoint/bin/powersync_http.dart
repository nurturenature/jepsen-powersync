import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:powersync/sqlite_async.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/pg_endpoint.dart';
import 'package:powersync_endpoint/ps_endpoint.dart';

Future<void> main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.config('args: $args');

  // initialize Endpoint database as PowerSync or PostgreSQL
  final endpoint = endpointLookup[args['endpoint']]!;
  final endpointDb = switch (endpoint) {
    Endpoints.powersync => PSEndpoint(),
    Endpoints.postgresql => PGEndpoint(),
  };
  await endpointDb.init(filePath: '${Directory.current.path}/http.sqlite3');

  // wrap Endpoint.sqlTxn with HTTP Request/Response, JSON decode/encode
  Future<Response> sqlTxn(Request req) async {
    final reqStr = await req.readAsString();
    final reqOp = SplayTreeMap.of(jsonDecode(reqStr));

    // JSON requires String keys so writeSome Map is <String, int> vs <int, int>
    _convertWriteSome(reqOp);

    log.fine('SQL txn: request: $reqOp');

    SplayTreeMap<dynamic, dynamic> resOp;
    try {
      resOp = await endpointDb.sqlTxn(reqOp);
    } on ClosedException {
      resOp = reqOp;
      resOp.addAll({'type': 'fail', 'error': 'ClosedException'});
    }

    log.fine('SQL txn: response: $resOp');

    final resStr = jsonEncode(
      resOp,
      toEncodable: (Object? value) =>
          // JSON requires String keys so convert readAll and writeSome Map<int, int> to <String, int>
          value is Map<int, int>
          ? Map.fromEntries(
              value.entries.map((kv) => MapEntry('${kv.key}', kv.value)),
            )
          : throw UnsupportedError('Cannot convert to JSON: $value'),
    );
    return Response.ok(resStr);
  }

  // wrap Endpoint.dbAPI with HTTP Request/Response, JSON decode/encode
  Future<Response> dbApi(Request req, String actionParam) async {
    final action = apiCallLookup[actionParam]!;

    log.fine('${endpoint.name} api: request: $action');

    final Map<String, dynamic> response;
    switch (action) {
      case APICalls.connect:
        response = (await endpointDb.dbApi(
          Endpoint.connectMessage(),
        ))['value']['v'];
        break;

      case APICalls.disconnect:
        response = (await endpointDb.dbApi(
          Endpoint.disconnectMessage(),
        ))['value']['v'];
        break;

      case APICalls.close:
        response = (await endpointDb.dbApi(
          Endpoint.closeMessage(),
        ))['value']['v'];
        break;

      case APICalls.uploadQueueCount:
        response = (await endpointDb.dbApi(
          Endpoint.uploadQueueCountMessage(),
        ))['value']['v'];
        break;

      case APICalls.uploadQueueWait:
        response = (await endpointDb.dbApi(
          Endpoint.uploadQueueWaitMessage(),
        ))['value']['v'];
        break;

      case APICalls.downloadingWait:
        response = (await endpointDb.dbApi(
          Endpoint.downloadingWaitMessage(),
        ))['value']['v'];
        break;

      case APICalls.selectAll:
        response = (await endpointDb.dbApi(
          Endpoint.selectAllMessage(),
        ))['value']['v'];
        break;
    }

    log.fine('${endpoint.name} api: response: $action: $response');

    final resStr = jsonEncode(response);
    return Response.ok(resStr);
  }

  // HTTP API
  final httpRouter = Router()
    ..post('/sql-txn', sqlTxn)
    ..get('/db-api/<action>', dbApi);

  // configure a pipeline that logs requests
  final httpPipeline = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(httpRouter.call);

  // configure and start HTTP server
  final ipAddr = InternetAddress.anyIPv4;
  final int ipPort = args['httpPort'];
  final httpServer = await serve(httpPipeline, ipAddr, ipPort);

  log.info('httpServer initialized: $httpServer');
  log.info('Listening at ${httpServer.port}');
}

// convert {value: [{f: writeSome Map<String, int>}]} to Map<int, int>
void _convertWriteSome(SplayTreeMap op) {
  final value = op['value'];

  // one or none writeSome
  final mop = value.firstWhere(
    (mop) => mop['f'] == SQLTransactions.writeSome.name,
    orElse: () => {},
  );
  if (mop.isEmpty) {
    return;
  }

  // JSON requires String keys
  final v = mop['v'] as Map<String, dynamic>;

  // convert to int keys
  mop['v'] = Map.fromEntries(
    v.entries.map((kv) => MapEntry(int.parse(kv.key), kv.value as int)),
  );

  return;
}
