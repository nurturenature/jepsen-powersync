A PowerSync fuzzer for testing the `disconnect()/connect()` API functionality.

`download-powersync-sqlite-core.sh`

Compile with `./compile.sh`.
Run with `./powersync_fuzz -h`.

Capture log output `./powersync_fuzz 2>&1 | tee powersync_fuzz.log`

upload errors
ignorable -> warning
else -> severe

uploading = true indeterminate
severe

syncStatus value mismatches