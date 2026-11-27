#!/bin/sh
# Remove generated build artifacts only. NEVER touch sessions/, config or .env.
# The build recreates these directories on the next `zig build`.
set -eu
cd "$(dirname "$0")/.."
rm -rf .zig-cache zig-out zig-cache
echo "removed generated caches and binaries (sessions/ and config untouched)"
