#!/bin/bash
set -e

# build a powersync-fuzz-node image
#   - reuse jepsen-node env
#   - tag as powersync-fuzz-node

docker build \
       -t powersync-fuzz-node \
       --build-arg JEPSEN_REGISTRY="ghcr.io/nurturenature/jepsen-docker/" \
       -f jepsen-node.Dockerfile \
       ../powersync_endpoint

echo
echo "powersync-fuzz-node Docker image has been built."
echo "Bring up a PowerSync cluster for fuzzing with ./powersync-fuzz-up.sh"
