import 'dart:core';
import 'dart:io';
import 'package:dotenv/dotenv.dart';

final _defaults = {
  'BACKEND_CONNECTOR': 'CrudTransactionConnector',
  'ENDPOINT_LOG_LEVEL': 'ALL',
  'ENDPOINT_PORT': '8089',
  'LOCAL_ONLY': 'false',
  'POWERSYNC_URL': 'http://powersync:8080',
  'SQLITE3_PATH': '${Directory.current.path}/powersync.sqlite3',
  'USER_ID': 'userId'
};

/// Global config.
final config = DotEnv(includePlatformEnvironment: true)..load();

void initConfig() {
  _defaults.forEach((k, v) {
    if (!config.isDefined(k)) {
      config.addAll({k: v});
    }
  });
}
