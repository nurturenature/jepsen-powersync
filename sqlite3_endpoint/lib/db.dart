import 'package:sqlite_async/sqlite_async.dart';

late SqliteDatabase db;

const path = '/tmp/sqlite3.db';

final migrations = SqliteMigrations()
  ..add(SqliteMigration(1, (tx) async {
    await tx.execute('''
      CREATE TABLE IF NOT EXISTS lww (
        k INTEGER NOT NULL PRIMARY KEY,
        v text
      )
    ''');
  }));

Future<void> initDb() async {
  print("Creating db");
  db = SqliteDatabase(path: path);

  print("Creating lww table");
  await migrations.migrate(db);
  await db.execute('''
    DELETE FROM lww''');

  final tables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1
  ''');
  final lww = await db.execute('''
    SELECT * FROM lww
  ''');
  print("tables: $tables");
  print("lww: $lww");
}
