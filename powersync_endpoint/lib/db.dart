import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';
import 'backend_connector.dart';
import 'config.dart';
import 'log.dart';
import 'schema.dart';

final uuid = Uuid();

/// Global PowerSync db.
late PowerSyncDatabase db;

Future<void> initDb() async {
  final tables = schema.tables.map((table) => {table.toJson()});
  log.info("Creating db, schema: $tables, path: ${config['SQLITE3_PATH']}");
  db =
      PowerSyncDatabase(schema: schema, path: config['SQLITE3_PATH'] as String);

  await db.initialize();
  log.info(
      'db initialized, runtimeType: ${db.runtimeType}, status: ${db.currentStatus}');

  await db.connect(connector: NoOpConnector(db));
  log.info('db connected, status: ${db.currentStatus}');

  final dbTables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1
  ''');
  log.info("tables: $dbTables");

  // init db to known state
  await db.execute('DELETE FROM lww');
  for (var i = 0; i < 100; i++) {
    await db
        .execute('INSERT INTO lww (id,k,v) VALUES (?,?,?)', [uuid.v7(), i, '']);
  }

  final lww = await db.execute('SELECT k,v FROM lww');
  log.info("lww: $lww");
}
