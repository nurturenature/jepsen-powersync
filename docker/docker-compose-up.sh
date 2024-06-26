#!/bin/bash
set -e

export JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/"

docker compose \
       -f powersync-compose.yaml \
       -f jepsen-compose.yaml \
       -f jepsen-powersync-compose.yaml \
       --env-file ../.env \
       up \
       --detach \
       --wait

docker ps --format="table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo
echo "A full Jepsen control + PowerSync node cluster is up and available"
echo "Run a Jepsen test with ./docker-run.sh lein run test"
