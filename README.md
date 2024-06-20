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
  final select = await tx.getOptional('SELECT * from lww where k = ?', [mop['k']]);
  await tx.execute(
    'INSERT OR REPLACE INTO lww (k,v) VALUES (?,?) ON CONFLICT (k) DO UPDATE SET v = lww.v || \' \' || ?',
    [k, v, v]);
  });
```

backend replication is transaction based:
```dart
PowerSyncDatabase.getNextCrudTransaction();

Connection.runInTransaction();
```

The implementation will evolve to use other data models and APIs to find the different consistency levels, performance, and usability trade-offs.

----

### Progressive Test Enhancement

Single user, generic SQLite3 db, no PowerSync
- tests the tests
- demonstrates test fidelity, i.e. accurately represent the database
 
Single user, PowerSync db, local only
- expectation is total availability and strict serializability
- SQLite3 is tight and using PowerSync APIs should reflect that

Single user, PowerSync db, with replication
- expectation stays the same

Multi user, generic SQLite3 shared db, no PowerSync
- tests the tests
- demonstrates test fidelity, i.e. accurately represent the database

Multi user, PowerSync db, with replication, using example backend connector
- expectation is
  - read committed vs Causal
  - non-atomic transactions with intermediate reads
  - strong convergence

Multi user, PowerSync db, with replication, using newly developed Causal connector 
- expectation is
  - Causal Consistency
  - Atomic transactions
  - Strong Convergence

Multi user, Active/Active PostgreSQL/SQLite, with replication
- mix of clients, some PostgreSQL, some PowerSync
- expectation remains Causal+

----

### Clients

The client will be a simple Dart CLI PowerSync implementation.
It will also expose an http endpoint for Jepsen to post transactions to and receive the results.

Clients are expected to have total sticky availability
- throughout the session, each client uses the
  - same API
  - same connection
- clients are expected to be available, liveness, unless explicitly killed or paused

Observe and interact with the database
- `PowerSyncDatabase` driver
  - single `writeTransaction` with multiple statements
  - split `readTransaction` \ `writeTransaction`
- `watch` query stream
  - reactive UI should receive a Causal+ view
- PostgreSQL
  - most used Dart pub.dev driver 
- `SqliteDatabase` driver
  - TODO: confirm this is appropriate, i.e. direct access to a sync'd SQLite3

----

### Faults

LoFi and distributed systems live in a rough and tumble environment.

Successful applications, amount/duration of use, will be exposed to faults. Reality is like that. 

Faults are applied
- to random clients
- at random intervals
- for random durations

We still expect total sticky availability unless the client has been explicitly paused/killed.

#### Offline / Online

- `close()`, `connect()`, `disconnect()`, `disconnectAndClose()`

#### Network

- progressively degrade the network up to total partitioning
- client backend <-> PowerSync service
- PowerSync service <-> PostgreSQL

#### Pause / Kill

- `kill stop\cont` client process(es)
- `kill -9` client process(es)

----

### Conflict Resolution

Last write wins, with last defined as the last transaction executed on the PostgreSQL backend with `repeatable read` isolation.

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

Miscellaneous notes on [usage](./doc/usage.md).