import 'package:postgres/postgres.dart';
import 'args.dart';

/// Assuming single use of `backendConnector` `uploadData`, i.e. single Postgres connection appropriate

/// Global Postgres connection.
late Connection postgreSQL;

Future<void> init({bool initData = true}) async {
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
    await _initData();
  }
}

// start test from a known state
Future<void> _initData() async {
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
  for (var key = 0; key < args['keys']; key++) {
    await postgreSQL.execute("INSERT INTO lww (k,v) VALUES ($key,'');");
  }
}

Future<Map<int, String>> selectAll(String table) async {
  final Map<int, String> response = {};
  response.addEntries(
      (await postgreSQL.execute('SELECT k,v FROM $table ORDER BY k;'))
          .map((resultRow) => resultRow.toColumnMap())
          .map((row) => MapEntry(row['k'], row['v'])));
  return response;
}

/// Expect to be fully done with PostgreSQL, so force close it.
Future<void> close() async {
  await postgreSQL.close(force: true);
}
