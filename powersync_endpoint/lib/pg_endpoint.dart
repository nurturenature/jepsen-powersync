import 'dart:io';
import 'package:postgres/postgres.dart' as pg;
import 'args.dart';
import 'endpoint.dart';
import 'log.dart';
import 'postgresql.dart' as local_pg;

class PGEndpoint extends Endpoint {
  @override
  Future<Map> sqlTxn(Map op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'txn');
    assert(op['value'].length >= 1);

    // augment op with client type
    op['clientType'] = 'pg';

    String newType = 'ok'; // assume ok

    // convert table as String to enum
    final table = switch (op['table'] as String) {
      'lww' => local_pg.Tables.lww,
      'mww' => local_pg.Tables.mww,
      _ => throw StateError('Invalid table in op: $op'),
    };

    try {
      // execute the PowerSync transaction in a PostgreSQL transaction
      // errors/throwing in the PostgreSQL transaction reverts it
      await local_pg.postgreSQL.runTx(
        (tx) async {
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
                    "Unexpected database state, uninitialized read for key: $k', in mop: $mop, for op: $op",
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
                    'Not 1 row affected by append in mop: $mop, with results: $result, for $op',
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
                    'invalid select: $select for mop: $mop in op: $op',
                  );
                  exit(11);
                }

                // return mop['v'] as a {k: v} map containing all read k/v
                mop['v'] = Map.fromEntries(
                  select
                      .map((resultRow) => resultRow.toColumnMap())
                      .map((row) => MapEntry(row['k'], row['v'])),
                );

                return mop;

              case 'write-some':
                // create a new Map to iterate over so we can modify the mop['v'] Map
                final Map<int, int> writeSome = Map.of(mop['v']);
                pg.Result update;
                for (final kv in writeSome.entries) {
                  update = await tx.execute(
                    "UPDATE mww SET v = GREATEST(${kv.value}, mww.v) WHERE k = ${kv.key} RETURNING *;",
                  );

                  // db is pre-seeded so 1 and only 1 result when updating
                  if (update.length != 1) {
                    log.severe(
                      'invalid update: $update for key: ${kv.key} in mop: $mop in op: $op',
                    );
                    exit(11);
                  }

                  // if another process wrote a greater value our write doesn't count
                  if (update.single.toColumnMap()['v'] > kv.value) {
                    mop['v'].remove([kv.key]);
                  }
                }

                return mop;

              default:
                throw StateError('Unexpected f: $f in mop: $mop in op: $op');
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
        log.severe('Fatal error from Postgres: ${se.message}');
        exit(21);
      }

      // no retry, just fail transaction, likely concurrent access or deadlock
      log.info('PostgreSQL exception: ${se.message}, for op: $op');
      newType = 'error';
    }

    op['type'] = newType;
    return op;
  }

  /// api endpoint for connect/disconnect, upload-queue-count/upload-queue-wait, and select-all
  @override
  Future<Map> powersyncApi(Map op) async {
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
        log.severe('Unknown powersyncApi request: $op');
        exit(100);
    }

    op['type'] = 'ok';
    return op;
  }
}
