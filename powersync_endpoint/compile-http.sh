#!/bin/bash
set -e

dart compile \
    exe \
    --target-os linux \
    --output=powersync_http \
    bin/powersync_http.dart
