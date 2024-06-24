// lib/backend_connector.dart
import 'dart:io';
import 'package:powersync/powersync.dart';
import 'auth.dart';
import 'config.dart';
import 'log.dart';

class NoOpConnector extends PowerSyncBackendConnector {
  PowerSyncDatabase db;

  NoOpConnector(this.db);

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await generateToken();

    return PowerSyncCredentials(
        endpoint: '${config['POWERSYNC_URL']}', token: token);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    log.severe('localOnly:true should never uploadData!');

    exit(127);
  }
}
