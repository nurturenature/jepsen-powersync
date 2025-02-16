#!/bin/bash
set -e

docker exec \
       -t \
       -w /jepsen/jepsen-powersync/powersync_endpoint \
       jepsen-n1 \
       bash -c "$* 2>&1 | tee powersync_fuzz.log"
