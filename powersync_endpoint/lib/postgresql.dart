import 'package:postgres/postgres.dart';
import 'args.dart';

/// Assuming single use of `backendConnector` `uploadData`, i.e. single Postgres connection appropriate

/// Global Postgres connection.
late Connection postgreSQL;

/// possible tables
enum Tables { lww, mww }

Future<void> init(Tables table, bool initData) async {
  final settings = ConnectionSettings(sslMode: SslMode.disable);
  postgreSQL = await Connection.open(
      Endpoint(
          host: args['PG_DATABASE_HOST']!,
          database: args['PG_DATABASE_NAME']!,
          username: args['PG_DATABASE_USER']!,
          password: args['PG_DATABASE_PASSWORD']!),
      settings: settings);

  // start test from a known state?
  if (initData) {
    switch (table) {
      case Tables.lww:
        await _initDataLWW();
        break;

      case Tables.mww:
        await _initDataMWW();
        break;
    }
  }
}

// start test from a known lww state
Future<void> _initDataLWW() async {
  // conditionally create lww table
  await postgreSQL.execute('''
    CREATE TABLE IF NOT EXISTS public.lww (
        id uuid NOT NULL DEFAULT gen_random_uuid (),
        k INTEGER NOT NULL UNIQUE,
        v TEXT NOT NULL,
        CONSTRAINT lww_pkey PRIMARY KEY (id)
    );
    ''');

  // populate table with initial value for all keys
  await postgreSQL.execute('DELETE FROM lww;');

  // initialize all k,v in a single transaction so all values are replicated/synced as a whole
  await postgreSQL.runTx((tx) async {
    for (var key = 0; key < args['keys']; key++) {
      await tx.execute("INSERT INTO lww (k,v) VALUES ($key,'');");
    }
  },
      settings:
          TransactionSettings(isolationLevel: IsolationLevel.repeatableRead));
}

// start test from a known mww state
Future<void> _initDataMWW() async {
  // conditionally create mww table
  await postgreSQL.execute('''
    CREATE TABLE IF NOT EXISTS public.mww (
        id TEXT NOT NULL,
        k INTEGER NOT NULL UNIQUE,
        v INTEGER NOT NULL,
        CONSTRAINT mww_pkey PRIMARY KEY (id)
    );
    ''');

  // populate table with initial value for all keys
  await postgreSQL.execute('DELETE FROM mww;');

  // initialize all id,k,v in a single transaction so all values are replicated/synced as a whole
  await postgreSQL.runTx((tx) async {
    for (var key = 0; key < args['keys']; key++) {
      await tx.execute("INSERT INTO mww (id,k,v) VALUES ('$key',$key,-1);");
    }
  },
      settings:
          TransactionSettings(isolationLevel: IsolationLevel.repeatableRead));
}

Future<Map<int, String>> selectAllLWW() async {
  final Map<int, String> response = {};
  response.addEntries(
      (await postgreSQL.execute('SELECT k,v FROM lww ORDER BY k;'))
          .map((resultRow) => resultRow.toColumnMap())
          .map((row) => MapEntry(row['k'], row['v'])));
  return response;
}

Future<Map<int, int>> selectAllMWW() async {
  final Map<int, int> response = {};
  response.addEntries(
      (await postgreSQL.execute('SELECT k,v FROM mww ORDER BY k;'))
          .map((resultRow) => resultRow.toColumnMap())
          .map((row) => MapEntry(row['k'], row['v'])));
  return response;
}

/// Expect to be fully done with PostgreSQL, so force close it.
Future<void> close() async {
  await postgreSQL.close(force: true);
}
