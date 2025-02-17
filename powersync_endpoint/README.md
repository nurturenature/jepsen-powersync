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
