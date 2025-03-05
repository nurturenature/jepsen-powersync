import 'dart:collection';
import 'dart:io';
import 'package:postgres/postgres.dart' as pg;
import 'args.dart';
import 'endpoint.dart';
import 'log.dart';
import 'postgresql.dart' as local_pg;

class PGEndpoint extends Endpoint {
  @override
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'txn');
    assert(op['value'].length >= 1);

    // augment op with client type
    op['clientType'] = 'pg';

    String newType = 'ok'; // assume ok

    // convert table as String to enum
    final table = local_pg.Tables.values.byName(op['table'] as String);

    try {
      // execute the PowerSync transaction in a PostgreSQL transaction
      // errors/throwing in the PostgreSQL transaction reverts it
      await local_pg.postgreSQL.runTx(
        (tx) async {
          late final Map<int, int> readAll;
          final valueAsFutures = op['value'].map((
            Map<String, dynamic> mop,
          ) async {
            final {'f': String f, 'k': dynamic k, 'v': dynamic v} = mop;
            switch (f) {
              case 'r':
                final result = await tx.execute(
                  'SELECT v from ${table.name} where k = $k',
                );
                final v =
                    result
                        .single // throws if not 1 and only 1 result
                        .toColumnMap() // friendly map
                        ['v'];

                // literal null read is an error, db is pre-seeded
                if (v == null) {
                  log.severe(
                    "PostgreSQL: unexpected database state, uninitialized read for key: $k', in mop: $mop, for op: $op",
                  );
                  exit(11);
                }

                switch (table) {
                  case local_pg.Tables.lww:
                    final vStr = v as String;
                    // v == '' is a null read
                    if (vStr != '') {
                      // trim leading space that was created on first INERT/UPDATE
                      mop['v'] = '[${vStr.trimLeft()}]';
                    }
                    break;

                  case local_pg.Tables.mww:
                    mop['v'] = v as int;
                    break;
                }
                return mop;

              case 'append':
                final pg.Result result = switch (table) {
                  local_pg.Tables.lww => await tx.execute('''
                    INSERT INTO ${table.name} (k,v) VALUES ($k,$v) 
                    ON CONFLICT (k) DO UPDATE SET v = concat_ws(' ',${table.name}.v,'$v')
                    '''),
                  local_pg.Tables.mww => await tx.execute(
                    'UPDATE ${table.name} SET v = $v WHERE k = $k',
                  ),
                };
                if (result.affectedRows != 1) {
                  log.severe(
                    'PostgreSQL: not 1 row affected by append in mop: $mop, with results: $result, for $op',
                  );
                  exit(11);
                }
                return mop;

              case 'read-all':
                final select = await tx.execute(
                  'SELECT k,v from mww ORDER BY k;',
                );

                // db is pre-seeded so all keys expected in result when reading
                if (select.length != args['keys']) {
                  log.severe(
                    'PostgreSQL: invalid select: $select for mop: $mop in op: $op',
                  );
                  exit(11);
                }

                // return mop['v'] as a {k: v} map containing all read k/v
                readAll = Map.fromEntries(
                  select
                      .map((resultRow) => resultRow.toColumnMap())
                      .map((row) => MapEntry(row['k'] as int, row['v'] as int)),
                );
                mop['v'] = readAll;

                return mop;

              case 'write-some':
                final Map<int, int> writeSome = mop['v'];
                // from the time of our txn request, sent via a ReceivePort
                //   - a txn from another client may have completed and replicated
                //   - so check to insure writes are still max write wins
                // note creation of List of keys to avoid mutation issues in loop
                for (final k in List<int>.from(
                  writeSome.keys,
                  growable: false,
                )) {
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
                      'PostgreSQL: invalid update: $update for key: ${kv.key} in mop: $mop in op: $op',
                    );
                    exit(11);
                  }
                }

                return mop;

              default:
                throw StateError(
                  'PostgreSQL: unexpected f: $f in mop: $mop in op: $op',
                );
            }
          });

          // as map() is a lazy Iterable, and it's toElement() is async.
          // it's necessary to iterate and await so txns are executed and op['value'] updated
          for (final mop in valueAsFutures) {
            await mop;
          }
        },
        settings: pg.TransactionSettings(
          isolationLevel: pg.IsolationLevel.repeatableRead,
        ),
      );
    } on pg.ServerException catch (se) {
      // truly fatal
      if (se.severity == pg.Severity.panic ||
          se.severity == pg.Severity.fatal) {
        log.severe('PostgreSQL: fatal error: ${se.message}');
        exit(21);
      }

      // no retry, just fail transaction, likely concurrent access or deadlock
      log.info('PostgreSQL: exception: ${se.message}, for op: $op');
      newType = 'error';
    }

    op['type'] = newType;
    return op;
  }

  /// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
  @override
  Future<SplayTreeMap> powersyncApi(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'api');
    assert(op['value'] != null);

    // augment op with client type
    op['clientType'] = 'pg';

    switch (op['value']['f']) {
      case 'connect':
        op['value']['v'] = {'pg': 'always-connected'};
        break;

      case 'disconnect':
        op['value']['v'] = {'pg': 'always-connected'};
        break;

      case 'upload-queue-count':
        op['value']['v'] = {'pg': 0};
        break;

      case 'upload-queue-wait':
        op['value']['v'] = {'pg': 'no-queue'};
        break;

      case 'downloading-wait':
        op['value']['v'] = {'pg': 'no-downloading'};
        break;

      case 'select-all':
        op['value']['v'] = switch (op['value']['k']) {
          'lww' => await local_pg.selectAllLWW(),
          'mww' => await local_pg.selectAllMWW(),
          _ => throw StateError("Invalid table value: ${op['value']['k']}"),
        };
        break;

      default:
        log.severe('PostgreSQL: unknown api request: $op');
        exit(100);
    }

    op['type'] = 'ok';
    return op;
  }
}
