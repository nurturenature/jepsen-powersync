#!/bin/bash
set -e

export JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/"

docker compose \
       -f powersync-compose.yaml \
       -f powersync-fuzz-compose.yaml \
       --env-file ../.env \
       up \
       --detach \
       --wait

docker ps --format="table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo
echo "A full PowerSync cluster with a fuzzing node, powersync-fuzz-node, is up and available."
echo "Run a PowerSync fuzz test with ./powersync-fuzz-run.sh ./powersync_fuzz --help"
