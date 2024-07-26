#!/bin/bash
set -e

TARGET_DIR=../jepsen/store/current
mkdir -p $TARGET_DIR

docker logs powersync     &> $TARGET_DIR/powersync.log     || echo "no docker logs" > $TARGET_DIR/powersync.log
docker logs pg-db         &> $TARGET_DIR/pg-db.log         || echo "no docker logs" > $TARGET_DIR/pg-db.log
docker logs mongo         &> $TARGET_DIR/mongo.log         || echo "no docker logs" > $TARGET_DIR/mongo.log
docker logs mongo-rs-init &> $TARGET_DIR/mongo-rs-init.log || echo "no docker logs" > $TARGET_DIR/mongo-rs-init.log
docker cp jepsen-control:/jepsen/jepsen-powersync/store/current/. $TARGET_DIR || echo "no docker logs for jepsen-control"
