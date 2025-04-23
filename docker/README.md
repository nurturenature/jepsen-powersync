## Running the Tests in Docker

### Jepsen Test Environment

```shell
cd jepsen-powersync/docker

# build, bring up cluster
./docker-build.sh
./docker-compose-up.sh

# run a test
./docker-run.sh lein run test --workload sqlite3-local --nodes n1

# bring up a web server for test results
./jepsen-web.sh

# visit http://localhost:8088

# bring cluster down and cleanup containers, networks, and volumes
./docker-compose-down.sh
```

Images are largish:
- Debian systemd base images
- system tools used to inject real faults
- full Jepsen libraries

----

### Dart CLI Fuzzer Environment

```bash
cd jepsen-powersync/docker

# conditionally cleanup and build a fuzzing environment, bring up a full PowerSync cluster and fuzzing node
./powersync-fuzz-down.sh && ./powersync-fuzz-build.sh && ./powersync-fuzz-up.sh

# run a fuzz test on the fuzzing node
./powersync-fuzz-run.sh ./powersync_fuzz --clients 10 --rate 10 --time 100 --postgresql --disconnect orderly --no-stop --no-kill --partition --no-pause --interval 5

# download the test run's output from the container to the local host for local analysis
docker cp powersync-fuzz-node:/jepsen/jepsen-powersync/powersync_endpoint/powersync_fuzz.log .
```
