import 'dart:collection';
import 'dart:io';
import 'package:powersync/powersync.dart';
import 'args.dart';
import 'backend_connector.dart';
import 'endpoint.dart';
import 'error_codes.dart';
import 'log.dart';
import 'schema.dart';
import 'utils.dart';

class PSEndpoint extends Endpoint {
  late final PowerSyncDatabase _db;
  late final PowerSyncBackendConnector _connector;
  DateTime? _lastSyncedAt;

  @override
  Future<void> init({String filePath = '', bool preserveData = false}) async {
    // delete any preexisting SQLite3 files?
    if (await File(filePath).exists()) {
      log.info('db: init: preexisting SQLite3 file: $filePath');

      if (!preserveData) {
        await _deleteSqlite3Files(filePath);
        log.info('\tpreexisting file deleted');
      } else {
        log.info('\tpreexisting file preserved');
      }
    } else {
      log.info('db: init: no preexisting SQLite3 file: $filePath');
    }

    _db = PowerSyncDatabase(schema: schemaMWW, path: filePath);
    log.info(
      "db: init: created db with schemas: ${_db.schema.tables.map((table) => {table.name: table.columns.map((column) => '${column.name} ${column.type.name}')})}, path: $filePath",
    );

    await _db.initialize().timeout(
      powerSyncTimeoutDuration,
      onTimeout: () {
        log.severe(
          'db: init: failed to initialize PowerSync Database, call to initialize() timed out after $powerSyncTimeoutDuration',
        );
        exit(errorCodes[ErrorReasons.powersyncDatabaseApiTimeout]!);
      },
    );
    log.info(
      'db: init: initialized with runtimeType: ${_db.runtimeType}, status: ${_db.currentStatus}',
    );

    _connector = await CrudTransactionConnector.connector();

    // retry significantly faster than default of 5s, designed to leverage a Transaction oriented BackendConnector
    // must be set before connecting
    _db.retryDelay = Duration(milliseconds: 1000);

    await _db.connect(connector: _connector);
    log.info(
      'db: init: connected with connector: $_connector, status: ${_db.currentStatus}',
    );

    await _db.waitForFirstSync();
    log.info(
      'db: init: first sync completed with status: ${_db.currentStatus}',
    );

    // insure local db is complete, i.e. has all the keys
    // PostgreSQL is source of truth, explicitly initialized at app startup with all keys
    var currentStatus = _db.currentStatus;
    Set<int> psKeys = Set.from((await _selectAll()).keys);
    while (!psKeys.containsAll(args['allKeys'] as Set<int>)) {
      log.info(
        'db: init: db.waitForFirstSync() incomplete, missing keys: ${(args['allKeys'] as Set<int>).difference(psKeys)}',
      );
      log.info('\twith currentStatus: $currentStatus');

      // sleep and try again
      await futureDelay(100);
      currentStatus = _db.currentStatus;
      psKeys = Set.from((await _selectAll()).keys);
    }
    log.info(
      'db: init: db.waitForFirstSync() confirmed with all keys present: $psKeys',
    );

    // log PowerSync status changes
    _logSyncStatus(_db);

    // log PowerSync db updates
    _logUpdates(_db);

    // log current db contents
    final dbTables = await _db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1;
  ''');

    final currTable = await _selectAll();
    log.info("db: init: tables: $dbTables");
    log.info("db: init: mww: $currTable");
  }

  @override
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'txn');
    assert(op['value'].length >= 1);

    // augment op with client type
    op['clientType'] = 'ps';

    await _db.writeTransaction((tx) async {
      late final Map<int, int> readAll;
      final valueAsFutures = op['value'].map((mop) async {
        final f = sqlTransactionLookup[mop['f']]!;
        switch (f) {
          case SQLTransactions.readAll:
            final select = await tx.getAll('SELECT k,v FROM mww ORDER BY k;');

            // db is pre-seeded so all keys expected in result when reading
            if (select.length != args['keys']) {
              op['type'] = 'fail';
              log.severe(
                'PowerSyncDatabase: invalid SELECT, tx.getAll(), ResultSet: $select for mop: $mop in op: $op',
              );
              exit(errorCodes[ErrorReasons.invalidSqlite3Data]!);
            }

            // return mop['v'] as a {k: v} map containing all read k/v
            readAll = Map.fromEntries(
              select.map((row) => MapEntry(row['k'] as int, row['v'] as int)),
            );
            mop['v'] = readAll;

            return mop;

          case SQLTransactions.writeSome:
            final Map<int, int> writeSome = mop['v'];
            // from the time of our txn request, sent via a ReceivePort
            //   - a txn from another client may have completed and replicated
            //   - so check to insure writes are still max write wins
            // note creation of List of keys to avoid mutation issues in loop
            for (final k in List<int>.from(writeSome.keys, growable: false)) {
              if (writeSome[k]! < readAll[k]!) {
                writeSome.remove(k);
              }
            }

            for (final kv in writeSome.entries) {
              final update = await tx.execute(
                "UPDATE mww SET v = ${kv.value} WHERE k = ${kv.key} RETURNING *;",
              );

              // db is pre-seeded so 1 and only 1 result when updating
              if (update.length != 1) {
                log.severe(
                  'PowerSyncDatabase: invalid update: $update for key: ${kv.key} in mop: $mop in op: $op',
                );
                exit(errorCodes[ErrorReasons.invalidSqlite3Data]!);
              }
            }

            return mop;
        }
      });

      // as map() is a lazy Iterable, and it's toElement() is async.
      // it's necessary to iterate and await so txns are executed and op['value'] updated
      for (final mop in valueAsFutures) {
        await mop;
      }
    });

    op['type'] = 'ok';
    return op;
  }

  @override
  Future<SplayTreeMap> dbApi(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'api');
    assert(op['value'] != null);

    // augment op with client type
    op['clientType'] = 'ps';

    String newType = 'ok';

    final f = apiCallLookup[op['value']['f']]!;
    switch (f) {
      case APICalls.connect:
        await _db.connect(connector: _connector);
        op['value']['v'] = {'db': 'connected'};
        break;

      case APICalls.disconnect:
        await _db.disconnect();
        op['value']['v'] = {'db': 'disconnected'};
        break;

      case APICalls.close:
        await _db.close();
        op['value']['v'] = {'db': 'closed'};
        break;

      case APICalls.uploadQueueCount:
        final uploadQueueCount =
            (await _db.getUploadQueueStats().timeout(
              powerSyncTimeoutDuration,
              onTimeout: () {
                log.severe(
                  'db: api: call to db.getUploadQueueStats() timed out after $powerSyncTimeoutDuration',
                );
                exit(errorCodes[ErrorReasons.powersyncDatabaseApiTimeout]!);
              },
            )).count;
        op['value']['v'] = {'db.uploadQueueStats.count': uploadQueueCount};
        break;

      case APICalls.uploadQueueWait:
        int prevCount = 0;
        int prevTimes = 0;
        const maxTimes = 10;

        int count = (await _db.getUploadQueueStats()).count;
        while (count != 0) {
          // check for a stuck count
          if (count == prevCount) {
            prevTimes = prevTimes + 1;

            if (prevTimes > maxTimes) {
              log.severe(
                'UploadQueueStats.count appears to be stuck at $count after waiting for ${prevTimes}s',
              );
              log.severe('\tdb.closed: ${_db.closed}');
              log.severe('\tdb.connected: ${_db.connected}');
              log.severe('\tdb.currentStatus: ${_db.currentStatus}');
              log.severe(
                '\tdb.getUploadQueueStats(): ${await _db.getUploadQueueStats(includeSize: true)}',
              );
              exit(errorCodes[ErrorReasons.uploadQueueStatsCount]!);
            }
          } else {
            prevCount = count;
            prevTimes = 0;
          }

          log.fine(
            'database api: ${APICalls.uploadQueueWait.name}: waiting on UploadQueueStats.count: $count ...',
          );
          log.fine('\tdb.currentStatus: ${_db.currentStatus}');

          await futureDelay(1000);

          count = (await _db.getUploadQueueStats()).count;
        }

        op['value']['v'] = {'db.uploadQueueStats.count': 'queue-empty'};
        break;

      case APICalls.downloadingWait:
        const maxTries = 30;
        const waitPerTry = 1000;

        int onTry = 1;
        var currentStatus = _db.currentStatus;
        while ((currentStatus.downloading) == true && onTry <= maxTries) {
          log.fine(
            'database api: ${APICalls.downloadingWait.name}: waiting on SyncStatus.downloading: true...',
          );
          await futureDelay(waitPerTry);
          onTry++;
          currentStatus = _db.currentStatus;
        }
        if (onTry > maxTries) {
          newType = 'info';
          op['type'] = newType; // update op now for better error message
          op['value']['v'] = {
            'error':
                'waited for SyncStatus.downloading: false $onTry times every ${waitPerTry}ms',
          };
          log.warning(
            'database api: ${APICalls.downloadingWait.name}: waited for SyncStatus.downloading: false $onTry times every ${waitPerTry}ms',
          );
        } else {
          op['value']['v'] = {'db.SyncStatus.downloading:': false};
        }
        break;

      case APICalls.selectAll:
        op['value']['v'] = await _selectAll();
        break;
    }

    op['type'] = newType;
    return op;
  }

  /// Select all rows from mww table and return {k: v}.
  Future<Map<int, int>> _selectAll() async {
    return Map.fromEntries(
      (await _db.getAll(
        'SELECT k,v FROM mww ORDER BY k;',
      )).map((row) => MapEntry(row['k'], row['v'])),
    );
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

  // Log PowerSync status changes.
  // Check that lastSyncedAt always goes forward in time.
  void _logSyncStatus(PowerSyncDatabase db) {
    db.statusStream.listen((syncStatus) {
      log.finest('$syncStatus');

      final lastSyncedAt = syncStatus.lastSyncedAt;

      // looking for lastSyncedAt that goes backwards in time
      if (_lastSyncedAt == null) {
        _lastSyncedAt = lastSyncedAt;
      } else if (lastSyncedAt == null) {
        log.severe(
          'SyncStatus.lastSyncedAt reverted from $_lastSyncedAt to null',
        );
        exit(errorCodes[ErrorReasons.syncStatusLastSyncedAt]!);
      } else {
        switch (_lastSyncedAt!.compareTo(lastSyncedAt)) {
          case -1:
            _lastSyncedAt = lastSyncedAt;
            break;
          case 0:
            break;
          case 1:
            log.severe(
              'SyncStatus.lastSyncedAt went back in time from $_lastSyncedAt to $lastSyncedAt',
            );
            exit(errorCodes[ErrorReasons.syncStatusLastSyncedAt]!);
        }
      }
    });
  }

  // log PowerSync db updates
  void _logUpdates(PowerSyncDatabase db) {
    db.updates.listen((updateNotification) {
      log.finest('$updateNotification');
    });
  }
}
