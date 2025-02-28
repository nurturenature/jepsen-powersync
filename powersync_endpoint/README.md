A Jepsen endpoint backed by PowerSync.

Entrypoint is `bin/powersync_http.dart`


A local CLI fuzzer for PowerSync.

Entrypoint is `bin/powersync_fuzz.dart`


Library code is in `lib/`.

### Return Codes

0 - success

1 - final reads violate Strong Convergence
2 - Causal Consistency violation in a txn
3 - Causal Consistency violation in a PostgreSQL txn 

10 - invalid data in PowerSync db
11 - invalid data in PostgreSQL db

20 - 
21 - PostgreSQL error

30 - BackendConnector upload failure

40 - unknown upload error in SyncStatus
41 - unknown download error in SyncStatus

100 - invalid state due to coding error

### Nemesis Behavior

#### --stop

```dart
// Database is closed, which disconnects, frees resources
await db.close();

// Isolate is killed immediately, do not wait for next event loop opportunity
Isolate.kill(priority: Isolate.immediate);
```

Worker client is started:
  - newly spawned Isolate
  - SQLite3 data files are preserved

#### --kill

```dart
// no warning, interaction, e.g. disconnect, close, etc, with PowerSync database

// Isolate is killed immediately, do not wait for next event loop opportunity
Isolate.kill(priority: Isolate.immediate);
```

Worker client is started:
  - newly spawned Isolate
  - SQLite3 data files are preserved

----

### Reproducing

In `jepsen-powersync/docker`:
```bash
./powersync-fuzz-loop.sh ./powersync_fuzz --table mww --clients 10 --rate 10 --time 200 --no-postgresql --disconnect --no-stop --no-kill --partition --no-pause --interval 5
```
will loop until exit coe == 2.
