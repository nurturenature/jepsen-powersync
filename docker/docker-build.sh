#!/bin/bash
set -e

# add PowerSync to Jepsen images

docker build \
       -t powersync-node \
       --build-arg JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/" \
       -f jepsen-node.Dockerfile \
       ../powersync_endpoint

docker build \
       -t powersync-control \
       --build-arg JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/" \
       -f jepsen-control.Dockerfile \
       ../jepsen

echo
echo "Jepsen control + PowerSync node Docker images have been built."
echo "Bring up a Jepsen + PowerSync cluster with ./docker-compose-up.sh"
