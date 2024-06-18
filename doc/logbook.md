## Logbook

### Next Step

Add PowerSync to local SQLite3 implementation.

Endpoint
- `PowerSyncDatabase` driver and ffi db
- `PromiscuousAuth` for development
- initial no-op/passthrough backend for local only 
- config
  - sync service
  - local only

Docker
- sync service

Test
- workload

Expectations
- total availability
- strict serializability

----

## History

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

GitHub [Action](https://github.com/nurturenature/jepsen-powersync/actions/workflows/sqlite3-local.yml).

Test command:
```shell
lein run test --workload sqlite3-local --nodes n1
```
