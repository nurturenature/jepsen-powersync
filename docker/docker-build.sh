#!/bin/bash
set -e

# add PowerSync to Jepsen images

docker build \
       -t jepsen-node \
       --build-arg JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/" \
       -f jepsen-node.Dockerfile \
       ../sqlite3_endpoint

docker build \
       -t jepsen-control \
       --build-arg JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/" \
       -f jepsen-control.Dockerfile \
       ../jepsen

# jepsen-setup not built locally so pull it as part of build
docker pull ghcr.io/nurturenature/jepsen-docker/jepsen-setup:latest

echo
echo "Jepsen control + PowerSync node Docker images have been built."
echo "Bring up a Jepsen + PowerSync cluster with ./docker-compose-up.sh"
