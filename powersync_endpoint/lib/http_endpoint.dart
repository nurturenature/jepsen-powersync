import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'args.dart';
import 'ps_endpoint.dart' as pse;
import 'log.dart';

/// Global Jepsen http endpoint.
late HttpServer endpoint;

// my PowerSync endpoint
final _pse = pse.PSEndpoint();

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
  final reqOp = jsonDecode(reqStr) as Map;

  log.fine('txn request: $reqOp');

  final resOp = await _pse.sqlTxn(reqOp);

  log.fine('txn response: $resOp');

  final resStr = jsonEncode(resOp);
  return Response.ok(resStr);
}

/// `/powersync` endpoint for status, connect/disconnect, and upload-queue-count/upload-queue-wait
Future<Response> _powersync(Request req, String action) async {
  Map response;

  log.fine('api request: $action');

  switch (action) {
    case 'connect':
      response = (await _pse.powersyncApi(_pse.connectMessage()))['value']['v'];
      response['db.currentStatus'] = response['db.currentStatus'].toString();
      break;

    case 'disconnect':
      response =
          (await _pse.powersyncApi(_pse.disconnectMessage()))['value']['v'];
      response['db.currentStatus'] = response['db.currentStatus'].toString();
      break;

    case 'upload-queue-count':
      response =
          (await _pse.powersyncApi(
            _pse.uploadQueueCountMessage(),
          ))['value']['v'];
      break;

    case 'upload-queue-wait':
      response =
          (await _pse.powersyncApi(
            _pse.uploadQueueWaitMessage(),
          ))['value']['v'];
      break;

    case 'downloading-wait':
      response =
          (await _pse.powersyncApi(
            _pse.downloadingWaitMessage(),
          ))['value']['v'];
      break;

    default:
      log.severe('Unknown /powersync request: $req');
      exit(127);
  }

  log.fine('api response: $action $response');

  final resStr = jsonEncode(response);
  return Response.ok(resStr);
}

final _router =
    Router()
      ..post('/sql-txn', _sqlTxn)
      ..get('/powersync/<action>', _powersync);

// configure a pipeline that logs requests
final handler = Pipeline()
    .addMiddleware(logRequests())
    .addHandler(_router.call);

Future<void> initEndpoint() async {
  endpoint = await serve(handler, _ip, _port);
}
