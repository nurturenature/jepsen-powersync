import 'package:sqlite3_endpoint/db.dart';
import 'package:sqlite3_endpoint/endpoint.dart';

Future<void> main(List<String> arguments) async {
  print('Initializing db');
  await initDb();
  print('db initialized: $db');

  print('Initializing endpoint');
  await initEndpoint();
  print('endpoint initialized: $endpoint');

  print('Listening at ${endpoint.port}');
}
