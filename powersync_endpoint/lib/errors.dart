import 'dart:io';
import 'log.dart';

/// All error exit reasons.
enum ErrorReasons {
  strongConvergence,
  sqlite3CausalConsistency,
  postgresqlCausalConsistency,
  syncStatusLastSyncedAt,
  uploadQueueStatsCount,
  invalidSqlite3Data,
  invalidPostgresqlData,
  backendConnectorUploadDataDuplicateId,
  backendConnectorUploadDataPostgresql,
  powersyncDatabaseApiTimeout,
  postgresqlError,
  codingError,
}

// All error exit codes.
const _errorCodes = {
  ErrorReasons.strongConvergence: 1,
  ErrorReasons.sqlite3CausalConsistency: 2,
  ErrorReasons.postgresqlCausalConsistency: 3,
  ErrorReasons.syncStatusLastSyncedAt: 10,
  ErrorReasons.uploadQueueStatsCount: 12,
  ErrorReasons.invalidSqlite3Data: 20,
  ErrorReasons.invalidPostgresqlData: 22,
  ErrorReasons.backendConnectorUploadDataDuplicateId: 30,
  ErrorReasons.backendConnectorUploadDataPostgresql: 32,
  ErrorReasons.powersyncDatabaseApiTimeout: 40,
  ErrorReasons.postgresqlError: 50,
  ErrorReasons.codingError: 100,
};

/// Log severe message with name of reason and exit code for reason.
/// Exit with exit code for reason.
void errorExit(ErrorReasons reason) {
  final exitCode = _errorCodes[reason]!;

  log.severe('Error exit: reason: ${reason.name}, code: $exitCode');
  exit(exitCode);
}
