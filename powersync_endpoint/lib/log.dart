import 'package:logging/logging.dart';
import 'config.dart';

/// Global logger.
final log = Logger('powersync_endpoint');

void initLogging() {
  Level level;
  switch (config['ENDPOINT_LOG_LEVEL'] as String) {
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
