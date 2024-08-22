#!/bin/bash
set -e

# app is responsible for getting native lib
wget --no-verbose -O libpowersync_x64.so https://github.com/powersync-ja/powersync-sqlite-core/releases/download/v0.2.0/libpowersync_x64.so
