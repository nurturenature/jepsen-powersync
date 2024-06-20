#!/bin/bash
set -e

export JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/"

docker compose \
       -f powersync-compose.yaml \
       -f jepsen-compose.yaml \
       -f jepsen-powersync-compose.yaml \
       down \
       -v
