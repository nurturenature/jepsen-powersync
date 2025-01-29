import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite_async.dart' as sqlite;
import 'backend_connector.dart';
import 'log.dart';
import 'postgresql.dart' as pg;
import 'schema.dart';
import 'utils.dart' as utils;

/// Global PowerSync db.
late PowerSyncDatabase db;

/// Connector to PowerSync db.
late PowerSyncBackendConnector connector;

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

  // insure complete db.waitForFirstSync()
  final pgLww = await pg.selectAll(
      'lww'); // PostgreSQL is source of truth, explicitly initialized at app startup
  var currentStatus = db
      .currentStatus; // get currentStatus first to show incorrect lastSyncedAt: hasSynced
  var psLww = await selectAll('lww');
  var diffs = utils.mapDiff('pg', pgLww, 'ps', psLww);
  while (diffs.isNotEmpty) {
    log.info('db.waitForFirstSync incomplete: $diffs');
    log.info('    with currentStatus: $currentStatus');

    // sleep and try again
    await utils.futureSleep(
        100); // in ms, sleep in separate Isolate to not block async activity is this Isolate
    currentStatus = db
        .currentStatus; // get currentStatus first to show values while sync incomplete
    psLww = await selectAll('lww');
    diffs = utils.mapDiff('pg', pgLww, 'ps', psLww);
  }

  // log PowerSync status changes
  // monitor for state mismatch
  // monitor for upload/download error messages, check if they're ignorable
  db.statusStream.listen((syncStatus) {
    // state mismatch
    if (!syncStatus.connected &&
        (syncStatus.downloading || syncStatus.uploading)) {
      log.warning(
          'syncStatus.connected is false yet uploading|downloading: $syncStatus');
    }
    if ((syncStatus.hasSynced == false && syncStatus.lastSyncedAt != null) ||
        (syncStatus.hasSynced == true && syncStatus.lastSyncedAt == null)) {
      log.warning('syncStatus.hasSynced/lastSyncedAt mismatch: $syncStatus');
    }

    // no errors
    if (syncStatus.anyError == null) {
      log.finest('$syncStatus');
      return;
    }

    // upload error
    if (syncStatus.uploadError != null) {
      // ignorable
      if (_ignorableUploadError(syncStatus.uploadError!)) {
        log.info(
            'ignorable upload error in statusStream: ${syncStatus.uploadError}');
        return;
      }
      // unexpected
      log.severe(
          'unexpected upload error in statusStream: ${syncStatus.uploadError}');
      exit(127);
    }

    // download error
    if (syncStatus.downloadError != null) {
      // ignorable
      if (_ignorableDownloadError(syncStatus.downloadError!)) {
        log.info(
            'ignorable download error in statusStream: ${syncStatus.downloadError}');
        return;
      }
      // unexpected
      log.severe(
          'unexpected download error in statusStream: ${syncStatus.downloadError}');
      exit(127);
    }

    // WTF?
    throw StateError('Error interpreting syncStatus: $syncStatus');
  });

  // log PowerSync db updates
  db.updates.listen((updateNotification) {
    log.finest('$updateNotification');
  });

  // log current db contents
  final dbTables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1;
  ''');

  final lww = await selectAll('lww');
  log.info("tables: $dbTables");
  log.info("lww: $lww");
}

/// Select all rows from given table and return {k: v}.
Future<Map<int, String>> selectAll(String table) async {
  return Map.fromEntries((await db.getAll('SELECT k,v FROM lww ORDER BY k;'))
      .map((row) => MapEntry(row['k'] as int, row['v'] as String)));
}

// can this upload error be ignored?
bool _ignorableUploadError(Object ex) {
  // exposed by disconnect-connect nemesis
  if (ex is sqlite.ClosedException) {
    return true;
  }

  // exposed by disconnect-connect nemesis
  if (ex is http.ClientException &&
      (ex.message.startsWith(
              'Connection closed before full header was received') ||
          ex.message
              .startsWith('HTTP request failed. Client is already closed.'))) {
    return true;
  }

  // don't ignore unexpected
  return false;
}

// can this download error be ignored?
bool _ignorableDownloadError(Object ex) {
  // exposed by disconnect-connect nemesis
  if (ex is sqlite.ClosedException) {
    return true;
  }

  // don't ignore unexpected
  return false;
}
