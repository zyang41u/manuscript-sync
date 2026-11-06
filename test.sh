#!/bin/bash
# Build and run the sync engine tests against throwaway local repos.
set -euo pipefail
cd "$(dirname "$0")"
# The Command Line Tools Swift on this Mac doesn't match its SDK; Xcode's toolchain works.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build
swiftc Sources/Engine.swift Tests/main.swift -o build/engine-tests
# The test repos must live outside any git repo, including this one.
TMP=$(mktemp -d -t manuscript-sync-tests)
trap 'rm -rf "$TMP"' EXIT
build/engine-tests "$TMP"
