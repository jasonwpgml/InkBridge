#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/InkBridge Mac.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework SwiftUI -framework ScreenCaptureKit -framework PencilKit \
  -framework MultipeerConnectivity -framework CoreImage \
  Shared/*.swift Mac/*.swift -o "$APP/Contents/MacOS/InkBridgeMac"
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
info = dict(CFBundleName='InkBridge Mac', CFBundleDisplayName='InkBridge Mac',
            CFBundleIdentifier='local.inkbridge.stream.mac', CFBundleExecutable='InkBridgeMac',
            CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1',
            LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
            NSLocalNetworkUsageDescription='연결한 iPad로 맥 화면을 보내고 필기를 받습니다.',
            NSBonjourServices=['_inkbridge-v1._tcp', '_inkbridge-v1._udp'])
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "${INKBRIDGE_SIGNING_IDENTITY:--}" "$APP"
printf 'Built: %s\n' "$APP"
