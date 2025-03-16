import 'dart:io';
import 'dart:math';
import 'package:postgres/postgres.dart' as postgres;
import 'package:powersync/powersync.dart';
import 'args.dart';
import 'auth.dart';
import 'log.dart';
import 'utils.dart';

/// A `PowerSyncBackendConnector` with:
/// - permissive auth
/// - logs error and exits if `uploadData()` called
class NoOpConnector extends PowerSyncBackendConnector {
  PowerSyncDatabase db;

  NoOpConnector(this.db);

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(endpoint: args['POWERSYNC_URL']!, token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    log.severe('localOnly:true should never uploadData!');

    exit(100);
  }
}

/// As PostgreSQL transactions are executed with an isolation level of repeatable read,
/// it is normal, and the client's responsibility, to retry serialization errors.
const _retryablePgErrors = {
  '40001', // serialization_failure
  '40P01', // deadlock_detected
};

// retry/delay strategy
// - delay diversity
//   - random uniform distribution
//   - not too big to keep MWW fair(er)
// - persistent retries
//   - relative large max to keep MWW fair(er)
const _minRetryDelay = 32; // in ms, each retry delay is min <= random <= max
const _maxRetryDelay = 512;
const _maxRetries = 64;
final _rng = Random();

dynamic _txWithRetries(postgres.Connection pg, List<CrudEntry> crud) async {
  for (var i = 0; i < _maxRetries; i++) {
    try {
      // execute the PowerSync transaction in a PostgreSQL transaction
      // throwing in the PostgreSQL transaction reverts it
      await pg.runTx(
        (tx) async {
          for (final crudEntry in crud) {
            switch (crudEntry.op) {
              case UpdateType.put:
                final put = await tx.execute(
                  'INSERT INTO mww (id,k,v) VALUES (\$1,\$2,\$3) RETURNING *',
                  parameters: [
                    crudEntry.id,
                    crudEntry.opData!['k'],
                    crudEntry.opData!['v'],
                  ],
                );
                final {'k': int k, 'v': int v} =
                    put
                        .single // gets and enforces 1 and only 1 affected row
                        .toColumnMap();
                log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} put: {$k: $v}',
                );
                break;

              case UpdateType.patch:
                // max write wins, so GREATEST() value of v
                final patchV = crudEntry.opData!['v'] as int;
                final patch = await tx.execute(
                  'UPDATE mww SET v = GREATEST($patchV, mww.v) WHERE id = \'${crudEntry.id}\' RETURNING *',
                );

                final {'k': int k, 'v': int v} =
                    patch // result of UPDATE
                        .single // gets and enforces 1 and only 1 affected row
                        .toColumnMap(); // pretty Map
                log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} patch: {$k: $v}',
                );
                break;

              case UpdateType.delete:
                final delete = await tx.execute(
                  'DELETE FROM mww WHERE id = \$1 RETURNING *',
                  parameters: [crudEntry.id],
                );
                final {'k': int k, 'v': int v} =
                    delete
                        .single // gets and enforces 1 and only 1 affected row
                        .toColumnMap();
                log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} delete: {$k: $v}',
                );
                break;
            }
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
        return ['error', 'Fatal error from Postgres: ${se.message}'];
      }

      // retryable?
      if (_retryablePgErrors.contains(se.code)) {
        log.fine(
          "uploadData: txn: ${crud.first.transactionId} retrying due to PostgreSQL: ${se.message}",
        );

        await futureSleep(
          _rng.nextInt(_maxRetryDelay - _minRetryDelay + 1) + _minRetryDelay,
        );

        continue;
      }

      // not retryable, recoverable
      return [
        'error',
        'Unrecoverable ServerException, severity: ${se.severity}, code: ${se.code}, ServerException: $se',
      ];
    } catch (ex) {
      // TODO: some exceptions, such as connection failures should be thrown for PowerSync to catch and then retry
      //       experimentally expose these through fault injection in the tests first, then implement catch/recover
      return ['error', 'Unexpected Exception: $ex'];
    }

    // transaction completed and committed successfully
    return 'ok';
  }

  // retried and failed
  return ['error', 'Max retries, $_maxRetries, exceeded'];
}

/// A `PowerSyncBackendConnector` with:
/// - permissive auth
/// - `CrudTransaction` oriented `uploadData()`
///
/// Eagerly consumes `CrudTransaction`s
/// - clears upload queue so local db can receive updates
/// - uploads data until `getNextCrudTransaction` is `null`
///
/// Tightly coupled to a PostgreSQL transaction
/// - transactions retried as appropriate
///
/// Consistency:
/// - Atomic transactions
///
/// Exception handling:
/// - recoverable
///   - `throw` to signal PowerSync to retry
/// - unrecoverable
///   - indicates architectural/implementation flaws
///   - not safe to proceed
///     - `exit` to force app restart and resync
class CrudTransactionConnector extends PowerSyncBackendConnector {
  final postgres.Connection _pg;
  final PowerSyncDatabase _db;

  CrudTransactionConnector._(this._pg, this._db);

  static Future<CrudTransactionConnector> connector(
    PowerSyncDatabase ps,
  ) async {
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

    final pg = await postgres.Connection.open(endpoint, settings: settings);

    log.config(
      'PostgreSQL: connected @ ${endpoint.host}:${endpoint.port}/${endpoint.database} as ${endpoint.username}/${endpoint.password} with socket: ${endpoint.isUnixSocket}',
    );

    return CrudTransactionConnector._(pg, ps);
  }

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(endpoint: args['POWERSYNC_URL']!, token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    // eagerly process all available PowerSync transactions
    for (
      CrudTransaction? crudTransaction = await _db.getNextCrudTransaction();
      crudTransaction != null;
      crudTransaction = await _db.getNextCrudTransaction()
    ) {
      switch (await _txWithRetries(_pg, crudTransaction.crud)) {
        case 'ok':
          await crudTransaction.complete();
          log.finer(
            'uploadData: txn: ${crudTransaction.transactionId} complete',
          );

          break;

        case ['error', final String cause]:
          log.severe(
            'Unable to process transaction: $crudTransaction, cause: $cause',
          );
          exit(30);

        case final unknown:
          log.severe('Invalid transaction result: $unknown');
          exit(100);
      }
    }
  }
}
