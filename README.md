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

#### `disconnect()` \ `connect()`

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

----

#### Offline / Online

`PowerSyncDatabase` API usage
- `close()`, `disconnectAndClose()`

#### Network

- progressively degrade the network up to total partitioning
- client backend <-> PowerSync service
- PowerSync service <-> PostgreSQL

#### Pause / Kill

- `kill stop\cont` client process(es)
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
