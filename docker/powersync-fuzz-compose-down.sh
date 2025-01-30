#!/bin/bash
set -e

docker compose \
       -f powersync-compose.yaml \
       -f powersync-fuzz-compose.yaml \
       --env-file ../.env \
       down \
       -v
