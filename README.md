## jepsen-powersync

Testing [PowerSync](https://github.com/powersync-ja) with [Jepsen](https://github.com/powersync-ja) for [Causal Consistency](https://jepsen.io/consistency/models/causal), [Atomic transactions](https://jepsen.io/consistency/models/monotonic-atomic-view), and Strong Convergence.

PowerSync is a full featured active/active sync service for PostgreSQL and local SQLite3 clients.
It offers a rich API for developers to configure and define the sync behavior.

Our primary goal is to test the sync algorithm, its core implementation, and develop best practices for
- Causal Consistency
  - read your writes
  - monotonic reads and writes
  - writes follow reads
  - happens before relationships
- Atomic transactions
- Strong Convergence
 
Operating under
  - normal environmental conditions
  - environmental failures
  - diverse user behavior
  - random property based conditions and behavior
   
----

### Safety First

The initial implementations of the PowerSync client and backend connector take a safety first bias:

- stay as close as possible to direct SQLite3/PostgreSQL transactions
- replicate at this transaction level
- favors consistency and full client syncing over immediate performance

clients do straight ahead SQL transactions: 
```dart
await db.writeTransaction((tx) async {
  // SQLTransactions.readAll
  final select = await tx.getAll('SELECT k,v FROM mww ORDER BY k;');
  
  // SQLTransactions.writeSome
  final update = await tx.execute(
    "UPDATE mww SET v = ${kv.value} WHERE k = ${kv.key} RETURNING *;",
  );
});
```

backend replication is transaction based:
```dart
CrudTransaction? crudTransaction = await db.getNextCrudTransaction();

await pg.runTx(
  // max write wins, so GREATEST() value of v
  final patchV = crudEntry.opData!['v'] as int;
  final patch = await tx.execute(
    'UPDATE mww SET v = GREATEST($patchV, mww.v) WHERE id = \'${crudEntry.id}\' RETURNING *',
  );
);
```

----

### Progressive Test Enhancement

✔️ Single user, generic SQLite3 db, no PowerSync
- tests the tests
- demonstrates test fidelity, i.e. accurately represent the database
- 🗸 as expected, tests show totally availability with strict serializability 

✔️ Multi user, generic SQLite3 shared db, no PowerSync
- tests the tests
- demonstrates test fidelity, i.e. accurately represent the database
- 🗸 as expected, tests show totally availability with strict serializability 

✔️ Single user, PowerSync db, local only
- expectation is total availability and strict serializability
- SQLite3 is tight and using PowerSync APIs should reflect that
- 🗸 as expected, tests show totally availability with strict serializability 

✔️ Single user, PowerSync db, with replication
- expectation is total availability and strict serializability
- SQLite3 is tight and using PowerSync APIs should reflect that
- 🗸 as expected, tests show total availability with strict serializability 

✔️ Multi user, PowerSync db, with replication, using `getCrudBatch()` backend connector
- expectation is
  - read committed vs Causal
  - non-atomic transactions with intermediate reads
  - strong convergence
- 🗸 as expected, tests show read committed, non-atomic with intermediate reads transactions, and all replicated databases strongly converge

✔️ Multi user, PowerSync db, with replication, using newly developed Causal `getNextCrudTransaction()` backend connector 
- expectation is
  - Atomic transactions
  - Causal Consistency
  - Strong Convergence
- 🗸 as expected, tests show Atomic transactions with Causal Consistency, and all replicated databases strongly converge

✔️ Multi user, Active/Active PostgreSQL/SQLite3, with replication, using newly developed Causal `getNextCrudTransaction()` backend connector
- mix of clients, some PostgreSQL, some PowerSync
- expectation is
  - Atomic transactions
  - Causal Consistency
  - Strong Convergence
- 🗸 as expected, tests show Atomic transactions with Causal Consistency, and all replicated databases strongly converge

----

### Clients

The client will be a simple Dart CLI PowerSync implementation.

Clients are expected to have total sticky availability
- throughout the session, each client uses the
  - same API
  - same connection
- clients are expected to be totally available, liveness, unless explicitly stopped, killed or paused

Observe and interact with the database
- `PowerSyncDatabase` driver
- single `db.writeTransaction()` with multiple SQL statements
  - `tx.getAll('SELECT')`
  - `tx.execute('UPDATE')`
- PostgreSQL driver
  - most used Dart pub.dev driver
  - single `pg.runTx()` with multiple SQL statements
      - `tx.execute('SELECT')`
      - `tx.execute('UPDATE')`

The client will expose an endpoint for SQL transactions and `PowerSyncDatabase` API calls
- HTTP for Jepsen
- `Isolate` `ReceivePort` for Dart Fuzzer

----

### Faults

LoFi and distributed systems live in a rough and tumble environment.

Successful applications, applications that receive a meaningful amount or duration of use, will be exposed to faults. Reality is like that. 

Faults are applied
- to random clients
- at random intervals
- for random durations

Even during faults, we still expect
- total sticky availability (unless the client has been explicitly stopped/paused/killed)
- Atomic transactions
- Causal Consistency
- Strong Convergence

----

#### Disconnect / Connect

Use the `PowerSyncDatabase` API to repeatedly and randomly disconnect and connect clients to the sync service.

```dart
await db.disconnect();
...
await db.connect(connector: connector);
```

##### Orderly

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly disconnected
  - wait a random interval
  - connect disconnected clients
- at the end of the test connect any disconnected clients

Example of 3 clients being disconnected for ~1.6s: 
```log
2025-04-26 03:37:10,938{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-orderly	{"n1" :disconnected, "n4" :disconnected, "n6" :disconnected}
...
2025-04-26 03:37:12,517{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:connect-orderly	{"n1" :connected, "n4" :connected, "n6" :connected}
```

##### Random

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly disconnected
  - wait a random interval
  - 1 to all clients are randomly connected
- at the end of the test connect any disconnected clients

Example of 3 clients being disconnected, waiting ~2.5s, then connecting 2 clients
```log
2025-04-26 03:37:14,623{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-random	{"n1" :disconnected, "n2" :disconnected, "n3" :disconnected}
2025-04-26 03:37:17,193{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:connect-random	{"n1" :connected, "n4" :connected}
```

##### Upload Que Count

- repeatedly
  - wait a random interval
  - query the upload que count

Example of observing differing queue counts for disconnected/connected clients: 
```log
2025-04-26 03:38:02,041{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:upload-queue-count	{"n2" 0, "n3" 0, "n4" 0, "n5" 0, "n6" 0}
...
2025-04-26 03:38:02,362{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-orderly	{"n5" :disconnected, "n6" :disconnected}
...
2025-04-26 03:38:07,807{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:upload-queue-count	{"n2" 0, "n3" 0, "n4" 0, "n5" 28, "n6" 28}
```

##### Impact on Consistency/Correctness

The update to powersync: 1.12.3, PR #267, shows significant improvements when fuzzing disconnect/connect.

See [issue #253 comment](https://github.com/powersync-ja/powersync.dart/issues/253#issuecomment-2835901911).

The new release eliminates all occurrences of
- multiple calls to BackendConnector.uploadData() for the same transaction id
- SyncStatus.lastSyncedAt goes backwards in time
- reads that appear to go back in time, read of previous versions
- select * reads that return [], empty database

And although less frequent, and requiring more
- demanding transaction rates
- total run times
- occurrences of disconnect/connecting

than before, it is still possible to fuzz into a state where
- `UploadQueueStats.count` appears to be stuck for a single client
- which leads to incomplete replication for that client and divergent final reads

The bug is hard enough to reproduce due to its lower frequency and longer run times that GitHub actions are a more appropriate test bed
- using Dart Isolates: https://github.com/nurturenature/jepsen-powersync/actions/workflows/fuzz-disconnect.yml
- using Jepsen: https://github.com/nurturenature/jepsen-powersync/actions/workflows/jepsen-disconnect.yml

As the error behavior usually (always?) presents as a single stuck transaction, is it theorized that
- replication occasionally gets stuck
- sometimes the test ends during this stuck phase
- sometimes the test is ongoing and replication is restarted by further transactions

----

#### Stop / Start

Use the `PowerSyncDatabase` API to repeatedly and randomly stop and start clients using the PowerSync sync service.

```dart
await db.close();
Isolate.kill();
...
// note: create db reusing existing SQLite3 files
await Isolate.spawn(...);
db = PowerSyncDatabase(...);
await db.initialize()/connect()/waitForFirstSync();
```

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly closed then stopped
  - wait a random interval
  - clients that were closed/stopped are restarted reusing existing SQLite3 files
- at the end of the test restart any clients that are currently closed/stopped reusing existing SQLite3 files

##### Impact on Consistency/Correctness

In a small, ~0.1% of the tests, the `UploadQueueStats.count` is stuck at the end of the test preventing Strong Convergence.

Similar to disconnect/connect, see above.

See [issue #253 comment](https://github.com/powersync-ja/powersync.dart/issues/253#issuecomment-2835901911) for similar behavior but with stop/start.

----

#### Network Partition

Use `iptables` to partition client hosts from the PowerSync sync service and PostgreSQL hosts.

```dart
// inbound
await Process.run('/usr/sbin/iptables', [ '-A', 'INPUT', '-s', powersyncServiceHost | postgreSQLHost, '-j', 'DROP', '-w' ]);

// outbound
await Process.run('/usr/sbin/iptables', [ '-A', 'OUTPUT', '-d', powersyncServiceHost | postgreSQLHost, '-j', 'DROP', '-w' ]);

// bidirectional
await Process.run('/usr/sbin/iptables', [ '-A', 'INPUT', '-s', powersyncServiceHost | postgreSQLHost, '-j', 'DROP', '-w' ]);
await Process.run('/usr/sbin/iptables', [ '-A', 'OUTPUT', '-d', powersyncServiceHost | postgreSQLHost, '-j', 'DROP', '-w' ]);

// heal network
await Process.run('/usr/sbin/iptables', ['-F', '-w']);
await Process.run('/usr/sbin/iptables', ['-X', '-w']);
```

- repeatedly
  - wait a random interval
  - all clients for `powersync_fuzz`, 1 to all clients for Jepsen, are randomly partitioned from the PowerSync sync service and PostgreSQL hosts
  - wait a random interval
  - all client networks are healed
- at the end of the test insure all client networks are healed

Example of partitioning nemesis from `powersync_fuzz.log`
```log
$ grep nemesis powersync_fuzz.log 
[2025-05-08 02:58:38.540582] [main] [INFO] nemesis: partition: start listening to stream of partition messages
[2025-05-08 02:58:44.308471] [main] [INFO] nemesis: partition: starting: bidirectional
[2025-05-08 02:58:44.367180] [main] [INFO] nemesis: partition: current: bidirectional hosts: {powersync, pg-db}
[2025-05-08 02:58:46.957552] [main] [INFO] nemesis: partition: starting: none
[2025-05-08 02:58:47.031792] [main] [INFO] nemesis: partition: current: none hosts: {}
[2025-05-08 02:58:49.190407] [main] [INFO] nemesis: partition: starting: outbound
[2025-05-08 02:58:49.219263] [main] [INFO] nemesis: partition: current: outbound hosts: {powersync, pg-db}
[2025-05-08 02:58:55.021681] [main] [INFO] nemesis: partition: starting: none
[2025-05-08 02:58:55.128247] [main] [INFO] nemesis: partition: current: none hosts: {}
...
[2025-05-08 03:00:04.102570] [main] [INFO] nemesis: partition: starting: inbound
[2025-05-08 03:00:04.120517] [main] [INFO] nemesis: partition: current: inbound hosts: {powersync, pg-db}
...
[2025-05-08 03:00:18.591748] [main] [INFO] nemesis: partition: stop listening to stream of partition messages
[2025-05-08 03:00:20.257646] [main] [INFO] nemesis: partition: starting: none
[2025-05-08 03:00:20.282057] [main] [INFO] nemesis: partition: current: none hosts: {}
```

##### Impact on Consistency/Correctness

###### Client `<SyncStatus error: null>`

Unexpectedly, there's often no errors in the client logs
```bash
$ grep 'SyncStatus' powersync_fuzz.log | grep 'error: ' | grep -v 'error: null' 
$
```
even when there's consistency errors.

###### Uploading Stops

Clients can end the test with a large number of transactions stuck in the `UploadQueueStats.count`
```log
[2025-05-03 04:33:14.152256] [ps-8] [SEVERE] UploadQueueStats.count appears to be stuck at 120 after waiting for 11s
[2025-05-03 04:33:14.152278] [ps-8] [SEVERE] 	db.closed: false
[2025-05-03 04:33:14.152288] [ps-8] [SEVERE] 	db.connected: true
[2025-05-03 04:33:14.152299] [ps-8] [SEVERE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: 2025-05-03 04:32:12.685048, hasSynced: true, error: null>
[2025-05-03 04:33:14.152527] [ps-8] [SEVERE] 	db.getUploadQueueStats(): UploadQueueStats<count: 120 size: 2.34375kB>
```
preventing Strong Convergence in ~20% of the tests.

Clients appear to enter and get stuck in a `SyncStatus<downloading: true>` state after the partition is healed and the `BackendConnector.UploadData()` is never called.

###### Replication Stops

Clients can end the test with divergent final reads, i.e. not Strongly Consistent, ~10% of the time.

```log
# observe client 5 write, then read, then upload {0: 1965}  
[2025-05-03 04:33:02.952207] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, f: txn, id: 197, type: ok, value: [{f: readAll, v: {0: 1651, ...}}, {f: writeSome, v: {0: 1965, ...}}]}
[2025-05-03 04:33:03.902696] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, f: txn, id: 198, type: ok, value: [{f: readAll, v: {0: 1965, ...}}, {f: writeSome, v: {...}}]}
[2025-05-03 04:33:03.940824] [ps-5] [FINER] uploadData: call: 68 txn: 198 patch: {0: 1965} 

# observe write in PostgreSQL
2025-05-03 04:33:03.937 UTC [144] LOG:  statement: BEGIN ISOLATION LEVEL REPEATABLE READ;
...
2025-05-03 04:33:03.940 UTC [144] LOG:  execute s/811/p/811: UPDATE mww SET v = GREATEST(1965, mww.v) WHERE id = '0' RETURNING *
...
2025-05-03 04:33:03.941 UTC [144] LOG:  statement: COMMIT;

# but write is missing in most client final reads
[2025-05-03 04:33:45.722564] [main] [SEVERE] Divergent final reads!:
[2025-05-03 04:33:45.722652] [main] [SEVERE] pg: {0: 1965, ...}
[2025-05-03 04:33:45.722717] [main] [SEVERE] ps-1 {0: 1734, ...}
[2025-05-03 04:33:45.723038] [main] [SEVERE] ps-2 {0: 1386, ...}
[2025-05-03 04:33:45.723083] [main] [SEVERE] ps-3 {0: 1760, ...}
[2025-05-03 04:33:45.723125] [main] [SEVERE] ps-4 {0: 1932, ...}
[2025-05-03 04:33:45.723201] [main] [SEVERE] ps-8 {0: 1566, ...}
[2025-05-03 04:33:45.723260] [main] [SEVERE] ps-9 {0: 1313, ...}
[2025-05-03 04:33:45.722793] [main] [SEVERE] ps-10 {0: 1769, ...}
```
At some point, individual clients appear to go into, and remain in a `SyncStatus.downloading: true` state but there is no replication from the PowerSync sync service
```log
[2025-05-03 04:33:05.960464] [ps-9] [FINEST] SyncStatus<connected: true connecting: false downloading: true uploading: false lastSyncedAt: 2025-05-03 04:31:57.783573, hasSynced: true, error: null>
...
[2025-05-03 04:33:15.299509] [ps-9] [FINE] database api: request: {clientNum: 9, f: api, id: 2, type: invoke, value: {f: downloadingWait, v: {}}}
[2025-05-03 04:33:15.299528] [ps-9] [FINE] database api: downloadingWait: waiting on SyncStatus.downloading: true...
...
[2025-05-03 04:33:44.328266] [ps-9] [FINE] database api: downloadingWait: waiting on SyncStatus.downloading: true...
[2025-05-03 04:33:45.329282] [ps-9] [WARNING] database api: downloadingWait: waited for SyncStatus.downloading: false 31 times every 1000ms
```

----

#### Client Pause

In `powersync_fuzz`, use
```dart
Capability resumeCapability = Isolate.pause();
...
// ok to resume an unpaused client
Isolate.resume(resumeCapability);
```

In Jepsen, use
```bash
$ grepkill stop powersync_http
...
# ok to cont an unpaused client
$ grepkill cont powersync_http
```

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly paused
  - wait a random interval
  - resume all clients
- at the end of the test resume all clients

##### Impact on Consistency/Correctness

----

#### Client Kill

- `kill -9` client process(es)

----

### Not Testing

- auth - using a permissive JWT

- sync filtering - using SELECT *

- Byzantine - natural faults, not malicious behavior

----

### Conflict Resolution

Maximum write value for the key wins
- SQLite3
  - `MAX()`
- PostgreSQL
  - `GREATEST()`
  - `repeatable read` isolation

The conflict/merge algorithm isn't important to the test.
It just needs to be
- consistently applied
- consistently replicated 

----

### Development

Public GitHub repository
- docs
- samples/demos
- actions that run tests in a CI/CD fashion

----

Development [Logbook](./doc/logbook.md).

GitHub [Actions](https://github.com/nurturenature/jepsen-powersync/actions).

[Docker](./docker/README.md) environment to run tests.

Non-Jepsen, Dart CLI fuzzer [instructions](./powersync_endpoint/README.md).
