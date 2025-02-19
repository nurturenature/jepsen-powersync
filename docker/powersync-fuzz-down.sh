#!/bin/bash
set -e

export JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/"

docker compose \
       -f powersync-compose.yaml \
       -f powersync-fuzz-compose.yaml \
       --env-file ../.env \
       down \
       -v
