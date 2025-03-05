import 'dart:collection';
import 'dart:io';
import 'args.dart';
import 'db.dart';
import 'endpoint.dart';
import 'log.dart';
import 'utils.dart';

class PSEndpoint extends Endpoint {
  /// Execute an sql transaction and return the results:
  /// - request is a Jepsen op value as a Map
  ///   - transaction maps are in value: [{f: r | append, k: key, v: value}...]
  /// - response is an updated Jepsen op value with the txn results
  ///
  /// No Exceptions are expected!
  /// Single user local PowerSync is totally available, strict serializable.
  /// No catching, let Exceptions fail the test
  @override
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'txn');
    assert(op['value'].length >= 1);

    // augment op with client type
    op['clientType'] = 'ps';

    final table = op['table']! as String;

    await db.writeTransaction((tx) async {
      late final Map<int, int> readAll;
      final valueAsFutures = op['value'].map((mop) async {
        switch (mop['f']) {
          case 'r':
            final select = await tx.getOptional(
              'SELECT k,v from $table where k = ?',
              [mop['k']],
            );
            // result row expected as db is pre-seeded
            if (select == null) {
              log.severe(
                "PowerSyncDatabase: unexpected state, uninitialized read key ${mop['k']} for op: $op",
              );
              exit(10);
            }

            // literal null read is an error, db is pre-seeded
            if (select['v'] == null) {
              log.severe(
                "PowerSyncDatabase: literal null read for key: ${mop['k']} in mop: $mop in op: $op",
              );
              exit(10);
            }

            switch (table) {
              case 'lww':
                // v == '' is a  null read
                if ((select['v'] as String) == '') {
                  return mop;
                } else {
                  // trim leading space that was created on first UPDATE
                  final v = (select['v'] as String).trimLeft();
                  mop['v'] = "[$v]";
                  return mop;
                }

              case 'mww':
                mop['v'] = select['v'] as int;
                return mop;

              default:
                throw StateError('Invalid table value: $table');
            }

          case 'append':
            final update = switch (table) {
              // note: creates leading space on first update, upsert isn't supported
              'lww' => await tx.execute(
                'UPDATE lww SET v = lww.v || \' \' || ? WHERE k = ? RETURNING *',
                [mop['v'], mop['k']],
              ),
              'mww' => await tx.execute(
                'UPDATE mww SET v = ? WHERE k = ? RETURNING *',
                [mop['v'], mop['k']],
              ),
              _ => throw StateError('Invalid table value: $table'),
            };

            // result set expected as db is pre-seeded
            if (update.isEmpty) {
              log.severe(
                "PowerSyncDatabase: unexpected state, uninitialized append key ${mop['k']} for op: $op",
              );
              exit(10);
            }

            return mop;

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

  /// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
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
        await db.connect(connector: connector);
        final closed = db.closed;
        final connected = db.connected;
        final currentStatus = db.currentStatus;
        final v = {
          'db.closed': closed,
          'db.connected': connected,
          'db.currentStatus': currentStatus,
        };
        if (!connected) {
          log.warning(
            'PowerSyncDatabase: expected db.connected to be true after db.connect(): $v',
          );
        }
        op['value']['v'] = v;
        break;

      case 'disconnect':
        await db.disconnect();
        final closed = db.closed;
        final connected = db.connected;
        final currentStatus = db.currentStatus;
        final v = {
          'db.closed': closed,
          'db.connected': connected,
          'db.currentStatus': currentStatus,
        };
        if (connected) {
          log.warning(
            'PowerSyncDatabase: expected db.connected to be false after db.disconnect(): $v',
          );
        }
        op['value']['v'] = v;
        break;

      case 'close':
        await db.close();
        final closed = db.closed;
        final connected = db.connected;
        final currentStatus = db.currentStatus;
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
        final uploadQueueCount = (await db.getUploadQueueStats()).count;
        op['value']['v'] = {'db.uploadQueueStats.count': uploadQueueCount};
        break;

      case 'upload-queue-wait':
        while ((await db.getUploadQueueStats()).count != 0) {
          log.info(
            'PowerSyncDatabase: waiting for db.uploadQueueStats.count == 0, currently ${(await db.getUploadQueueStats()).count}...',
          );
          await futureSleep(1000);
        }
        op['value']['v'] = {'db.uploadQueueStats.count': 'queue-empty'};
        break;

      case 'downloading-wait':
        const maxTries = 30;
        const waitPerTry = 1000;

        int onTry = 1;
        var currentStatus = db.currentStatus;
        while ((currentStatus.downloading) == true && onTry <= maxTries) {
          log.info(
            'PowerSyncDatabase: waiting for db.currentStatus.downloading == false: on try $onTry: $currentStatus',
          );
          await futureSleep(waitPerTry);
          onTry++;
          currentStatus = db.currentStatus;
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
        op['value']['v'] = switch (op['value']['k']) {
          'lww' => await selectAllLWW(),
          'mww' => await selectAllMWW(),
          _ =>
            throw StateError(
              "PowerSyncDatabase: invalid table value: ${op['value']['k']}",
            ),
        };
        break;

      default:
        log.severe('PowerSyncDatabase: unknown powersyncApi request: $op');
        exit(100);
    }

    op['type'] = newType;
    return op;
  }
}
