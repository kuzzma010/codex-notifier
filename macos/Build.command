#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Сборка требует macOS и Xcode."
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Открой Xcode, заверши настройку и выбери Command Line Tools в Xcode → Settings → Locations."
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=13.0
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/arm64 build/x86_64
SOURCES=(Sources/*.swift)
for ARCH in arm64 x86_64; do
  echo "Сборка для ${ARCH}…"
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
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "Проверка логики…"
"$APP/Contents/MacOS/CodexNotifier" --self-test
echo "Готово. Перетащи Codex Notifier.app в Applications и запусти."
open -R "$APP"
