import 'dart:io';
import 'package:args/args.dart';

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
    args['clients'] = int.parse(results.option('clients')!);
    args['keys'] = int.parse(results.option('keys')!);
    args['rate'] = int.parse(results.option('rate')!);
    args['txns'] = int.parse(results.option('txns')!);
    args['logLevel'] = results.option('logLevel')!;
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    _printUsage(argParser);
  }
}

ArgParser _buildParser() {
  return ArgParser()
    ..addOption('clients',
        abbr: 'c', defaultsTo: '5', help: 'number of PowerSync clients')
    ..addOption('keys', abbr: 'k', defaultsTo: '100', help: 'number of keys')
    ..addOption('rate', abbr: 'r', defaultsTo: '100', help: 'txn rate in ms')
    ..addOption('txns', abbr: 't', defaultsTo: '100', help: 'number of txns')
    ..addOption('logLevel', abbr: 'l', defaultsTo: 'ALL', help: 'log level')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );
}

void _printUsage(ArgParser argParser) {
  print('Usage: dart powersync_fuzz.dart <flags> [arguments]');
  print(argParser.usage);
}
