import 'dart:collection';
import 'dart:io';
import 'package:powersync/powersync.dart';
import 'args.dart';
import 'backend_connector.dart';
import 'endpoint.dart';
import 'log.dart';
import 'schema.dart';
import 'utils.dart';

class PSEndpoint extends Endpoint {
  late final PowerSyncDatabase _db;
  late final PowerSyncBackendConnector _connector;

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

    await _db.initialize();
    log.info(
      'db: init: initialized with runtimeType: ${_db.runtimeType}, status: ${_db.currentStatus}',
    );

    _connector = CrudTransactionConnector(Tables.mww, _db);

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
      await futureSleep(100);
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
    log.info("db: init: ${Tables.mww.name}: $currTable");
  }

  @override
  Future<void> close() async {
    await _db.close();
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
        switch (mop['f']) {
          case 'read-all':
            final select = await tx.getAll('SELECT k,v FROM mww ORDER BY k;');

            // db is pre-seeded so all keys expected in result when reading
            if (select.length != args['keys']) {
              op['type'] = 'error';
              log.severe(
                'PowerSyncDatabase: invalid SELECT, tx.getAll(), ResultSet: $select for mop: $mop in op: $op',
              );
              exit(10);
            }

            // return mop['v'] as a {k: v} map containing all read k/v
            readAll = Map.fromEntries(
              select.map((row) => MapEntry(row['k'] as int, row['v'] as int)),
            );
            mop['v'] = readAll;

            return mop;

          case 'write-some':
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
                exit(10);
              }
            }

            return mop;

          default:
            throw StateError(
              'PowerSyncDatabase: invalid f: ${mop['f']} in mop: $mop in op: $op',
            );
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
  Future<SplayTreeMap> powersyncApi(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'api');
    assert(op['value'] != null);

    // augment op with client type
    op['clientType'] = 'ps';

    String newType = 'ok';

    switch (op['value']['f']) {
      case 'connect':
        await _db.connect(connector: _connector);
        final closed = _db.closed;
        final connected = _db.connected;
        final currentStatus = _db.currentStatus;
        final v = {
          'db.closed': closed,
          'db.connected': connected,
          'db.currentStatus': currentStatus,
        };
        op['value']['v'] = v;
        break;

      case 'disconnect':
        await _db.disconnect();
        final closed = _db.closed;
        final connected = _db.connected;
        final currentStatus = _db.currentStatus;
        final v = {
          'db.closed': closed,
          'db.connected': connected,
          'db.currentStatus': currentStatus,
        };
        op['value']['v'] = v;
        break;

      case 'close':
        await _db.close();
        final closed = _db.closed;
        final connected = _db.connected;
        final currentStatus = _db.currentStatus;
        final v = {
          'db.closed': closed,
          'db.connected': connected,
          'db.currentStatus': currentStatus,
        };
        if (!closed || connected) {
          log.warning(
            'PowerSyncDatabase: expected db.closed to be true and db.connected to be false after db.close(): $v',
          );
        }
        op['value']['v'] = v;
        break;

      case 'upload-queue-count':
        final uploadQueueCount = (await _db.getUploadQueueStats()).count;
        op['value']['v'] = {'db.uploadQueueStats.count': uploadQueueCount};
        break;

      case 'upload-queue-wait':
        while ((await _db.getUploadQueueStats()).count != 0) {
          log.info(
            'PowerSyncDatabase: waiting for db.uploadQueueStats.count == 0, currently ${(await _db.getUploadQueueStats()).count}...',
          );
          await futureSleep(1000);
        }
        op['value']['v'] = {'db.uploadQueueStats.count': 'queue-empty'};
        break;

      case 'downloading-wait':
        const maxTries = 30;
        const waitPerTry = 1000;

        int onTry = 1;
        var currentStatus = _db.currentStatus;
        while ((currentStatus.downloading) == true && onTry <= maxTries) {
          log.info(
            'PowerSyncDatabase: waiting for db.currentStatus.downloading == false: on try $onTry: $currentStatus',
          );
          await futureSleep(waitPerTry);
          onTry++;
          currentStatus = _db.currentStatus;
        }
        if (onTry > maxTries) {
          newType = 'error';
          op['type'] = newType; // update op now for better error message
          op['value']['v'] = {
            'error': 'Tried ${onTry - 1} times every ${waitPerTry}ms',
            'db.currentStatus.downloading': currentStatus.downloading,
          };
          log.warning(
            'PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried $onTry times every ${waitPerTry}ms',
          );
        } else {
          op['value']['v'] = {
            'db.currentStatus.downloading': currentStatus.downloading,
          };
        }
        break;

      case 'select-all':
        op['value']['v'] = await _selectAll();
        break;

      default:
        log.severe('PowerSyncDatabase: unknown powersyncApi request: $op');
        exit(100);
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

  // log PowerSync status changes
  void _logSyncStatus(PowerSyncDatabase db) {
    db.statusStream.listen((syncStatus) {
      log.finest('$syncStatus');
    });
  }

  // log PowerSync db updates
  void _logUpdates(PowerSyncDatabase db) {
    db.updates.listen((updateNotification) {
      log.finest('$updateNotification');
    });
  }
}
