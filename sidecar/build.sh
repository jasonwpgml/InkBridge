#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${INKBRIDGE_BUILD_APP:-$ROOT/InkBridge.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework Carbon -framework UniformTypeIdentifiers "$ROOT/Sources/InkModel.swift" "$ROOT/Sources/InkRendering.swift" "$ROOT/Sources/InkCursor.swift" "$ROOT/Sources/GlassSurface.swift" "$ROOT/Sources/ToolControls.swift" "$ROOT/Sources/PencilDiagnostics.swift" "$ROOT/Sources/PencilCanvas.swift" "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/InkBridge"
# The Liquid Glass icon needs Xcode's actool; the Command Line Tools alone can't compile .icon files.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun actool "$ROOT/../Shared/AppIcon.icon" \
  --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null >/dev/null
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
