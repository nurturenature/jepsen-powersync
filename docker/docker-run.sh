#!/bin/bash
# set -e test may fail, still want echo

# pass Jepsen cli to run in docker as args

docker exec \
       -t \
       -w /jepsen/jepsen-powersync \
       jepsen-control \
       bash -c "source /root/.bashrc && cd /jepsen/jepsen-powersync && $*"

jepsen_exit=$?

echo
echo "The test is complete"
echo "Run the test webserver, ./jepsen-web.sh"

exit ${jepsen_exit}
