#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/check
xcrun swiftc -swift-version 5 Shared/Protocol.swift iPad/WritingTools.swift Tests/main.swift -o build/check/protocol-tests
build/check/protocol-tests
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework SwiftUI -framework ScreenCaptureKit -framework PencilKit \
  -framework MultipeerConnectivity -framework CoreImage \
  Shared/*.swift Mac/*.swift -o build/check/InkBridgeMac
printf 'Mac compilation passed\n'
