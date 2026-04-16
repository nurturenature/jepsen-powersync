#!/bin/bash
set -e

dart build \
    cli \
    --output=powersync_http \
    --target=bin/powersync_http.dart
