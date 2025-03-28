## Logbook

Working on Strong Convergence anomaly [issue](issues/strong-convergence.md) using [powersync_fuzz](../powersync_endpoint/README.md) as discussed below.


Jepsen has been able to find and exhibit non Causally Consistent behavior when testing PowerSync.

But Jepsen is a bit of a heavy lift:
- full featured generic environment
  - each client is its own container
  - written in Clojure
  - analyzes the test history
    - with acyclic graphs for transaction values
    - using Adya's full blown SQL consistency models and research

So `powersync_fuzz` was developed:
- written as a minimalistic Dart CLI application
  - uses existing Powersync Dart client libraries
  - easier to understand, modify
- analyzes the test history dynamically
  - just for Causal Consistency
  - uses simple/efficient Lists of integers for client state

See `powersync_fuzz` [readme](../powersync_endpoint/README.md).

A full suite of [GitHub Actions](https://github.com/nurturenature/jepsen-powersync/actions) that use `powersync_fuzz` to demonstrate anomalies.

----

## History

### Issue Fixed and Tested

- [`db.statusStream` has a large # of contiguous duplicate SyncStatus messages, ~70% of all messages are duplicates](https://github.com/powersync-ja/powersync.dart/issues/224)
  
  `db.statusStream` has a large # of contiguous duplicate `SyncStatus` messages.
  Usually ~70% of all messages are duplicates.

  The logging code: 
  ```dart
  db.statusStream.listen((syncStatus) {
      log.finest('statusStream: $syncStatus');
  });
  ```

  Often produces a series of duplicate messages (note the following 3 duplicates even occur within the same millisecond timestamp):
  ```log
  [2:4:26.279] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: 2025-01-04 02:04:26.098549, hasSynced: true, error: null>
  [2:4:26.279] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: 2025-01-04 02:04:26.098549, hasSynced: true, error: null>
  [2:4:26.279] [powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: 2025-01-04 02:04:26.098549, hasSynced: true, error: null>
  ```

  To quantify the amount of duplication:
  ```dart
  int distinctSyncStatus = 0;
  int totalSyncStatus = 0;
  db.statusStream.distinct().listen((syncStatus) {
    distinctSyncStatus++;
    log.finest('distinctSyncStatus: $distinctSyncStatus');
  });
  db.statusStream.listen((syncStatus) {
    totalSyncStatus++;
    log.finest('totalSyncStatus: $totalSyncStatus');
  });
  ```

  Produces typical output of:
  ```log
  distinctSyncStatus: 1675
  ...
  totalSyncStatus: 6230
  ```

  It seems like any de-duping of the `db.statusStream` should be done in the library vs the client application:
  - avoid overhead of:
    - sending duplicate messages to client application
    - de-duping in the client application
    - reactive UI/behavior/functionality being unnecessarily re-triggered in the client application
  - and maybe other behavior/functionality at the library level is listening to the stream and duplicating work?

  Note that this does not affect correctness and may not be considered a bug.
  Maybe concerns re overhead are misplaced, a bit OCD :)

  
- `connect/disconnect`

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

----

### ~~Errors That Aren't Understood Yet~~

This turned out to be an error in the applications `backendConnector` and usage by the test:

This behavior was an artifact of the application's newly developed causally consistent backendConnector, and not inherent in PowerSync.

Characteristics of the test and backendConnector that exhibited this behavior:

- triggered by higher rates, transactions/second/client
- larger transactions involving multiple updates to more keys
  -  so more likely to conflict with other client's concurrent transactions with shared keys 
- key/value updates with an exponential key distribution, i.e. grind against individual keys to try and force update inconsistencies
- once the transactions/sec crossed a threshold, e.g. starting to challenge PostgreSQL's update latency
  - retries were triggered due to PostgreSQL deadlocks/concurrent updates against common keys
  - normal for all applications with multiple clients, same keys in a single transaction
- retry values were too hot, i.e. too small
- the end of test quiescence was inadequate to allow the backendConnector to complete the upload queue
  - so final reads weren't really final 😔

The backendConnector retry min/max values have been expanded and now the test explicitly waits for the upload queue == 0 during the end of test quiescence before final reads.

Still need to tune the application's backendConnector's retry logic.
For a fair(er) LWW, one almost wants a reverse exponential back-off, more like a Zeno's back-in 🙃

#### Original, Incorrect Concerns:

### ~~Known Errors In New CrudTransactionConnector~~ 

- PostgreSQL could not serialize access due to concurrent update
  - Max retries, 10, exceeded

TODO: Implement a try hard, try harder, 'reverse' exponential backoff?
- fair and polite
- currently testing a more patient strategy
  ```dart
  // retry/delay strategy
  // - delay diversity, random uniform distribution
  // - persistent retries, relative large max
  const _minRetryDelay = 1; // in ms, each retry delay is min <= random <= max
  const _maxRetryDelay = 64;
  const _maxRetries = 32;
  final _rng = Random();
  ```
----

### ~~Errors That Aren't Understood Yet~~

Only consistency anomaly consistently found
- triggered by sustained higher transaction rates, 100 tps
- PostgreSQL -> client db replication stops
- introducing disconnecting/connecting, killing/starting, etc actually makes the system a bit more resilient


```clj
; can break replication and convergence
; example of all clients doing a different final read of key 0
:divergent-reads {0 {nil #{"n3"},
                     [2 5] #{"n4"},
                     [3 4 7] #{"n1"},
                     [6] #{"n2"},
                     [1] #{"n5"}}}
                 ...
```

Let's:
- shrink the tests to the smallest reproducible
- trace a few transactions end-to-end
- insure that it's not a test artifact, incorrect usage
- maybe explore a Dart CLI app that reproduces?

Test command:
```bash
lein run test --workload convergence --rate 100 --time-limit 30 --nodes n1,n2,n3,n4,n5 --postgres-nodes n1
```

Smallest example of divergence:
```clj
:divergent-reads {0 {nil #{"n3"
                           "n4"
                           "n5"},
                     [3] #{"n1" "n2"}}}
```

Turn on PostgreSQL statement logging to see replication from `CrudTransactionConnector`:

- see correct transaction isolation
  ```log
  LOG:  execute <unnamed>: SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL READ COMMITTED
  LOG:  execute <unnamed>: SHOW TRANSACTION ISOLATION LEVEL
  LOG:  execute <unnamed>: SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ
  ```
- see correct handling of concurrent conflict retries
  ```log
  LOG:  statement: COMMIT;
  ERROR:  could not serialize access due to concurrent update
  STATEMENT:  UPDATE lww SET v = $1 WHERE id = $2 RETURNING *
  LOG:  statement: ROLLBACK;
  ```

----

### Exercise Backend Connector With Process Pause/Kill

```clj
(c/su
   (cu/grepkill! app-ps-name)
   ...
   (cu/grepkill! :stop app-ps-name)
   ...
   (cu/grepkill! :cont app-ps-name))
```

Jepsen log:
```log
:nemesis	:info	:kill	:minority
...
:nemesis	:info	:kill	{"n1" :killed, "n2" :killed}
...
:nemesis	:info	:start	:all
...
:nemesis	:info	:start	{"n1" :started, "n2" :started, "n3" :already-running, "n4" :already-running, "n5" :already-running}
```

Observations:
- the usual, can end up in a divergent state
  - pause more likely than kill to diverge
- new Exception in client when paused
  - org.apache.http.NoHttpResponseException

----

### Exercise Backend Connector By Partitioning

```clj
(c/su
   (c/exec :iptables
           :-A :INPUT
           :-s :powersync
           :-j :DROP
           :-w)
   (c/exec :iptables
           :-A :INPUT
           :-s :pg-db
           :-j :DROP
           :-w))
```

Jepsen log:
```log
:nemesis	:info	:partition-sync	:majority
...
:nemesis	:info	:partition-sync	{"n1" :partitioned, "n3" :partitioned, "n4" :partitioned}
...
:nemesis	:info	:heal-sync	nil
...
:nemesis	:info	:heal-sync	{"n1" :healed, "n2" :healed, "n3" :healed, "n4" :healed, "n5" :healed}
```

Observations:
- exercises start-up under partition
- client always reconnects when partition heals
- more likely to end up in a divergent state

----

### Exercise Backend Connector By Disconnecting/Connecting

```dart
await db.connect(connector: connector);
await db.disconnect();
```

Jepsen log:
```log
2024-07-18 20:03:19,792 :nemesis	:info	:disconnect	:majority
2024-07-18 20:03:19,796 :nemesis	:info	:disconnect	{"n1" :disconnected, "n3" :disconnected, "n5" :disconnected}
...
2024-07-18 20:03:24,403 :nemesis	:info	:connect	nil
2024-07-18 20:03:24,412 :nemesis	:info	:connect	{"n1" :connected, "n2" :connected, "n3" :connected, "n4" :connected, "n5" :connected}
```

PowerSync Endpoint log:
```log
[powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false ...>
GET     [200] /powersync/connect
[powersync_endpoint] FINEST: statusStream: SyncStatus<connected: false connecting: false ...>
[powersync_endpoint] FINEST: statusStream: SyncStatus<connected: true connecting: false ...>
```

Observations:
- disconnecting/connecting is reliable
  - client seems more resilient, likely to strongly converge, than normal operations
  - only error that's reproducible is PostgreSQL could not serialize access due to concurrent update, max retries exceeded
- doing a connect on an already connected connection seems to trigger a disconnect then a connect

TODO / Questions:
- are `connect/disconnect` idempotent?
  - check if connect causes an initial disconnect?

----

### Initial Atomic Transaction Orientated Backend Connector

Example of a non-atomic transaction replication from a PowerSync write to a PostgreSQL read:
- PowerSync, top transaction, writes '47' to random keys
- PostgreSQL, bottom transaction, reads some but not all of the PowerSync writes in its transaction

Note that all writes are synced, Strong Convergence, but not on transaction boundaries. 

![G-single-item](./G-single-item.svg)

#### CrudTransactionConnector (PostgreSQL transaction orientated)

New `CrudTransactionConnector`:
- `uploadData` tightly coupled to a PostgreSQL transaction
- eager
  - processes all available transactions
  - wants local db to be available for sync updates
- PostgreSQL transactions are executed with an isolation level of repeatable-read
  - so app retries on concurrent access Exceptions

Can clearly see the effects of different connectors and atomic transactions:

![atomic-matrix GitHub action results](atomic-matix.png)

#### Implementation

Specify backend connector at runtime:
- cli: `--backend-connector CLASSNAME`
- .env: `BACKEND_CONNECTOR=CrudTransactionConnector`

Expect no Exceptions, and mean it:
```dart
// log PowerSync status changes
// monitor for upload error messages, there should be none
db.statusStream.listen((syncStatus) {
  if (syncStatus.uploadError != null) {
    log.severe(
        'Upload error detected in statusStream: ${syncStatus.uploadError}');
    exit(127);
  }
```

New workloads that isolate, emphasize PowerSync -> PostgreSQL and PostgreSQL -> PowerSync replication.
Simple way to show atomic/non-atomic replication with different backend connectors:

- `ps-wo-pg-ro` PowerSync write only, PostgreSQL read only 
- `ps-ro-pg-wo` PowerSync read only, PostgreSQL write only

Sample test commands:
```bash
lein run test --workload ps-wo-pg-ro --rate 20 --time-limit 60 --nodes n1,n2 --postgres-nodes n1 --backend-connector CrudBatchConnector
lein run test --workload ps-ro-pg-wo --rate 20 --time-limit 60 --nodes n1,n2 --postgres-nodes n1 --backend-connector CrudTransactionConnector
```

[GitHub action](https://github.com/nurturenature/jepsen-powersync/actions/workflows/atomic-matrix.yml).

----

### PowerSync, w/sync, Single User

`CrudBatchConnector`
- `fetchCredentials`
  - generate permissive JWT
- `uploadData`
  - `CrudBatch` oriented
  - one `CrudBatch` per call, not eager
  - one `CrudEntry` at a time
  - reuses single Postgres `Connection`
  - consistency quite casual, not at all causal, will allow:
    - non-Atomic transactions
    - Intermediate Reads
    - Monotonic Read cycling
- `Exception` handling:
  - recoverable
    - `throw` to signal PowerSync to retry
  - unrecoverable
    - indicates architectural/implementation flaws
    - not safe to proceed
    - `exit` to force app restart and resync
  
The `CrudBatchConnector` was design to be the minimum needed to go end-to-end.

Test results:
- PowerSync writing, PostgreSQL reading:
  - total availability
  - non-atomic transactions
  - Strong Convergence

- PowerSync reading, PostgreSQL writing:
  - total availability
  - Repeatable Read
  - Strong Convergence

Notes:
- TODO: check on performance of replication with direct writes to PostgreSQL
  - tests can cause long periods of replication
  - but always strongly converges
  
Test command:
```shell
lein run test --workload ps-ro-pg-wo --rate 10 --time-limit 60 --nodes n1,n2 --postgres-nodes n1
lein run test --workload ps-wo-pg-ro --rate 10 --time-limit 60 --nodes n1,n2 --postgres-nodes n1
```

----

### PowerSync, localOnly: true, Single User

Demonstrates
- PowerSync's `PowerSyncDatabase` driver, `libpowersync.so` native ffi lib
- initial `NoOpConnector` for local only 
  - permissive auth JWT/JWS for development
  - no `uploadDate()` as `localOnly: true`
- Docker
  - full PowerSync service
  - config, env
- longer test runs
  - 10k's of transactions

Test results:
- total availability
- strict serializability

```clj
{:stats {:count 35802,
         :ok-count 35802,
         :fail-count 0,
         :info-count 0},
 :workload {:list-append {:valid? true},
            :logs-ps-client {:valid? true, :count 0, :matches ()}},
 :valid? true}
 ```
Action and workload were a stepping stone and have been retired.

~~GitHub [Action](https://github.com/nurturenature/jepsen-powersync/actions/workflows/powersync-local.yml).~~

~~Test command:~~
```shell
lein run test --workload powersync-local --rate 150 --time-limit 1000 --nodes n1
```

----

### Initial Endpoint Test

Implementation
- Dart CLI app
- PowerSync's `sqlite_async` driver
- native `libsqlite3-dev.so` implementation
- exposes an http post API for Jepsen to submit transactions

Demonstrates
- basic automated building/installing, starting/stopping, of Dart apps
- endpoint
  - correct handling of Jepsen transaction maps
  - roundtrip type handling from Jepsen through endpoint to db and back
  - correct use of driver
- basic end-to-end functionality
- Docker, GitHub Action integration

Test results:
- total availability
- strict serializability

```clj
{:stats {:valid? true,
         :count 11795,
         :ok-count 11795,
         :fail-count 0,
         :info-count 0},
 :workload {:list-append {:valid? true}},
 :valid? true}
```

![sqlite3-local latency](./sqlite3-local-latency-raw.png)

Action and workload were a stepping stone and have been retired.

~~GitHub [Action](https://github.com/nurturenature/jepsen-powersync/actions/workflows/sqlite3-local.yml).~~

~~Test command:~~
```shell
lein run test --workload sqlite3-local --nodes n1
```
