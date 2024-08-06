Hi,

Mostly just an FYI on observing connecting/disconnecting and the statusStream.

Don't know if `connect/disconnect` are expected to be idempotent?
It appears connect always does a disconnect before re-connecting.

hasSynced and lastSyncedAt don't always update in unison, e.g. lastSyncedAt can get set to null even though db has been synced and hasSynced remains true.

And so far, all local writes when disconnected are replicated on reconnection, and reconnection fully catches up the local db. 

connect when connected:
```log
[12:4:13.909] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:04:04.793216, hasSynced: true, error: null>
[12:4:13.909] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:04:04.793216, hasSynced: true, error: null>
[12:4:13.918] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: true downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[12:4:13.918] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: true downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[12:4:13.972] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[12:4:13.972] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[12:4:13.977] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[12:4:13.990] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:04:13.990260, hasSynced: true, error: null>
```

connect when disconnected:
```log
[11:58:46.478] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 11:54:38.176819, hasSynced: true, error: null>
[11:58:46.487] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: true downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[11:58:46.488] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: true downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[11:58:46.549] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: false uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[11:58:46.549] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[11:58:46.553] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: null, hasSynced: true, error: null>
[11:58:46.569] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 11:58:46.569435, hasSynced: true, error: null>
```

disconnect when connected
```log
[12:3:7.960] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:02:52.023069, hasSynced: true, error: null>
[12:3:7.961] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:02:52.023069, hasSynced: true, error: null>
```

disconnect when disconnected
```log
[12:0:51.521] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false downloading: false uploading: false lastSyncedAt: 2024-08-06 12:00:28.991090, hasSynced: true, error: null>
```