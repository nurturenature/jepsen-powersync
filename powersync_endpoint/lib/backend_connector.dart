// lib/backend_connector.dart
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:powersync/powersync.dart';
import 'auth.dart';
import 'config.dart';
import 'log.dart';

// Assuming single use of `uploadData`, i.e. single Postgres connection appropriate
// TODO: find out if PowerSync will call `uploadData` concurrently?

/// Global Postgres connection.
late Connection postgres;

/// `BackendConnector` will reuse single Postgres connection.
/// `.env` `POSTGRES_` vars must be set, note null! checks.
Future<void> initPostgres() async {
  final settings = ConnectionSettings(sslMode: SslMode.disable);
  postgres = await Connection.open(
      Endpoint(
          host: config['PG_DATABASE_HOST']!,
          database: config['PG_DATABASE_NAME']!,
          username: config['PG_DATABASE_USER']!,
          password: config['PG_DATABASE_PASSWORD']!),
      settings: settings);
}

/// Postgres Response codes that we cannot recover from by retrying.
final unrecoverableResponseCodes = [
  // Class 22 — Data Exception
  // Examples include data type mismatch.
  RegExp('^22...\$'),
  // Class 23 — Integrity Constraint Violation.
  // Examples include NOT NULL, FOREIGN KEY and UNIQUE violations.
  RegExp('^23...\$'),
  // INSUFFICIENT PRIVILEGE - typically a row-level security violation
  RegExp('^42501\$')
];

/// A `PowerSyncBackendConnector` with:
/// - permissive auth
/// - logs error and exits if `uploadData()` called
class NoOpConnector extends PowerSyncBackendConnector {
  PowerSyncDatabase db;

  NoOpConnector(this.db);

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(
        endpoint: '${config['POWERSYNC_URL']}', token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    log.severe('localOnly:true should never uploadData!');

    exit(127);
  }
}

/// A `PowerSyncBackendConnector` with:
/// - permissive auth
/// - `CrudBatch` oriented `uploadData()`
///
/// Processes:
/// - one `CrudBatch` per call, not eager
/// - one `CrudEntry` at a time
/// - reuses single Postgres `Connection`
///
/// Consistency quite casual, not at all causal, will allow:
/// - non-Atomic transactions
/// - Intermediate Reads
/// - Monotonic Read cycling
///
/// Exception handling:
/// - recoverable
///   - `throw` to signal PowerSync to retry
/// - unrecoverable
///   - indicates architectural/implementation flaws
///   - not safe to proceed
///     - `exit` to force app restart and resync
class CrudBatchConnector extends PowerSyncBackendConnector {
  PowerSyncDatabase db;

  CrudBatchConnector(this.db);

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(
        endpoint: '${config['POWERSYNC_URL']}', token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final crudBatch = await db.getCrudBatch();

    // any work todo?
    if (crudBatch == null) {
      return;
    }

    // process one CrudEntry at a time
    try {
      for (final crudEntry in crudBatch.crud) {
        switch (crudEntry.op) {
          case UpdateType.put:
            final put = await postgres.execute(
                'INSERT INTO lww (id,k,v) VALUES (\$1,\$2,\$3)',
                parameters: [
                  crudEntry.id,
                  crudEntry.opData!['k'],
                  crudEntry.opData!['v']
                ]);
            log.finer('uploadData: put result: $put');
            break;

          case UpdateType.patch:
            final patch = await postgres.execute(
                'UPDATE lww SET v = \$1 WHERE id = \$2',
                parameters: [crudEntry.opData!['v'], crudEntry.id]);
            log.finer('uploadData: patch result: $patch');
            break;

          case UpdateType.delete:
            final delete = await postgres.execute(
                'DELETE FROM lww WHERE id = \$1',
                parameters: [crudEntry.id]);
            log.finer('uploadData: delete result: $delete');
            break;

          default:
            log.severe("Unknown UpdateType: ${crudEntry.op}");
            exit(127);
        }
      }

      await crudBatch.complete();
    } on ServerException catch (se) {
      // truly fatal
      if (se.severity == Severity.panic || se.severity == Severity.fatal) {
        log.severe("Fatal error from Postgres: $se");
        exit(127);
      }

      // unrecoverable?
      if (unrecoverableResponseCodes.any((regex) => regex.hasMatch(se.code!))) {
        log.severe("Unrecoverable error from Postgres: $se");
        exit(127);
      }

      // recoverable, throw exception to signal PowerSync to retry
      log.info(
          "Recoverable error in Postgres, signaling PowerSync to retry: $se");
      rethrow;
    } catch (ex) {
      log.severe("Unexpected Exception: $ex");
      exit(127);
    }
  }
}
