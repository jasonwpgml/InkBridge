#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/InkBridge Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework SwiftUI -framework ScreenCaptureKit -framework PencilKit \
  -framework MultipeerConnectivity -framework CoreImage \
  Shared/*.swift Mac/*.swift -o "$APP/Contents/MacOS/InkBridgeMac"
# The Liquid Glass icon needs Xcode's actool; the Command Line Tools alone can't compile .icon files.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun actool Shared/AppIcon.icon \
  --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null >/dev/null
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
info = dict(CFBundleName='InkBridge Mac', CFBundleDisplayName='InkBridge Mac',
            CFBundleIdentifier='local.inkbridge.stream.mac', CFBundleExecutable='InkBridgeMac',
            CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1',
            LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
            CFBundleIconFile='AppIcon', CFBundleIconName='AppIcon',
            NSLocalNetworkUsageDescription='연결한 iPad로 맥 화면을 보내고 필기를 받습니다.',
            NSBonjourServices=['_inkbridge-v1._tcp', '_inkbridge-v1._udp'])
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "${INKBRIDGE_SIGNING_IDENTITY:--}" "$APP"
printf 'Built: %s\n' "$APP"
