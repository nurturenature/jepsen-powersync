## Logbook

### In Progress

Started syncing.

PowerSync
- setup.sql
- sync rules
- config.yaml and .env

Endpoint
- `sql-txn` handler
  - just interact with k/v columns
  - let PowerSync manage id
- `CrudBatch/Entry` backend 

Workload
- final read from Postgres
  - test strong convergence

Expectations
- total availability
- strict serializability
  - local writes/reads
- strong convergence
  - Postgres final read

Test command:
```shell
lein run test --workload powersync-single --rate 150 --time-limit 100 --nodes n1
```

----

## History

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
