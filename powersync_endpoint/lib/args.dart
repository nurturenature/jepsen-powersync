import 'dart:io';
import 'package:args/args.dart';

/// Global args set from CLI or default args.
Map<String, dynamic> args = {};

/// A Set of all keys
late Set<int> allKeys;

/// Parse CLI args into global args
void parseArgs(List<String> arguments) {
  final ArgParser argParser = _buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);

    // if help, usage then exit
    if (results.wasParsed('help')) {
      _printUsage(argParser);
      exit(0);
    }

    // set args based on CLI or defaults
    args['clients'] = int.parse(results.option('clients')!);
    // txn values
    args['keys'] = int.parse(results.option('keys')!);
    args['rate'] = int.parse(results.option('rate')!);
    args['time'] = int.parse(results.option('time')!);
    args['maxTxnLen'] = int.parse(results.option('maxTxnLen')!);
    // disconnect/connect
    args['disconnect'] = results.flag('disconnect');
    args['interval'] = int.parse(results.option('interval')!);
    // http_endpoint
    args['httpPort'] = int.parse(results.option('httpPort')!);
    // logging
    args['logLevel'] = results.option('logLevel')!;
    // PostgreSQL
    args['PG_DATABASE_HOST'] = results.option('PG_DATABASE_HOST')!;
    args['PG_DATABASE_PORT'] = results.option('PG_DATABASE_PORT')!;
    args['PG_DATABASE_NAME'] = results.option('PG_DATABASE_NAME')!;
    args['PG_DATABASE_USER'] = results.option('PG_DATABASE_USER')!;
    args['PG_DATABASE_PASSWORD'] = results.option('PG_DATABASE_PASSWORD')!;
    // PowerSync
    args['POWERSYNC_URL'] = results.option('POWERSYNC_URL')!;
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    _printUsage(argParser);
  }

  // init common values based on args
  allKeys = {};
  for (var i = 0; i < args['keys']; i++) {
    allKeys.add(i);
  }
}

ArgParser _buildParser() {
  return ArgParser()
    ..addOption('clients',
        abbr: 'c', defaultsTo: '5', help: 'number of PowerSync clients')
    // txn values
    ..addOption('keys', abbr: 'k', defaultsTo: '100', help: 'number of keys')
    ..addOption('rate',
        abbr: 'r', defaultsTo: '30', help: 'txn rate in txn per second')
    ..addOption('time',
        abbr: 't', defaultsTo: '100', help: 'time of test in seconds')
    ..addOption('maxTxnLen', defaultsTo: '4', help: 'max transaction length')
    ..addFlag('disconnect',
        defaultsTo: false,
        negatable: true,
        help: 'call disconnect/connect API at intervals')
    ..addOption('interval',
        abbr: 'i',
        defaultsTo: '5',
        help: 'disconnect/connect every interval in seconds')
    // http_endpoint
    ..addOption('httpPort', defaultsTo: '8089', help: 'http_endpoint port')
    // logging
    ..addOption('logLevel', abbr: 'l', defaultsTo: 'ALL', help: 'log level')
    // PostgreSQL
    ..addOption('PG_DATABASE_HOST', defaultsTo: 'pg-db')
    ..addOption('PG_DATABASE_PORT', defaultsTo: '5432')
    ..addOption('PG_DATABASE_NAME', defaultsTo: 'postgres')
    ..addOption('PG_DATABASE_USER', defaultsTo: 'postgres')
    ..addOption('PG_DATABASE_PASSWORD', defaultsTo: 'mypassword')
    // PowerSync
    ..addOption('POWERSYNC_URL', defaultsTo: 'http://powersync:8080')
    // help
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}

void _printUsage(ArgParser argParser) {
  print('Usage: dart powersync_(http|fuzz).dart <flags> [arguments]');
  print(argParser.usage);
}
