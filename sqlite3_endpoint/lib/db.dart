import 'dart:io';

import 'package:sqlite_async/sqlite_async.dart';

late SqliteDatabase db;

final path = '${Directory.current.path}/sqlite3_endpoint.sqlite3';

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
  // always start test with a new db in a known state
  if (await File(path).exists()) {
    await File(path).delete();
    await File('$path-shm').delete();
    await File('$path-wal').delete();
  }
  db = SqliteDatabase(path: path);
  print('db: $path, closed: ${db.closed}');

  print("Creating lww table");
  await migrations.migrate(db);
  final tables = await db.execute('''
    SELECT name FROM sqlite_schema 
    WHERE type IN ('table','view') 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY 1
  ''');
  print("tables: $tables");

  await db.execute('''
    DELETE FROM lww''');
  final lww = await db.execute('''
    SELECT * FROM lww
  ''');
  print("lww: $lww");
}
