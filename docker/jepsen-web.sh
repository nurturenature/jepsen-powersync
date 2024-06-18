#!/bin/bash
set -e

docker exec -t \
       -w /jepsen/jepsen-powersync \
       jepsen-control \
       lein run serve
 