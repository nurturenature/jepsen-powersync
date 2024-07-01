import 'dart:io';
import 'package:powersync/powersync.dart';
import 'backend_connector.dart';
import 'config.dart';
import 'log.dart';
import 'schema.dart';

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

  PowerSyncBackendConnector connector;
  switch (config['BACKEND_CONNECTOR']) {
    case 'CrudTransactionConnector':
      connector = CrudTransactionConnector(db);
      break;
    case 'CrudBatchConnector':
      connector = CrudBatchConnector(db);
      break;
    default:
      log.severe('Invalid BACKEND_CONNECTOR: ${config['BACKEND_CONNECTOR']}');
      exit(127);
  }

  await db.connect(connector: connector);
  log.info('db connected, connector: $connector, status: ${db.currentStatus}');

  // log PowerSync status changes
  // monitor for upload error messages, there should be none
  db.statusStream.listen((syncStatus) {
    if (syncStatus.uploadError != null) {
      log.severe(
          'Upload error detected in statusStream: ${syncStatus.uploadError}');
      exit(127);
    }

    log.finest('statusStream: $syncStatus');
  });

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
