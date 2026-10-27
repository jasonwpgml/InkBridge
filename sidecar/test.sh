#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inkbridge-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 "$ROOT/Sources/InkModel.swift" "$ROOT/Tests/main.swift" -o "$TEST_DIR/model-tests"
"$TEST_DIR/model-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit "$ROOT/Sources/InkModel.swift" "$ROOT/Sources/InkRendering.swift" "$ROOT/Tests/Rendering/main.swift" -o "$TEST_DIR/rendering-tests"
"$TEST_DIR/rendering-tests"
