## Strong Convergence Anomalies

GitHub Action for [no fault](https://github.com/nurturenature/jepsen-powersync/actions/workflows/fuzz-no-fault.yml) environment that demonstrates final reads that diverge, i.e. violate Strong Convergence.

Using the test matrix:
```yml
clients: >
  [ '5', '10']
rates: >
  [ '10', '20', '30', '40', '50']
times: >
  [ '100', '200', '300', '400', '500', '600', '700', '800', '900', '1000', '1100', '1200' ]
postgresql: >
  [ '--postgresql', '--no-postgresql' ]
```

Note: `[ '--postgresql', '--no-postgresql' ]` indicates whether reads/writes are active/active, both PowerSync and PostgreSQL or PowerSync only, no PostgreSQL.

----

#### Strong Convergence

Rates < 50tps converge over all clients, times, and both active/active and PowerSync only updates.

#### Occasional Divergence

At 50tps and 10 clients divergence starts appearing at 300s with active/active updates.

#### Consistent Divergence

At 50tps and 10 clients tests always diverge when time >= 500s with both active/active and PowerSync only updates.

----

### Interpreting an Example

Let's choose the smallest example to look at as the log files are large:
- 10 clients, 50tps rate, 300s time, active/active 

At the tail of the log file we can see `SEVERE` messages that show the final read from PostgreSQL, our source of truth, and each individual client. The output is a summary, i.e. only shows divergent `{k: v}` values.

```log
[2025-03-04 23:17:50.364370] [main] [SEVERE] Divergent final reads!:
[2025-03-04 23:17:50.364387] [main] [SEVERE] PostgreSQL {k: v} for client diversions:
[2025-03-04 23:17:50.364439] [main] [SEVERE] 	{0: 14987, 1: 14990, 2: 14949, 3: 14994, 4: 14971, 5: 14961, 6: 14996, 7: 14998, 8: 14971, 9: 14988, 10: 14965, 11: 14996, 12: 14974, 13: 14987, 14: 14990, 15: 14988, 16: 14998, 17: 14975, 18: 14906, 19: 14813, 20: 14997, 21: 14978, 22: 14972, 23: 14970, 24: 14998, 25: 14968, 26: 14997, 27: 14985, 28: 14999, 29: 14998, 30: 14969, 31: 14976, 32: 14989, 33: 14992, 34: 14978, 35: 14993, 36: 14993, 37: 14951, 38: 14991, 39: 14939, 40: 14944, 41: 14982, 42: 14995, 43: 14976, 44: 14979, 45: 14934, 46: 14995, 47: 14953, 48: 14994, 49: 14919, 50: 14982, 51: 14992, 52: 14985, 53: 14994, 54: 14986, 55: 14986, 56: 14992, 57: 14965, 58: 14987, 59: 14991, 60: 14999, 61: 14985, 62: 14995, 63: 14949, 64: 14994, 65: 14999, 66: 14977, 67: 14963, 68: 14959, 69: 14972, 70: 14985, 71: 14983, 72: 14997, 73: 14991, 74: 14975, 75: 14988, 76: 14993, 77: 14981, 78: 14980, 79: 14990, 80: 14977, 81: 14968, 82: 14977, 83: 14826, 84: 14976, 85: 14969, 86: 14959, 87: 14989, 88: 14986, 89: 14959, 90: 14955, 91: 14979, 92: 14997, 93: 14990, 94: 14983, 95: 14984, 96: 14986, 97: 14909, 98: 14977, 99: 14999}
[2025-03-04 23:17:50.364463] [main] [SEVERE] ps-1 {k: v} that diverged from PostgreSQL
[2025-03-04 23:17:50.364494] [main] [SEVERE] 	{1: 14931, 2: 14596, 3: 14477, 4: 14824, 5: 14951, 7: 14802, 8: 14905, 9: 14770, 10: 14869, 12: 14934, 14: 14699, 15: 14602, 16: 14565, 17: 14777, 18: 14757, 19: 14306, 20: 14659, 21: 14665, 22: 14725, 23: 14589, 24: 14905, 26: 14996, 27: 14695, 28: 14725, 29: 14641, 31: 14905, 32: 14987, 33: 14596, 34: 14262, 35: 14695, 36: 14980, 38: 14769, 39: 14824, 40: 14558, 41: 14980, 42: 14951, 43: 14826, 44: 14824, 46: 14869, 47: 14901, 48: 14869, 49: 14665, 50: 14969, 51: 14931, 52: 14466, 53: 14869, 54: 14045, 55: 14652, 56: 14705, 57: 14333, 59: 14609, 60: 14092, 61: 14155, 62: 14826, 63: 14652, 64: 14769, 65: 14951, 66: 14725, 67: 14931, 68: 14468, 69: 14786, 70: 14798, 71: 14217, 72: 14909, 73: 14931, 74: 14495, 75: 14006, 76: 14798, 77: 14484, 79: 14824, 80: 14235, 82: 14710, 84: 14934, 86: 14659, 87: 14340, 88: 14850, 89: 14934, 90: 14798, 91: 14901, 92: 14774, 93: 14425, 94: 14072, 95: 14786, 96: 14770, 98: 14969, 99: 14996}
[2025-03-04 23:17:50.364575] [main] [SEVERE] ps-2 {k: v} that diverged from PostgreSQL
[2025-03-04 23:17:50.364611] [main] [SEVERE] 	{0: 14513, 2: 14764, 3: 14389, 4: 14694, 5: 14171, 6: 14945, 8: 14933, 9: 14793, 10: 14645, 11: 14945, 12: 14782, 13: 14751, 15: 14479, 17: 14807, 18: 14877, 19: 14687, 20: 14734, 21: 14891, 22: 14868, 23: 14741, 25: 14760, 26: 14858, 27: 14672, 28: 14868, 30: 14718, 32: 14933, 33: 14479, 34: 14805, 35: 14590, 36: 14793, 37: 14513, 38: 14858, 39: 14877, 40: 14513, 41: 14933, 42: 14807, 44: 14945, 45: 14694, 46: 13550, 47: 14535, 48: 14139, 49: 14817, 50: 14955, 51: 13548, 52: 14686, 53: 14396, 54: 14675, 55: 14514, 56: 14726, 57: 14760, 58: 14891, 59: 14760, 60: 14868, 61: 14891, 62: 14760, 63: 14690, 64: 14249, 65: 14694, 66: 14553, 67: 14868, 68: 14734, 69: 14858, 70: 14718, 71: 14718, 72: 14405, 73: 14945, 74: 14782, 75: 14764, 76: 14955, 77: 14645, 78: 14955, 80: 14751, 81: 14022, 82: 14858, 83: 14687, 85: 14604, 86: 14327, 87: 14719, 88: 14719, 89: 14162, 91: 14655, 92: 14234, 94: 14746, 95: 14782, 96: 14741, 97: 14142, 98: 14687, 99: 14817}
...
```

Note that clients ps-1 and ps-2 show divergence between some keys that are similar and some that are distinct with values that are distinct.

Let's look at key 2 as both clients and PostgreSQL all have different values by grepping through the log looking for the PostgreSQL value:
- PostgreSQL: `grep '2: 14949' powersync_fuzz.log`
  ```log
  # written by client ps-5
  [2025-03-04 23:17:16.267290] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, value: [{f: writeSome, k: -1, v: {2: 14949, 81: 14949, 14: 14949, 63: 14949}}]}
  
  # ps-5 BackendConnector.uploadData()
  [2025-03-04 23:17:16.279645] [ps-5] [FINER] uploadData: txn: 1369 patch: {2: 14949}
  
  # ps-5 repeatedly reads
  [2025-03-04 23:17:16.459805] [ps-5] [FINE] SQL txn: response: {clientNum: 5, clientType: ps, value: [{f: readAll, k: -1, v: {... 2: 14949, ...}}]}
  
  # ps-0, PostgreSQL repeatedly reads
  [2025-03-04 23:17:16.573451] [ps-0] [FINE] SQL txn: response: {clientNum: 0, clientType: pg, value: [{f: readAll, k: -1, v: {..., 2: 14949, ...}}]}
  ```
- no other clients interact with '2: 14949'

Before doing final reads, the tests:
- quiesce for 3s
- wait for the upload que == 0
- wait for SyncStatus.downloading == false

When there's divergent final reads, SyncStatus.downloading remains true indefinitely, the tests try for 30s before giving up:
```log
$ grep 'WARNING' powersync_fuzz.log
[2025-03-04 23:17:50.313972] [ps-7] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.314982] [ps-6] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.317332] [ps-10] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.321494] [ps-8] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.321568] [ps-1] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.321599] [ps-4] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.322617] [ps-5] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.323002] [ps-2] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.325515] [ps-9] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
[2025-03-04 23:17:50.325590] [ps-3] [WARNING] PowerSyncDatabase: waited for db.currentStatus.downloading == false: tried 31 times every 1000ms
```

There is no `SyncStatus` or `UpdateNotification` during this time.

The GitHub Action results are relatively consistent re success/failure.

To reproduce on a local machine:
```bash
cd jepsen-powersync/docker

# simplest CLI args most likely to produce divergence in several test runs
./powersync-fuzz-loop.sh ./powersync_fuzz --table mww --clients 10 --rate 50 --time 300 --postgresql

# cp logs from Docker container to host
docker cp powersync-fuzz-node:/jepsen/jepsen-powersync/powersync_endpoint/powersync_fuzz.log .
```
