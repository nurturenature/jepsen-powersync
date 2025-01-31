#!/bin/bash
set -e

echo
echo    "Opening a shell to the powersync-fuzz-node:"
echo -e "\t./powersync_fuzz -h"
echo -e "\texit to exit"
echo

docker exec \
       -i \
       -t \
       -w /powersync_endpoint \
       powersync-fuzz-node \
       bash
