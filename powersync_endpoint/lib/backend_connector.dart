import 'package:postgres/postgres.dart' as postgres;
import 'package:powersync/powersync.dart';
import 'args.dart';
import 'auth.dart';
import 'errors.dart';
import 'log.dart';
import 'utils.dart';

/// A no-op `PowerSyncBackendConnector` with:
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

    errorExit(ErrorReasons.codingError);
  }
}

/// As PostgreSQL transactions are executed with an isolation level of repeatable read,
/// it is normal, and the client's responsibility, to retry serialization errors.
const _retryablePgErrors = {
  '40001', // serialization_failure
  '40P01', // deadlock_detected
  '57014', // canceling statement due to user request, e.g. timeout
};

// be persistent with retries
// relatively large max as MWW transactions should always go through
const _maxRetries = 64;

// Transactions are:
//
// Tightly coupled to a PostgreSQL transaction
// - transactions retried as appropriate
//
// Consistency:
// - Atomic transactions
//
// Exception handling:
// - are treated as unrecoverable
//   - indicates architectural/implementation flaws
//   - not safe to proceed
//     - `exit` to force app restart and resync
Future<void> _txWithRetries(
  int callCounter,
  postgres.Connection pg,
  List<CrudEntry> crud,
) async {
  final BackOff backOff = BackOff();
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
                  'uploadData: call: $callCounter txn: ${crudEntry.transactionId} put: {$k: $v}',
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
                final reason = switch (patchV < v) {
                  true => 'greatest($patchV, $v)',
                  false => '',
                };
                log.finer(
                  'uploadData: call: $callCounter txn: ${crudEntry.transactionId} patch: {$k: $patchV} $reason',
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
                  'uploadData: call: $callCounter txn: ${crudEntry.transactionId} delete: {$k: $v}',
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
        log.severe(
          'uploadData: call: $callCounter txn: ${crud.first.transactionId} PostgreSQL fatal ServerException: $se, in transaction: $crud',
        );
        errorExit(ErrorReasons.postgresqlError);
      }

      // retryable?
      if (_retryablePgErrors.contains(se.code)) {
        log.finer(
          "uploadData: call: $callCounter txn: ${crud.first.transactionId} retrying due to PostgreSQL: ${se.message}",
        );

        await backOff.backOffAndWait();

        continue;
      }

      // not retryable, recoverable
      log.severe(
        'uploadData: call: $callCounter txn: ${crud.first.transactionId} PostgreSQL unrecoverable ServerException: $se, in transaction: $crud',
      );
      errorExit(ErrorReasons.postgresqlError);
    } catch (ex) {
      log.severe(
        'uploadData: call: $callCounter txn: ${crud.first.transactionId} PostgreSQL unexpected Exception: $ex, in transaction: $crud',
      );
      errorExit(ErrorReasons.postgresqlError);
    }

    // transaction completed and committed successfully
    return;
  }

  // retried and failed
  log.severe(
    'uploadData: call: $callCounter txn: ${crud.first.transactionId} PostgreSQL max retries exceeded: $_maxRetries, in transaction: $crud',
  );
  errorExit(ErrorReasons.backendConnectorUploadDataPostgresql);
}

/// A `PowerSyncBackendConnector` with:
/// - permissive auth
/// - `CrudTransaction` oriented `uploadData()`
///
/// Eagerly consumes `CrudTransaction`s
/// - clears upload queue so local db can receive updates
/// - uploads data until `getNextCrudTransaction` is `null`
class CrudTransactionConnector extends PowerSyncBackendConnector {
  final postgres.Connection _pg;
  int _callCounter = 0;
  final Set<int> _transactionIds = {};

  CrudTransactionConnector._(this._pg);

  /// Create a CrudTransactionConnector with its own PostgreSQL Connection.
  static Future<CrudTransactionConnector> connector() async {
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

    return CrudTransactionConnector._(pg);
  }

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(endpoint: args['POWERSYNC_URL']!, token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase db) async {
    // count our calls for debugging purposes
    _callCounter = _callCounter + 1;
    final callCounter = _callCounter;
    log.finer(
      'uploadData: call: $callCounter begin with UploadQueueStats.count: ${(await db.getUploadQueueStats()).count}',
    );

    // eagerly process all available PowerSync transactions
    for (
      CrudTransaction? crudTransaction = await db.getNextCrudTransaction();
      crudTransaction != null;
      crudTransaction = await db.getNextCrudTransaction()
    ) {
      log.finer(
        'uploadData: call: $callCounter txn: ${crudTransaction.transactionId} begin $crudTransaction',
      );

      // it's an error to try and upload the same transaction
      if (_transactionIds.contains(crudTransaction.transactionId)) {
        log.severe(
          'uploadData: call: $callCounter txn: ${crudTransaction.transactionId} Duplicate call to uploadData or duplicate getNextCrudTransaction() for transaction id!',
        );
        errorExit(ErrorReasons.backendConnectorUploadDataDuplicateId);
      }
      _transactionIds.add(crudTransaction.transactionId!);

      await _txWithRetries(callCounter, _pg, crudTransaction.crud);
      await crudTransaction.complete();

      log.finer(
        'uploadData: call: $callCounter txn: ${crudTransaction.transactionId} committed',
      );
    }

    log.finer(
      'uploadData: call: $callCounter end with UploadQueueStats.count: ${(await db.getUploadQueueStats()).count}',
    );
  }
}

/// backoff doubles from min to max then wraps-around back to min
class BackOff {
  static const _minRetryDelay = 16;
  static const _maxRetryDelay = 512;

  int _delay = 0;

  Future<void> backOffAndWait() async {
    _delay = _delay * 2;

    // first use or > max wraparound?
    if (_delay == 0 || _delay > _maxRetryDelay) {
      _delay = _minRetryDelay;
    }

    await futureDelay(_delay);
  }
}
