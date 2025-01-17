import 'dart:io';
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite_async.dart' as sqlite;
import 'backend_connector.dart';
import 'log.dart';
import 'schema.dart';

/// Global PowerSync db.
late PowerSyncDatabase db;

/// Connector to PowerSync db.
late PowerSyncBackendConnector connector;

// can this upload error be ignored?
bool _ignorableUploadError(Object ex) {
  // exposed by disconnect-connect nemesis
  if (ex is sqlite.ClosedException) {
    return true;
  }

  // don't ignore unexpected
  return false;
}

Future<void> initDb(String sqlite3Path) async {
  // delete any existing files
  try {
    await File(sqlite3Path).delete();
    await File('$sqlite3Path-shm').delete();
    await File('$sqlite3Path-wal').delete();
  } catch (ex) {
    // don't care
  }

  db = PowerSyncDatabase(schema: schema, path: sqlite3Path);
  log.info("Created db, schema: ${schema.tables.map((table) => {
        table.toJson()
      })}, path: $sqlite3Path");

  await db.initialize();
  log.info(
      'db initialized, runtimeType: ${db.runtimeType}, status: ${db.currentStatus}');

  connector = CrudTransactionConnector(db);

  // retry significantly faster than default of 5s, designed to leverage a Transaction oriented BackendConnector
  // must be set before connecting
  db.retryDelay = Duration(milliseconds: 1000);

  await db.connect(connector: connector);
  log.info('db connected, connector: $connector, status: ${db.currentStatus}');

  await db.waitForFirstSync();
  log.info('db first sync completed, status: ${db.currentStatus}');

  // log PowerSync status changes
  // monitor for upload error messages, check if they're ignorable
  db.statusStream.listen((syncStatus) {
    if (syncStatus.uploadError != null &&
        !_ignorableUploadError(syncStatus.uploadError!)) {
      log.severe(
          'Upload error detected in statusStream: ${syncStatus.uploadError}');
      exit(127);
    }

    log.finest('statusStream: $syncStatus');
  });

  // log PowerSync db updates
  db.updates.listen((updateNotification) {
    log.finest('updates: $updateNotification');
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
