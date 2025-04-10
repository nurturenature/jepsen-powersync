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
  postgresqlError,
  codingError,
}

/// All error exit codes.
const errorCodes = {
  ErrorReasons.strongConvergence: 1,
  ErrorReasons.sqlite3CausalConsistency: 2,
  ErrorReasons.postgresqlCausalConsistency: 3,
  ErrorReasons.syncStatusLastSyncedAt: 10,
  ErrorReasons.uploadQueueStatsCount: 12,
  ErrorReasons.invalidSqlite3Data: 20,
  ErrorReasons.invalidPostgresqlData: 22,
  ErrorReasons.backendConnectorUploadDataDuplicateId: 30,
  ErrorReasons.backendConnectorUploadDataPostgresql: 32,
  ErrorReasons.postgresqlError: 40,
  ErrorReasons.codingError: 100,
};
