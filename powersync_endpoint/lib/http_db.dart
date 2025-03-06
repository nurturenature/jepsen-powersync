// TODO: old db package for http
// TODO: refactor to ps_endpoint

import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite_async.dart' as sqlite;
import 'backend_connector.dart';
import 'log.dart';
import 'http_postgresql.dart' as pg;
import 'schema.dart';
import 'utils.dart' as utils;

/// Global PowerSync db.
late PowerSyncDatabase db;

/// Connector to PowerSync db.
late PowerSyncBackendConnector connector;

Future<void> initDb(
  Tables table,
  String sqlite3Path, {
  bool preserveSqlite3Data = false,
}) async {
  // delete any preexisting SQLite3 files?
  if (await File(sqlite3Path).exists()) {
    log.info('db: init: preexisting SQLite3 file: $sqlite3Path');

    if (!preserveSqlite3Data) {
      await _deleteSqlite3Files(sqlite3Path);
      log.info('\tpreexisting file deleted');
    } else {
      log.info('\tpreexisting file preserved');
    }
  } else {
    log.info('db: init: no preexisting SQLite3 file: $sqlite3Path');
  }

  db = switch (table) {
    Tables.lww => PowerSyncDatabase(schema: schemaLWW, path: sqlite3Path),
    Tables.mww => PowerSyncDatabase(schema: schemaMWW, path: sqlite3Path),
  };
  log.info(
    "db: init: created db with schemas: ${db.schema.tables.map((table) => {table.name: table.columns.map((column) => '${column.name} ${column.type.name}')})}, path: $sqlite3Path",
  );

  await db.initialize();
  log.info(
    'db: init: initialized with runtimeType: ${db.runtimeType}, status: ${db.currentStatus}',
  );

  connector = CrudTransactionConnector(table, db);

  // retry significantly faster than default of 5s, designed to leverage a Transaction oriented BackendConnector
  // must be set before connecting
  db.retryDelay = Duration(milliseconds: 1000);

  await db.connect(connector: connector);
  log.info(
    'db: init: connected with connector: $connector, status: ${db.currentStatus}',
  );

  await db.waitForFirstSync();
  log.info('db: init: first sync completed with status: ${db.currentStatus}');

  // insure local db is complete, i.e. has all the keys
  // PostgreSQL is source of truth, explicitly initialized at app startup
  final Set<int> pgKeys = Set.from(
    (switch (table) {
      Tables.lww => await pg.selectAllLWW(),
      Tables.mww => await pg.selectAllMWW(),
    }).keys,
  );
  var currentStatus = db.currentStatus;
  Set<int> psKeys = Set.from(
    (switch (table) {
      Tables.lww => await selectAllLWW(),
      Tables.mww => await selectAllMWW(),
    }).keys,
  );
  while (!psKeys.containsAll(pgKeys)) {
    log.info(
      'db: init: db.waitForFirstSync() incomplete, missing keys: ${pgKeys.difference(psKeys)}',
    );
    log.info('\twith currentStatus: $currentStatus');

    // sleep and try again
    await utils.futureSleep(100);
    currentStatus = db.currentStatus;
    psKeys = Set.from(
      (switch (table) {
        Tables.lww => await selectAllLWW(),
        Tables.mww => await selectAllMWW(),
      }).keys,
    );
  }
  log.info(
    'db: init: db.waitForFirstSync() confirmed with all keys present: $psKeys',
  );

  // log PowerSync status changes
  _logSyncStatus(db);

  // log PowerSync db updates
  _logUpdates(db);

  // log current db contents
  final dbTables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1;
  ''');

  final currTable = switch (table) {
    Tables.lww => await selectAllLWW(),
    Tables.mww => await selectAllMWW(),
  };
  log.info("db: init: tables: $dbTables");
  log.info("db: init: ${table.name}: $currTable");
}

// delete any existing SQLite3 files
Future<void> _deleteSqlite3Files(String sqlite3Path) async {
  try {
    await File(sqlite3Path).delete();
    await File('$sqlite3Path-shm').delete();
    await File('$sqlite3Path-wal').delete();
  } catch (ex) {
    // don't care
  }
}

// log PowerSync status changes
void _logSyncStatus(PowerSyncDatabase db) {
  db.statusStream.listen((syncStatus) {
    // state mismatch
    if (!syncStatus.connected &&
        (syncStatus.downloading || syncStatus.uploading)) {
      log.warning(
        'SyncStatus: syncStatus.connected is false yet uploading|downloading: $syncStatus',
      );
    }
    if ((syncStatus.hasSynced == false && syncStatus.lastSyncedAt != null) ||
        (syncStatus.hasSynced == true && syncStatus.lastSyncedAt == null)) {
      log.warning(
        'SyncStatus: syncStatus.hasSynced/lastSyncedAt mismatch: $syncStatus',
      );
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
          'SyncStatus: ignorable upload error in statusStream: ${syncStatus.uploadError}',
        );
        return;
      }
      // unexpected
      log.severe(
        'SyncStatus: unexpected upload error in statusStream: ${syncStatus.uploadError}',
      );
      exit(40);
    }

    // download error
    if (syncStatus.downloadError != null) {
      // ignorable
      if (_ignorableDownloadError(syncStatus.downloadError!)) {
        log.info(
          'SyncStatus: ignorable download error in statusStream: ${syncStatus.downloadError}',
        );
        return;
      }
      // unexpected
      log.severe(
        'SyncStatus: unexpected download error in statusStream: ${syncStatus.downloadError}',
      );
      exit(41);
    }

    // WTF?
    throw StateError('Error interpreting syncStatus: $syncStatus');
  });
}

// log PowerSync db updates
void _logUpdates(PowerSyncDatabase db) {
  db.updates.listen((updateNotification) {
    log.finest('$updateNotification');
  });
}

/// Select all rows from lww table and return {k: v}.
Future<Map<int, String>> selectAllLWW() async {
  return Map.fromEntries(
    (await db.getAll(
      'SELECT k,v FROM lww ORDER BY k;',
    )).map((row) => MapEntry(row['k'], row['v'])),
  );
}

/// Select all rows from mww table and return {k: v}.
Future<Map<int, int>> selectAllMWW() async {
  return Map.fromEntries(
    (await db.getAll(
      'SELECT k,v FROM mww ORDER BY k;',
    )).map((row) => MapEntry(row['k'], row['v'])),
  );
}

// can this upload error be ignored?
bool _ignorableUploadError(Object ex) {
  // exposed by disconnect-connect nemesis
  if (ex is sqlite.ClosedException) {
    return true;
  }

  // exposed by nemesis
  if (ex is http.ClientException &&
      (ex.message.startsWith(
            'Connection closed before full header was received',
          ) ||
          ex.message.startsWith(
            'HTTP request failed. Client is already closed.',
          ) ||
          ex.message.startsWith('Broken pipe') ||
          ex.message.startsWith('Connection reset by peer') ||
          ex.message.contains('Connection timed out'))) {
    return true;
  }

  // exposed by nemesis
  if (ex is Exception &&
      ex.toString().contains(
        'ClientException with SocketException: Connection timed out (OS Error: Connection timed out, errno = 110)',
      )) {
    return true;
  }

  // exposed by nemesis
  if (ex is SyncResponseException &&
      ex.statusCode == 408 &&
      ex.description.startsWith('Request Timeout')) {
    return true;
  }

  // exposed by disconnect-connect nemesis
  if (ex is SyncResponseException &&
      ex.statusCode == 429 &&
      ex.description.startsWith('Too Many Requests')) {
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

  // exposed by nemesis
  if (ex is http.ClientException &&
      (ex.message.startsWith(
            'Connection closed before full header was received',
          ) ||
          ex.message.startsWith('Broken pipe') ||
          ex.message.startsWith('Connection reset by peer'))) {
    return true;
  }

  // exposed by nemesis
  if (ex is Exception &&
      ex.toString().contains(
        'ClientException with SocketException: Connection timed out (OS Error: Connection timed out, errno = 110)',
      )) {
    return true;
  }

  // exposed by disconnect-connect nemesis
  if (ex is SyncResponseException &&
      ex.statusCode == 401 &&
      ex.description.contains('"exp" claim timestamp check failed')) {
    return true;
  }

  // exposed by nemeses
  if (ex is SyncResponseException &&
      ex.statusCode == 408 &&
      ex.description.contains('Request Timeout')) {
    return true;
  }

  // don't ignore unexpected
  return false;
}
