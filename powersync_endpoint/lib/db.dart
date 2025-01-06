import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite_async.dart' as sqlite;
import 'backend_connector.dart';
import 'config.dart';
import 'log.dart';
import 'schema.dart';

/// Global PowerSync db.
late PowerSyncDatabase db;

/// Connector to PowerSync db.
late PowerSyncBackendConnector connector;

// can this upload error be ignored?
bool _ignorableUploadError(Object ex) {
  // exposed by disconnect-connect nemesis
  if (ex is http.ClientException &&
      ex.message
          .startsWith('Connection closed before full header was received')) {
    return true;
  }

  // exposed by disconnect-connect nemesis
  if (ex is sqlite.ClosedException) {
    return true;
  }

  // don't ignore unexpected
  return false;
}

Future<void> initDb() async {
  db =
      PowerSyncDatabase(schema: schema, path: config['SQLITE3_PATH'] as String);
  log.info("Created db, schema: ${schema.tables.map((table) => {
        table.toJson()
      })}, path: ${config['SQLITE3_PATH']}");

  await db.initialize();
  log.info(
      'db initialized, runtimeType: ${db.runtimeType}, status: ${db.currentStatus}');

  connector = switch (config['BACKEND_CONNECTOR']) {
    'CrudTransactionConnector' => CrudTransactionConnector(db),
    'CrudBatchConnector' => CrudBatchConnector(db),
    _ => throw ArgumentError.value(
        config['BACKEND_CONNECTOR'], 'BACKEND_CONNECTOR', 'Unknown value')
  };

  // retry significantly faster than default of 5s, designed to leverage a Transaction oriented BackendConnector
  // must be set before connecting
  db.retryDelay = Duration(milliseconds: 1000);

  await db.connect(connector: connector);
  log.info('db connected, connector: $connector, status: ${db.currentStatus}');

  await db.waitForFirstSync();
  log.info('db first sync completed, status: ${db.currentStatus}');

  // TODO: debug, delete me!
  // [`db.statusStream` has a large # of contiguous duplicate SyncStatus messages, ~70% of all messages are duplicates](https://github.com/powersync-ja/powersync.dart/issues/224)
  // int distinctSyncStatus = 0;
  // int totalSyncStatus = 0;
  // db.statusStream.distinct().listen((syncStatus) {
  //   distinctSyncStatus++;
  //   log.finest('distinctSyncStatus: $distinctSyncStatus');
  // });
  // db.statusStream.listen((syncStatus) {
  //   totalSyncStatus++;
  //   log.finest('totalSyncStatus: $totalSyncStatus');
  // });

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
