import 'package:logging/logging.dart';
import 'package:powersync_fuzz/args.dart';

/// Global logger.
late Logger log;

void initLogging(String name) {
  log = Logger(name);

  Level level;
  switch (args['logLevel'] as String) {
    case 'OFF':
      level = Level.OFF;
    case 'FINEST':
      level = Level.FINEST;
    case 'FINER':
      level = Level.FINER;
    case 'FINE':
      level = Level.FINE;
    case 'CONFIG':
      level = Level.CONFIG;
    case 'INFO':
      level = Level.INFO;
    case 'WARNING':
      level = Level.WARNING;
    default:
      level = Level.ALL;
  }

  Logger.root.level = level;
  Logger.root.onRecord.listen((record) {
    print(
        '[${record.time.toString()}] [${record.loggerName}] [${record.level.name}] ${record.message}');
  });
}
