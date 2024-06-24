#!/bin/bash
set -e

dart compile \
    exe \
    --target-os linux \
    --output=powersync_endpoint \
    bin/main.dart
