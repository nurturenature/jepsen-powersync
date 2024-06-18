#!/bin/bash
set -e

# export JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/"

docker compose \
       -f jepsen-compose.yaml \
       down \
       -v
