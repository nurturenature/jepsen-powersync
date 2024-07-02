## Logbook

### In Progress

As the range of testing has increased, a couple of potential issues that stop PostgreSQL -> client db replication have surfaced:

```clj
; can crash client
; from client logs:
:logs-ps-client {:valid? false,
                  :count 160,
                  :matches ({:node "n2",
                             :line "ERROR - 2024-07-02 18:42:24.432226"}
                            ...)}
```

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

----

## History

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

![atomic-matix GitHub action results](atomic-matix.png)

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
