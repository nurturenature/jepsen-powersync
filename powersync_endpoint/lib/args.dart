import 'dart:io';
import 'package:args/args.dart';
import 'endpoint.dart';
import 'nemesis/disconnect.dart';

/// Global args set from CLI or default args.
Map<String, dynamic> args = {};

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
    args['endpoint'] = results.option('endpoint')!;
    args['clientImpl'] = clientImplLookup[results.option('clientImpl')]!;
    args['clients'] = int.parse(results.option('clients')!);
    args['postgresql'] = results.flag('postgresql');
    // txn values
    args['keys'] = int.parse(results.option('keys')!);
    args['rate'] = int.parse(results.option('rate')!);
    args['time'] = int.parse(results.option('time')!);
    args['maxTxnLen'] = int.parse(results.option('maxTxnLen')!);
    // nemeses
    args['disconnect'] = disconnectNemesesLookup[results.option('disconnect')]!;
    args['stop'] = results.flag('stop');
    args['kill'] = results.flag('kill');
    args['partition'] = results.flag('partition');
    args['pause'] = results.flag('pause');
    args['interval'] = int.parse(results.option('interval')!);
    // http_endpoint
    args['httpPort'] = int.parse(results.option('httpPort')!);
    // logging
    args['logLevel'] = results.option('logLevel')!;
    // PostgreSQL
    args['PG_DATABASE_HOST'] = results.option('PG_DATABASE_HOST')!;
    args['PG_DATABASE_PORT'] = int.parse(results.option('PG_DATABASE_PORT')!);
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
  final Set<int> allKeys = {};
  for (var i = 0; i < args['keys']; i++) {
    allKeys.add(i);
  }
  args['allKeys'] = allKeys;
}

ArgParser _buildParser() {
  return ArgParser()
    ..addOption(
      'endpoint',
      allowed: ['powersync', 'postgresql'],
      defaultsTo: 'powersync',
      help: 'endpoint database',
    )
    ..addOption(
      'clientImpl',
      defaultsTo: 'rust',
      allowed: ['dflt', 'dart', 'rust'],
      allowedHelp: {
        'dflt': 'default client implementation, currently dart',
        'dart': 'dart client',
        'rust': 'rust client',
      },
    )
    ..addOption(
      'clients',
      abbr: 'c',
      defaultsTo: '5',
      help: 'number of PowerSync clients',
    )
    ..addFlag(
      'postgresql',
      defaultsTo: false,
      negatable: true,
      help: 'include a postgresql client',
    )
    // txn values
    ..addOption('keys', abbr: 'k', defaultsTo: '100', help: 'number of keys')
    ..addOption(
      'rate',
      abbr: 'r',
      defaultsTo: '30',
      help: 'txn rate in txn per second',
    )
    ..addOption(
      'time',
      abbr: 't',
      defaultsTo: '100',
      help: 'time of test in seconds',
    )
    ..addOption('maxTxnLen', defaultsTo: '4', help: 'max transaction length')
    ..addOption(
      'disconnect',
      defaultsTo: 'none',
      allowed: ['none', 'orderly', 'random'],
      allowedHelp: {
        'none': 'no disconnecting',
        'orderly': 'disconnect then reconnect only the disconnected clients',
        'random':
            'randomly disconnect or connect clients regardless of their state',
      },
    )
    ..addFlag(
      'stop',
      defaultsTo: false,
      negatable: true,
      help: 'stop/start Workers at interval',
    )
    ..addFlag(
      'kill',
      defaultsTo: false,
      negatable: true,
      help: 'kill/start Workers at interval',
    )
    ..addFlag(
      'partition',
      defaultsTo: false,
      negatable: true,
      help: 'partition Workers from PowerSync Service at interval',
    )
    ..addFlag(
      'pause',
      defaultsTo: false,
      negatable: true,
      help: 'pause/resume client Worker Isolates at interval',
    )
    ..addOption(
      'interval',
      abbr: 'i',
      defaultsTo: '5',
      help: 'invoke nemeses every 0 <= random <= interval * 2 seconds',
    )
    // logging
    ..addOption(
      'logLevel',
      abbr: 'l',
      allowed: [
        'OFF',
        'FINEST',
        'FINER',
        'FINE',
        'CONFIG',
        'INFO',
        'WARNING',
        'SEVERE',
        'ALL',
      ],
      defaultsTo: 'ALL',
      help: 'log level',
    )
    // http_endpoint
    ..addOption('httpPort', defaultsTo: '8089', help: 'http_endpoint port')
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
