#!/bin/bash
set -e

set -o pipefail

docker exec \
       -t \
       -w /jepsen/jepsen-powersync/powersync_endpoint \
       jepsen-n1 \
       bash -c "set -o pipefail && $* 2>&1 | tee powersync_fuzz.log"
