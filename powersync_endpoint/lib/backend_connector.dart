import 'dart:io';
import 'dart:math';
import 'package:postgres/postgres.dart';
import 'package:powersync/powersync.dart';
import 'args.dart';
import 'auth.dart';
import 'log.dart';
import 'postgresql.dart';
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

    exit(127);
  }
}

/// As PostgreSQL transactions are executed with an isolation level of repeatable read,
/// it is normal, and the client's responsibility, to retry serialization errors.
const _retryablePgErrors = {
  '40001', // serialization_failure
  '40P01' // deadlock_detected
};

// retry/delay strategy
// - delay diversity
//   - random uniform distribution
//   - not too big to keep LWW fair(er)
// - persistent retries
//   - relative large max to keep LWW fair(er)
const _minRetryDelay = 32; // in ms, each retry delay is min <= random <= max
const _maxRetryDelay = 256;
const _maxRetries = 32;
final _rng = Random();

dynamic _txWithRetries(Tables table, List<CrudEntry> crud) async {
  for (var i = 0; i < _maxRetries; i++) {
    try {
      // execute the PowerSync transaction in a PostgreSQL transaction
      // throwing in the PostgreSQL transaction reverts it
      await postgreSQL.runTx((tx) async {
        for (final crudEntry in crud) {
          switch (crudEntry.op) {
            case UpdateType.put:
              final put = await tx.execute(
                  'INSERT INTO ${table.name} (id,k,v) VALUES (\$1,\$2,\$3) RETURNING *',
                  parameters: [
                    crudEntry.id,
                    crudEntry.opData!['k'],
                    crudEntry.opData!['v']
                  ]);
              final row =
                  put.single; // gets and enforces 1 and only 1 affected row

              log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} put: $row');
              break;

            case UpdateType.patch:
              late Result patch;
              switch (table) {
                case Tables.lww:
                  patch = await tx.execute(
                    'UPDATE ${table.name} SET v = \'${crudEntry.opData!['v']}\' WHERE id = \'${crudEntry.id}\' RETURNING *',
                  );
                  break;

                case Tables.mww:
                  // max write wins, so GREATEST() value of v
                  final v = crudEntry.opData!['v'] as int;
                  patch = await tx.execute(
                      'UPDATE ${table.name} SET v = GREATEST($v, ${table.name}.v) WHERE id = \'${crudEntry.id}\' RETURNING *');
                  break;
              }

              final row = patch // result of UPDATE
                  .single // gets and enforces 1 and only 1 affected row
                  .toColumnMap(); // pretty Map
              row.remove('id'); // readability
              log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} patch: $row');
              break;

            case UpdateType.delete:
              final delete = await tx.execute(
                  'DELETE FROM ${table.name} WHERE id = \$1 RETURNING *',
                  parameters: [crudEntry.id]);
              final row =
                  delete.single; // gets and enforces 1 and only 1 affected row

              log.finer(
                  'uploadData: txn: ${crudEntry.transactionId} delete: $row');
              break;
          }
        }
      },
          settings: TransactionSettings(
              isolationLevel: IsolationLevel.repeatableRead));
    } on ServerException catch (se) {
      // truly fatal
      if (se.severity == Severity.panic || se.severity == Severity.fatal) {
        return ['error', 'Fatal error from Postgres: ${se.message}'];
      }

      // retryable?
      if (_retryablePgErrors.contains(se.code)) {
        log.fine(
            "Retrying txn: ${crud.first.transactionId} PostgreSQL: ${se.message}");

        await futureSleep(
            _rng.nextInt(_maxRetryDelay - _minRetryDelay + 1) + _minRetryDelay);

        continue;
      }

      // not retryable, recoverable
      return [
        'error',
        'Unrecoverable ServerException, severity: ${se.severity}, code: ${se.code}, ServerException: $se'
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
  Tables table;
  PowerSyncDatabase db;

  CrudTransactionConnector(this.table, this.db);

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(endpoint: args['POWERSYNC_URL']!, token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    // eagerly process all available PowerSync transactions
    for (CrudTransaction? crudTransaction = await db.getNextCrudTransaction();
        crudTransaction != null;
        crudTransaction = await db.getNextCrudTransaction()) {
      switch (await _txWithRetries(table, crudTransaction.crud)) {
        case 'ok':
          await crudTransaction.complete();
          break;

        case ['error', final String cause]:
          log.severe(
              'Unable to process transaction: $crudTransaction, cause: $cause');
          exit(127);

        case final unknown:
          log.severe('Invalid transaction result: $unknown');
          exit(127);
      }
    }
  }
}
