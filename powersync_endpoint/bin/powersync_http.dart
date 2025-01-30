import 'package:powersync_endpoint/backend_connector.dart';
import 'package:powersync_endpoint/config.dart';
import 'package:powersync_endpoint/db.dart';
import 'package:powersync_endpoint/endpoint.dart';
import 'package:powersync_endpoint/log.dart';

Future<void> main(List<String> arguments) async {
  print('Initializing config');
  initConfig();

  print('Initializing logging');
  initLogging();

  log.info('Initializing Postgres connection...');
  await initPostgres();
  log.info('Postgres connection initialized: $postgres');

  log.info('Initializing db...');
  await initDb();
  log.info('db initialized: $db');

  log.info('Initializing endpoint...');
  await initEndpoint();
  log.info('endpoint initialized: $endpoint');

  log.info('Listening at ${endpoint.port}');
}
