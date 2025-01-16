#!/bin/bash
set -e

dart compile \
    exe \
    --target-os linux \
    --output=powersync_fuzz \
    bin/powersync_fuzz.dart
