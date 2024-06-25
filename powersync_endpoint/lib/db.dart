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
  db =
      PowerSyncDatabase(schema: schema, path: config['SQLITE3_PATH'] as String);
  log.info("Created db, schema: ${schema.tables.map((table) => {
        table.toJson()
      })}, path: ${config['SQLITE3_PATH']}");

  await db.initialize();
  log.info(
      'db initialized, runtimeType: ${db.runtimeType}, status: ${db.currentStatus}');

  await db.connect(connector: CrudBatchConnector(db));
  log.info('db connected, status: ${db.currentStatus}');

  // log PowerSync status changes
  db.statusStream
      .listen((syncStatus) => log.finest('statusStream: $syncStatus'));

  // log current db contents
  final dbTables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1
  ''');
  final lww = await db.execute('SELECT k,v FROM lww');
  log.info("tables: $dbTables");
  log.info("lww: $lww");
}
