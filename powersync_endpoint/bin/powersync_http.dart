import 'dart:io';
import 'package:powersync_endpoint/args.dart';
import 'package:powersync_endpoint/db.dart' as db;
import 'package:powersync_endpoint/http_endpoint.dart';
import 'package:powersync_endpoint/log.dart';
import 'package:powersync_endpoint/postgresql.dart' as pg;

Future<void> main(List<String> arguments) async {
  // parse args, set defaults, must be 1st in main
  parseArgs(arguments);
  initLogging('main');
  log.config('args: $args');

  // initialize PostgreSQL
  await pg.init(
    pg.Tables.lww,
    false,
  ); // TODO: have Jepsen init on 1st client/db setup
  log.config(
    'PostgreSQL connection and database initialized, connection: ${pg.postgreSQL}',
  );
  log.config('PostgreSQL lww table: ${await pg.selectAllLWW()}');

  await db.initDb(
    pg.Tables.lww,
    '${Directory.current.path}/powersync_http.sqlite3',
  );
  log.info('db initialized: ${db.db}');

  await initEndpoint();
  log.info('endpoint initialized: $endpoint');

  log.info('Listening at ${endpoint.port}');
}
