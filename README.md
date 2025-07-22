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
    'UPDATE mww SET v = ${kv.value} WHERE k = ${kv.key} RETURNING *;',
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

Tests can use a mix of clients
- active/active, replicate central PostgreSQL and local client activities
  - some clients read/write PostgreSQL database
  - some clients read/write local SQLite3 databases
- replicate central PostgreSQL activity to local clients
  - some clients read/write PostgreSQL database
  - some clients read only local SQLite3 databases
- replicate local clients to local clients
  - some clients read only PostgreSQL database (to check for consistency)
  - some clients read/write local SQLite3 databases

----

### No Fault Environments

PowerSync tests 100% successfully in no fault environments using a test matrix of
- 5-10 clients
- 10-50 transactions/second
- active/active, simultaneous PostgreSQL and/or local SQLite3 client transactions
- local SQLite3 client transactions
- complex transactions that read 100 keys and write 4 keys in a single transaction

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

#### Client Application Disconnect / Connect

In both `powersync_fuzz` and `Jepsen` use `PowerSyncDatabase.disconnect()/connect()`.

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

`Jepsen` example of 3 clients being disconnected for ~1.6s and then the same clients being reconnected: 
```log
2025-04-26 03:37:10,938{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-orderly	{"n1" :disconnected, "n4" :disconnected, "n6" :disconnected}
...

# note that all disconnected and only disconnected clients are reconnected
2025-04-26 03:37:12,517{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:connect-orderly	{"n1" :connected, "n4" :connected, "n6" :connected}
```

##### Random

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly disconnected
  - wait a random interval
  - 1 to all clients are randomly connected
- at the end of the test connect any disconnected clients

`Jepsen` example of 3 clients being disconnected, waiting ~2.5s, then only 1 of the disconnected clients and 1 other random client being reconnected
```log
2025-04-26 03:37:14,623{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-random	{"n1" :disconnected, "n2" :disconnected, "n3" :disconnected}
...

# note that only 1 disconnected and a random client are reconnected
2025-04-26 03:37:17,193{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:connect-random	{"n1" :connected, "n4" :connected}
```

##### Upload Que Count

- repeatedly
  - wait a random interval
  - query the upload que count

`Jepsen` example of observing differing queue counts for disconnected/connected clients: 
```log
2025-04-26 03:38:02,041{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:upload-queue-count	{"n2" 0, "n3" 0, "n4" 0, "n5" 0, "n6" 0}
...

2025-04-26 03:38:02,362{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:disconnect-orderly	{"n5" :disconnected, "n6" :disconnected}
...

2025-04-26 03:38:07,807{GMT}	INFO	[jepsen worker nemesis] jepsen.util: :nemesis	:info	:upload-queue-count	{"n2" 0, "n3" 0, "n4" 0, "n5" 28, "n6" 28}
```

##### Impact on Consistency/Correctness

In a small, fraction of a percent, of tests it is possible to fuzz into a state where
- `UploadQueueStats.count` appears to be stuck
  - for a single client
  - for a single transaction

which leads to incomplete replication for that client and divergent final reads.

As the error behavior always presents as a single stuck transaction, is it theorized that
- replication occasionally gets stuck, is not triggered
- sometimes the test ends during this stuck phase
- sometimes the test is ongoing and replication is restarted by further transactions

In no cases have the tests been able to drop any data or order the transactions in a non Causally Consistent fashion.

The bug is hard enough to reproduce due to its lower frequency and longer run times that GitHub actions are a more appropriate test bed than the local fuzzing environment
- using Dart Isolates: https://github.com/nurturenature/jepsen-powersync/actions/workflows/fuzz-disconnect.yml
- using Jepsen: https://github.com/nurturenature/jepsen-powersync/actions/workflows/jepsen-disconnect.yml

to reproduce.

##### History

The update to PowerSync: 1.12.3, PR #267, shows significant improvements when fuzzing disconnect/connect.

See [issue #253 comment](https://github.com/powersync-ja/powersync.dart/issues/253#issuecomment-2835901911).

The new release eliminates all occurrences of
- multiple calls to BackendConnector.uploadData() for the same transaction id
- SyncStatus.lastSyncedAt goes backwards in time
- reads that appear to go back in time, read of previous versions
- select * reads that return [], empty database

And the remaining bug is less frequent requiring more
- demanding transaction rates
- total run times
- occurrences of disconnecting/connecting

The update to PowerSync: 1.14.1, PR #294, brings the Rust implementation to parity with the Dart implementation.

See [issue #253 comment](https://github.com/powersync-ja/powersync.dart/issues/253#issuecomment-3076511953).

----

#### Client Application Stop / Start

In `powersync_fuzz` use `PowerSyncDatabase` api and Dart's `Isolate` api
```dart
await db.close();
Isolate.kill();
...
// note: create db reusing existing SQLite3 files
await Isolate.spawn(...);
db = PowerSyncDatabase(...);
await db.initialize()/connect()/waitForFirstSync();
```

In `Jepsen` use `PowerSyncDatabase` api and Jepsen's `control/util/grepkill!` and `start-daemon!` utilities
```clj
; use Dart API to close
; db.close()
(control/util/grepkill! "powersync_http")
...
; start powersync_http CLI reusing existing SQLite3 files
(control/util/start-daemon! "powersync_http")
```

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly closed then killed
  - wait a random interval
  - clients that were closed/killed are restarted reusing existing SQLite3 files
- at the end of the test restart any clients that are currently closed/killed reusing existing SQLite3 files

Sample `Jepsen` log
```clj
:nemesis	:info	:stop-nodes	nil
:nemesis	:info	:stop-nodes	{"n10" :stopped, "n3" :stopped, "n7" :stopped}
...
:nemesis	:info	:start-nodes	nil
:nemesis	:info	:start-nodes	{"n1" :already-running, "n10" :started, "n2" :already-running, "n3" :started, "n4" :already-running, "n5" :already-running, "n6" :already-running, "n7" :started, "n8" :already-running, "n9" :already-running}
```

##### Impact on Consistency/Correctness

Stop/start behaves the same as disconnect/connect but with a significantly smaller frequency of the "stuck queue" bug.

----

#### Network Partition

For both `powersync_fuzz` and `Jepsen` use `iptables` to partition client hosts from the PowerSync sync service.

`powersync_fuzz` Dart partition implementation
```dart
// inbound
await Process.run('/usr/sbin/iptables', [ '-A', 'INPUT', '-s', powersyncServiceHost, '-j', 'DROP', '-w' ]);

// outbound
await Process.run('/usr/sbin/iptables', [ '-A', 'OUTPUT', '-d', powersyncServiceHost, '-j', 'DROP', '-w' ]);

// bidirectional
await Process.run('/usr/sbin/iptables', [ '-A', 'INPUT', '-s', powersyncServiceHost, '-j', 'DROP', '-w' ]);
await Process.run('/usr/sbin/iptables', [ '-A', 'OUTPUT', '-d', powersyncServiceHost, '-j', 'DROP', '-w' ]);

// heal network
await Process.run('/usr/sbin/iptables', ['-F', '-w']);
await Process.run('/usr/sbin/iptables', ['-X', '-w']);
```
- repeatedly
  - 0 to all client hosts are randomly partitioned from the PowerSync sync service host
    - the client network failure is randomly selected to be none, inbound, outbound, or all traffic 
  - wait a random interval, 0-10s
  - heal network partition
  - wait a random interval, 0-10s

At the end of the test:
- insure network is healed for all clients
- quiesce for 3s, i.e. no further transactions
- wait for `db.uploadQueueStats.count: 0` for all clients
- wait for `db.SyncStatus.downloading: false` for all clients
- do a final read on all clients and check for Strong Convergence
  
Without partitioning, all test runs are successful.

There's no obvious differences between the Dart and Rust sync implementations.

During successful runs you can see:
```log
# partition clients
[2025-07-20 02:18:23.222360] [main] [INFO] nemesis: partition: starting: outbound
[2025-07-20 02:18:23.236820] [main] [INFO] nemesis: partition: current: outbound, hosts: {powersync}

# clients continue with local transactions
[2025-07-20 02:18:23.254476] [ps-1] [FINE] SQL txn: response: {clientNum: 1, clientType: ps, f: txn, id: 15, type: ok, value: [{f: readAll, v: {0: -1, 1: 42, 2: 21, ...}}, {f: writeSome, v: {16: 62, 53: 62, 50: 62, 33: 62}}]}

# partition is healed
[2025-07-20 02:18:31.337347] [main] [INFO] nemesis: partition: starting: none
[2025-07-20 02:18:31.363529] [main] [INFO] nemesis: partition: current: none, hosts: {}

# clients catchup with downloads from sync service
[2025-07-20 02:18:36.427705] [ps-1] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 4 / 8) uploading: false lastSyncedAt: 2025-07-20 02:18:23.000, hasSynced: true, error: null>
...
[2025-07-20 02:18:36.439118] [ps-1] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 20 / 20) uploading: true lastSyncedAt: 2025-07-20 02:18:23.000, hasSynced: true, error: null>

# clients upload to sync service
[2025-07-20 02:18:36.439257] [ps-1] [FINER] uploadData: call: 17 begin with UploadQueueStats.count: 108

# local transactions, downloading, uploading go on as normal
...

# at the end of the test
[2025-07-20 02:20:09.373311] [main] [INFO] wait for upload queue to be empty in clients
[2025-07-20 02:20:09.375017] [ps-1] [FINE] database api: response: {clientNum: 1, clientType: ps, f: api, id: 0, type: ok, value: {f: uploadQueueCount, v: {db.uploadQueueStats.count: 0}}}
...

[2025-07-20 02:20:09.379592] [main] [INFO] wait for downloading to be false in clients
[2025-07-20 02:20:09.379765] [ps-1] [FINE] database api: response: {clientNum: 1, clientType: ps, f: api, id: 2, type: ok, value: {f: downloadingWait, v: {db.SyncStatus.downloading:: false}}}
...

[2025-07-20 02:20:09.380379] [main] [INFO] check for strong convergence in final reads
[2025-07-20 02:20:09.505932] [ps-1] [FINE] database api: response: {clientNum: 1, clientType: ps, f: api, id: 3, type: ok, value: {f: selectAll, v: {0: 938, 1: 964, 2: 989, ...}}}
...

[2025-07-20 02:20:09.528708] [main] [INFO] Success!
[2025-07-20 02:20:09.528714] [main] [INFO] Final reads had Strong Convergence
[2025-07-20 02:20:09.528717] [main] [INFO] All transactions were Atomic and Causally Consistent

```

As expected, network errors exist in sync service logs:
```bash
$ grep -P 'error: (?!null)' powersync_fuzz.log
$ grep -i 'err' powersync.log 
{"cause":{"code":"ECONNREFUSED","message":"request to http://localhost:8089/api/auth/keys failed, reason: connect ECONNREFUSED 127.0.0.1:8089","name":"FetchError"},...}
```

##### Impact on Consistency/Correctness

Transient network partitions can disrupt replication.

Most commonly, the client stops uploading, just indefinitely queuing local writes.

In other cases, less frequently, the tests complete without any indication of errors, local writes are uploaded to PostgreSQL, but only replicated to 0 or a subset of clients.

###### Wedged/Stalled Client Uploads

At the end of the test with:
- healed partitions
- no transactions

uploading remains `true`, but the upload queue never clears:
- note lack of updated `SyncStatus`, or other messages
- `db.UploadQueueStats.count` is wedged/stuck, never changes
- we wait 11 seconds with no upload activity before ending the test, but the wait can be indefinite. i.e. client never recovers
```log
[2025-07-15 13:27:10.486902] [ps-1] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 200 ...
[2025-07-15 13:27:10.486917] [ps-1] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: false (progress: null) uploading: true lastSyncedAt: 2025-07-15 13:26:32.000, hasSynced: true, error: null>
...
[2025-07-15 13:27:20.496789] [ps-1] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 200 ...
[2025-07-15 13:27:20.496848] [ps-1] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: false (progress: null) uploading: true lastSyncedAt: 2025-07-15 13:26:32.000, hasSynced: true, error: null>
[2025-07-15 13:27:21.497830] [ps-1] [SEVERE] UploadQueueStats.count appears to be stuck at 200 after waiting for 11s
[2025-07-15 13:27:21.497843] [ps-1] [SEVERE] 	db.closed: false
[2025-07-15 13:27:21.497901] [ps-1] [SEVERE] 	db.connected: true
[2025-07-15 13:27:21.497911] [ps-1] [SEVERE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: false (progress: null) uploading: true lastSyncedAt: 2025-07-15 13:26:32.000, hasSynced: true, error: null>
[2025-07-15 13:27:21.498085] [ps-1] [SEVERE] 	db.getUploadQueueStats(): UploadQueueStats<count: 200 size: 3.90625kB>
[2025-07-15 13:27:21.498140] [ps-1] [SEVERE] Error exit: reason: uploadQueueStatsCount, code: 12
```

Unexpectedly, there are no network errors in the logs:
```bash
$ grep -P 'error: (?!null)' powersync_fuzz.log
$ grep -i 'err' powersync.log
```

###### Divergent Final Reads

At the end of the test with:
- healed partitions
- no transactions
- `db.uploadQueueStats.count: 0` for all clients
- `db.SyncStatus.downloading: false` for all clients
- no errors

there can be divergent final reads:
```log
# client 5 writes {0: 992}
[2025-07-17 04:07:26.390143] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, f: txn, id: 183, type: ok, value: [{f: readAll, v: {0: 487,...}}, {f: writeSome, v: {0: 992, ...}}]}

# client 5 reads {0: 992}
[2025-07-17 04:07:26.589324] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, f: txn, id: 184, type: ok, value: [{f: readAll, v: {0: 992, ...}}, {f: writeSome, v: {...}}]}

# client 5 uploads {0: 992}
[2025-07-17 04:07:36.402584] [ps-5] [FINER] uploadData: call: 48 txn: 184 patch: {0: 992} 

# note: no other client ever observes {0: 992}

# insure network is healed
[2025-07-17 04:07:30.684918] [main] [INFO] nemesis: partition: current: none, hosts: {}

# quiet time, no more transactions
[2025-07-17 04:07:30.684950] [main] [INFO] quiesce for 3 seconds...

# wait for `db.uploadQueueStats.count: 0` for all clients
[2025-07-17 04:07:33.685707] [main] [INFO] wait for upload queue to be empty in clients
[2025-07-17 04:07:33.687003] [ps-1] [FINE] database api: response: {clientNum: 1, clientType: ps, f: api, id: 0, type: ok, value: {f: uploadQueueCount, v: {db.uploadQueueStats.count: 0}}}
...

# wait for `db.SyncStatus.downloading: false` for all clients
[2025-07-17 04:07:36.693082] [main] [INFO] wait for downloading to be false in clients
[2025-07-17 04:07:36.693400] [ps-1] [FINE] database api: response: {clientNum: 1, clientType: ps, f: api, id: 2, type: ok, value: {f: downloadingWait, v: {db.SyncStatus.downloading:: false}}}

# client 5 still reads {0: 992} for its final read
[2025-07-17 04:07:36.811193] [ps-5] [FINE] database api: response: {clientNum: 5, clientType: ps, f: api, id: 3, type: ok, value: {f: selectAll, v: {0: 992, ...}}}

# only client 5 and PostgreSQL read {0: 992} during final reads
# clients 1-4 all read a different value for key 0
[2025-07-17 04:07:36.811322] [main] [SEVERE] Divergent final reads!:
[2025-07-17 04:07:36.811342] [main] [SEVERE] PostgreSQL {k: v} for client diversions:
[2025-07-17 04:07:36.811409] [main] [SEVERE] pg: {0: 992, ...}
[2025-07-17 04:07:36.811441] [main] [SEVERE] ps-1 {k: v} that diverged from PostgreSQL
[2025-07-17 04:07:36.811556] [main] [SEVERE] ps-1 {0: 777, ...}
[2025-07-17 04:07:36.811575] [main] [SEVERE] ps-2 {k: v} that diverged from PostgreSQL
[2025-07-17 04:07:36.811619] [main] [SEVERE] ps-2 {0: 975, ...}
[2025-07-17 04:07:36.811625] [main] [SEVERE] ps-3 {k: v} that diverged from PostgreSQL
[2025-07-17 04:07:36.811651] [main] [SEVERE] ps-3 {0: 929, ...}
[2025-07-17 04:07:36.811656] [main] [SEVERE] ps-4 {k: v} that diverged from PostgreSQL
[2025-07-17 04:07:36.811683] [main] [SEVERE] ps-4 {0: 951, ...}
[2025-07-17 04:07:36.811722] [main] [SEVERE] :(
[2025-07-17 04:07:36.811736] [main] [SEVERE] Error exit: reason: strongConvergence, code: 1
```

Unexpectedly, there are no network errors in the logs:
```bash
$ grep -P 'error: (?!null)' powersync_fuzz.log
$ grep -i 'err' powersync.log
```

###### Error Rate

Fuzzing with a test matrix of:
- 5 | 10 clients
- 10 | 20 | 30 | 40 transactions/second
- 100 | 200 | 300 second run times

will generate errors in ~30-40% of the tests.

----

#### Client Application Process Pause / Resume

In `powersync_fuzz`, use Dart's `Isolate.pause()/resume()`
```dart
Capability resumeCapability = Isolate.pause();
...
// ok to resume an unpaused client
Isolate.resume(resumeCapability);
```

In `Jepsen`, use Jepsen's `control/util/grepkill!` utility
```clj
(control/util/grepkill! :stop "powersync_http")
...
; ok to cont an unpaused client
(control/util/grepkill! :cont "powersync_http")
```

- repeatedly
  - wait a random interval
  - 1 to all clients are randomly paused
  - wait a random interval
  - resume all clients
- at the end of the test resume all clients

##### Impact on Consistency/Correctness

PowerSync tests 100% successful when injecting client process pause/resumes.

----

#### Client Application Process Kill / Start

Client application process kills can happen when
- someone's phone running out of battery
- a user turning off their laptop without shutting down
- force quitting an app
- etc

Not available in `powersync_fuzz` as `Isolate.kill()`'s behavior appears to be heavy handed, have side effects that are not fully understood, so use Jepsen to test kill/start.

In Jepsen, use Jepsen's `control/util/grepkill!` and `start-daemon!` utilities
```clj
(control/util/grepkill! "powersync_http")
...
; start powersync_http CLI reusing existing SQLite3 files
(control/util/start-daemon! "powersync_http")
```

Test choreography:
- repeatedly
  - 1 to a majority of clients are randomly killed
  - wait a random interval, 0-10s
  - restart/reconnect clients that were killed reusing existing SQLite3 files
  - wait a random interval, 0-10s

At the end of the test:
- insure all clients are started/connected
- quiesce for 3s, i.e. no further transactions
- wait for `db.uploadQueueStats.count: 0` for all clients
- wait for `db.SyncStatus.downloading: false` for all clients
- do a final read on all clients and check for Strong Convergence

##### Impact on Consistency/Correctness

PowerSync is usually quite resilient with a full recovery after client is restarted and reconnects to the sync service:
- quickly/fully downloads to catch up with the other clients
- resumes uploading, including any pending pre-kill transactions
  - even for transactions that were in progress, only partially uploaded, when client was killed
- continues with normal operation as if nothing happened
  
Without killing, all test runs are successful.

With process kills, occasionally, ~0.5%, the test will end with:
- `db.currentStatus.downloading` staying indefinitely `true`
- `db.currentStatus.progress` counting to #/# but never `null`ing

and local transactions committed after the kill not being uploaded to the sync service.

There's no obvious differences between the Dart and Rust sync implementations.

There's a lot going on in the logs during a kill/restart/reconnect sequence, but here's a commented snippet from the end of a test that illustrates the issue:

```log
# last ~20s of test

# local writes of 4461 to several keys in a transaction which are uploaded

[2025-07-20 23:53:44.467176] [main] [FINE] SQL txn: response: {clientType: ps, f: txn, type: ok, value: [{f: readAll, k: null, v: {0: 4423, ...}}, {f: writeSome, k: null, v: {88: 4461, 0: 4461, 31: 4461, 93: 4461}}]}
2025-07-20T23:53:44.464781  0:00:00.002482 POST    [200] /sql-txn
[2025-07-20 23:53:44.468805] [main] [FINER] uploadData: call: 311 txn: 610 begin CrudTransaction<610, [CrudEntry<610/2437 PATCH mww/88 {v: 4461}>, CrudEntry<610/2438 PATCH mww/0 {v: 4461}>, CrudEntry<610/2439 PATCH mww/31 {v: 4461}>, CrudEntry<610/2440 PATCH mww/93 {v: 4461}>]>
...
[2025-07-20 23:53:44.474808] [main] [FINER] uploadData: call: 311 txn: 610 committed
[2025-07-20 23:53:44.475026] [main] [FINER] uploadData: call: 311 end with UploadQueueStats.count: 0

# upload queue is now empty

# several sequences of normal downloading
# downloads fully complete until progress is null

[2025-07-20 23:53:44.480877] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 0 / 4) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
...
[2025-07-20 23:53:44.555293] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 28 / 28) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:44.555937] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: false (progress: null) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
...

# local writes of 4472 to several keys in a transaction
# client will be killed before they can be successfully uploaded

[2025-07-20 23:53:44.674403] [main] [FINE] SQL txn: response: {clientType: ps, f: txn, type: ok, value: [{f: readAll, k: null, v: {0: 4461, ...}}, {f: writeSome, k: null, v: {12: 4472, 88: 4472, 87: 4472, 60: 4472}}]}

# start upload of transaction that wrote 4472
# client will be killed mid upload

[2025-07-20 23:53:44.683554] [main] [FINER] uploadData: call: 312 begin with UploadQueueStats.count: 4
[2025-07-20 23:53:44.683750] [main] [FINER] uploadData: call: 312 txn: 611 begin CrudTransaction<611, [CrudEntry<611/2441 PATCH mww/12 {v: 4472}>, CrudEntry<611/2442 PATCH mww/88 {v: 4472}>, CrudEntry<611/2443 PATCH mww/87 {v: 4472}>, CrudEntry<611/2444 PATCH mww/60 {v: 4472}>]>

# local writes of 4473 to several keys in a transaction
# client will be killed before the transaction is uploaded

[2025-07-20 23:53:44.690599] [main] [FINE] SQL txn: response: {clientType: ps, f: txn, type: ok, value: [{f: readAll, k: null, v: {0: 4461, ...}}, {f: writeSome, k: null, v: {17: 4473, 24: 4473, 64: 4473, 8: 4473}}]}

# still uploading transaction that wrote 4472
# client will be killed before upload is committed 

[2025-07-20 23:53:44.700366] [main] [FINER] uploadData: call: 312 txn: 611 patch: {12: 4472} 
[2025-07-20 23:53:44.701982] [main] [FINER] uploadData: call: 312 txn: 611 patch: {88: 4472} 
[2025-07-20 23:53:44.714241] [main] [FINER] uploadData: call: 312 txn: 611 patch: {87: 4472} 
[2025-07-20 23:53:44.719150] [main] [FINER] uploadData: call: 312 txn: 611 patch: {60: 4472} 

#
# CLIENT PROCESS KILLED
#

# client remains killed for ~7s, other clients continue with their local transactions

# client application is restarted

2025-07-20 23:53:51 Jepsen starting  /jepsen/jepsen-powersync/powersync_endpoint/powersync_http --endpoint powersync --clientImpl rust

# existing SQLite3 file is preserved

[2025-07-20 23:53:51.477284] [main] [INFO] db: init: preexisting SQLite3 file: /jepsen/jepsen-powersync/powersync_endpoint/http.sqlite3
[2025-07-20 23:53:51.477302] [main] [INFO] 	preexisting file preserved

# normal API calls for db creation, initialization, connect, etc.

# auth token is requested/created/etc

[2025-07-20 23:53:51.992961] [main] [FINER] auth: created token w/payload: {iss: https://github.com/nurturenature/jepsen-powersync, sub: userId, aud: [powersync-dev, powersync], iat: 1753055631.977, exp: 1753055931.977, parameters: {sync_filter: *}}

# upload data is called to upload the 2 transactions in the upload queue, i.e. not uploaded before the process kill
# note: BackendConnector is max write wins so greater values were written during the time client was killed

[2025-07-20 23:53:51.998536] [main] [FINER] uploadData: call: 1 begin with UploadQueueStats.count: 8
[2025-07-20 23:53:52.000342] [main] [FINER] uploadData: call: 1 txn: 611 begin CrudTransaction<611, [CrudEntry<611/2441 PATCH mww/12 {v: 4472}>, CrudEntry<611/2442 PATCH mww/88 {v: 4472}>, CrudEntry<611/2443 PATCH mww/87 {v: 4472}>, CrudEntry<611/2444 PATCH mww/60 {v: 4472}>]>
...
[2025-07-20 23:53:52.052889] [main] [FINER] uploadData: call: 1 txn: 611 committed
[2025-07-20 23:53:52.053189] [main] [FINER] uploadData: call: 1 txn: 612 begin CrudTransaction<612, [CrudEntry<612/2445 PATCH mww/17 {v: 4473}>, CrudEntry<612/2446 PATCH mww/24 {v: 4473}>, CrudEntry<612/2447 PATCH mww/64 {v: 4473}>, CrudEntry<612/2448 PATCH mww/8 {v: 4473}>]>
...
[2025-07-20 23:53:52.065657] [main] [FINER] uploadData: call: 1 txn: 612 committed
[2025-07-20 23:53:52.066858] [main] [FINER] uploadData: call: 1 end with UploadQueueStats.count: 0

# transactions writing 4472 and 4473, the transactions in the upload queue at the time of the kill
# have been upload and the queue is empty

# the following 2 new transactions, after the kill and before the end of the test, with local writes will never be uploaded

[2025-07-20 23:53:52.115743] [main] [FINE] SQL txn: response: {clientType: ps, f: txn, type: ok, value: [{f: readAll, k: null, v: {0: 4461, }}, {f: writeSome, k: null, v: {90: 4842, 80: 4842, 5: 4842, 7: 4842}}]}
[2025-07-20 23:53:52.143933] [main] [FINE] SQL txn: response: {clientType: ps, f: txn, type: ok, value: [{f: readAll, k: null, v: {0: 4461, }}, {f: writeSome, k: null, v: {65: 4843, 94: 4843, 43: 4843, 49: 4843}}]}

# client is still downloading all of the transactions from the other clients that happened while it was killed

[2025-07-20 23:53:52.160452] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 592 / 592) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
...
[2025-07-20 23:53:52.341508] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 644 / 644) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>

# it's the end of the test
# test begins waiting for the upload queue to be empty

[2025-07-20 23:53:52.372307] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:52.372329] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 644 / 644) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>

# these will be the last SyncStatus messages received

[2025-07-20 23:53:52.380560] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 644 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:52.384780] [main] [FINEST] SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>

# test continues to wait for the upload queue to be empty, which never happens
# test will wait for 11 seconds before failing although it can wait indefinitely
# note that downloading will stay true and progress stays 656/656 and never nulls

[2025-07-20 23:53:53.373404] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:53.373433] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:54.374406] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:54.374436] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:55.375396] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:55.375433] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:56.376429] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:56.376482] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:57.377454] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:57.377504] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:58.378385] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:58.378416] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:53:59.379378] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:53:59.379412] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:54:00.380425] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:54:00.380460] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:54:01.381362] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:54:01.381392] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:54:02.382556] [main] [FINE] database api: uploadQueueWait: waiting on UploadQueueStats.count: 8 ...
[2025-07-20 23:54:02.382598] [main] [FINE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:54:03.383374] [main] [SEVERE] UploadQueueStats.count appears to be stuck at 8 after waiting for 11s
[2025-07-20 23:54:03.383401] [main] [SEVERE] 	db.closed: false
[2025-07-20 23:54:03.383408] [main] [SEVERE] 	db.connected: true
[2025-07-20 23:54:03.383417] [main] [SEVERE] 	db.currentStatus: SyncStatus<connected: true connecting: false downloading: true (progress: for total: 656 / 656) uploading: false lastSyncedAt: 2025-07-20 23:53:44.000, hasSynced: true, error: null>
[2025-07-20 23:54:03.383544] [main] [SEVERE] 	db.getUploadQueueStats(): UploadQueueStats<count: 8 size: 0.15625kB>
[2025-07-20 23:54:03.383566] [main] [SEVERE] Error exit: reason: uploadQueueStatsCount, code: 12
```

As expected, network errors exist in sync service logs:
```bash
$ find . -name 'client.log' -exec grep -H -P 'error: (?!null)' {} \;
$ grep -i 'err' powersync.log 
{"cause":{"code":"ECONNREFUSED","message":"request to http://localhost:8089/api/auth/keys failed, reason: connect ECONNREFUSED 127.0.0.1:8089","name":"FetchError"},...}
```

----

### GitHub Actions 

There's a suite of [GitHub Actions](https://github.com/nurturenature/jepsen-powersync/actions) with an action for every type of fault.

Each action uses a test matrix for
- number of clients
- rate of transactions
- fault characteristics
- and other common configuration options

Oddly, GitHub Actions can fail
- pulling Docker images from the GitHub Container Registry
- building images
- pause in the middle of a test run and timeout

Ignorable failure status messages
- "GitHub Actions has encountered an internal error when running your job."
- "The action '5c-20tps-100s...' has timed out after 25 minutes."
- "Process completed with exit code 255."

These failures are Microsoft resource allocation and infrastructure issues and are not related to the tests.

The action will fail with an exit code of 255 and "no logs available" log file contents when this happens.

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
