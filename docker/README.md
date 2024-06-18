## Running the Tests in Docker

```shell
cd docker

# build, bring up cluster
./docker-build.sh
./docker-compose-up.sh

# run a test
./docker-run.sh lein run test --workload sqlite3-local --nodes n1

# bring up a web server for test results
./jepsen-web.sh

# visit http://localhost:8080

# bring cluster down and cleanup containers, networks, and volumes
./docker-compose-down.sh
```

Images are largish:
- Debian systemd base images
- system tools used to inject real faults
- full Jepsen libraries
