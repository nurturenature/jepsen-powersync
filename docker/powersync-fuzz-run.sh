#!/bin/bash
set -e

docker exec \
       -t \
       -w /powersync_endpoint \
       powersync-fuzz-node \
       bash -c "$* 2>&1 | tee powersync_fuzz.log"
