#!/bin/bash
set -e

# build a powersync-fuzz image

docker build \
       -t powersync-fuzz-node \
       -f powersync-fuzz-node.Dockerfile \
       ../powersync_endpoint

echo
echo "powersync-fuzz-node Docker image has been built."
echo "Bring up a PowerSync cluster for fuzzing with ./powersync-fuzz-compose-up.sh"
