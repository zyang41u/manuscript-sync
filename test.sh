#!/bin/bash
# Build and run the sync engine tests against throwaway local repos.
set -euo pipefail
cd "$(dirname "$0")"
# The Command Line Tools Swift on this Mac doesn't match its SDK; Xcode's toolchain works.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/test-tmp
swiftc Sources/Engine.swift Tests/main.swift -o build/engine-tests
build/engine-tests "$PWD/build/test-tmp"
