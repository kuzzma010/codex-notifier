#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Building requires macOS and Xcode."
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Open Xcode, finish setup and select Command Line Tools in Xcode → Settings → Locations."
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=13.0
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/arm64 build/x86_64
SOURCES=(Sources/*.swift)
for ARCH in arm64 x86_64; do
  echo "Building for ${ARCH}…"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization \
    -sdk "$SDK" -target "$ARCH-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework CoreServices \
    -framework ServiceManagement -framework ApplicationServices \
    "${SOURCES[@]}" -o "build/$ARCH/CodexNotifier"
done
APP="build/Codex Notifier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create build/arm64/CodexNotifier build/x86_64/CodexNotifier -output "$APP/Contents/MacOS/CodexNotifier"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/App.icns "$APP/Contents/Resources/App.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "Checking core logic…"
"$APP/Contents/MacOS/CodexNotifier" --self-test
echo "Done. Move Codex Notifier.app to Applications and launch it."
open -R "$APP"
