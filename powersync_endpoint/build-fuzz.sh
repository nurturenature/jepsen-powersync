#!/bin/bash
set -e

dart build \
    cli \
    --output=powersync_fuzz \
    --target=bin/powersync_fuzz.dart
