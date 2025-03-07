import 'dart:collection';
import 'dart:io';
import 'package:postgres/postgres.dart' as postgres;
import 'args.dart';
import 'endpoint.dart';
import 'log.dart';

class PGEndpoint extends Endpoint {
  late final postgres.Connection _postgreSQL;

  @override
  Future<void> init({String filePath = '', bool preserveData = false}) async {
    final endpoint = postgres.Endpoint(
      host: args['PG_DATABASE_HOST']!,
      port: args['PG_DATABASE_PORT']!,
      database: args['PG_DATABASE_NAME']!,
      username: args['PG_DATABASE_USER']!,
      password: args['PG_DATABASE_PASSWORD']!,
    );
    final settings = postgres.ConnectionSettings(
      sslMode: postgres.SslMode.disable,
    );

    _postgreSQL = await postgres.Connection.open(endpoint, settings: settings);

    log.config(
      'PostgreSQL: connected @ ${endpoint.host}:${endpoint.port}/${endpoint.database} as ${endpoint.username}/${endpoint.password} with socket: ${endpoint.isUnixSocket}',
    );
  }

  @override
  Future<void> close() async {
    await _postgreSQL.close(force: true);
  }

  @override
  Future<SplayTreeMap> sqlTxn(SplayTreeMap op) async {
    assert(op['type'] == 'invoke');
    assert(op['f'] == 'txn');
    assert(op['value'].length >= 1);

    // augment op with client type
    op['clientType'] = 'pg';

    String newType = 'ok'; // assume ok

    try {
      // execute the PowerSync transaction in a PostgreSQL transaction
      // errors/throwing in the PostgreSQL transaction reverts it
      await _postgreSQL.runTx(
        (tx) async {
          late final Map<int, int> readAll;
          final valueAsFutures = op['value'].map((
            Map<String, dynamic> mop,
          ) async {
            final {'f': String f, 'k': dynamic k, 'v': dynamic v} = mop;
            switch (f) {
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
        settings: postgres.TransactionSettings(
          isolationLevel: postgres.IsolationLevel.repeatableRead,
        ),
      );
    } on postgres.ServerException catch (se) {
      // truly fatal
      if (se.severity == postgres.Severity.panic ||
          se.severity == postgres.Severity.fatal) {
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

      case 'close':
        await close();
        op['value']['v'] = {'pg': 'closed'};
        break;

      case 'upload-queue-count':
        op['value']['v'] = {'pg': 'no-queue'};
        break;

      case 'upload-queue-wait':
        op['value']['v'] = {'pg': 'no-queue'};
        break;

      case 'downloading-wait':
        op['value']['v'] = {'pg': 'no-downloading'};
        break;

      case 'select-all':
        op['value']['v'] = await selectAll();
        break;

      default:
        log.severe('PostgreSQL: unknown api request: $op');
        exit(100);
    }

    op['type'] = 'ok';
    return op;
  }

  Future<Map<int, int>> selectAll() async {
    final Map<int, int> response = {};
    response.addEntries(
      (await _postgreSQL.execute('SELECT k,v FROM mww ORDER BY k;'))
          .map((resultRow) => resultRow.toColumnMap())
          .map((row) => MapEntry(row['k'], row['v'])),
    );
    return response;
  }
}
