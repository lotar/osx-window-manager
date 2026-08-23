#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/dist/osx-window-manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/osx-window-manager" "$APP/Contents/MacOS/osx-window-manager"
chmod +x "$APP/Contents/MacOS/osx-window-manager"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Sign with a persistent identity when available so the Accessibility grant
# survives rebuilds; fall back to ad-hoc signing otherwise.
IDENTITY="Glass Developer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo "$APP"
