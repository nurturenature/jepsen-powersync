#!/bin/bash
set -e

docker compose \
       -f powersync-compose.yaml \
       -f powersync-fuzz-compose.yaml \
       --env-file ../.env \
       up \
       --detach \
       --wait

docker ps --format="table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo
echo "A full PowerSync cluster with a powersync-fuzz-node is up and available"
echo "Run a fuzz test with ./powersync-fuzz-run.sh ./powersync_fuzz --help"
