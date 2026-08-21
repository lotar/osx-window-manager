#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/dist/Glass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Glass" "$APP/Contents/MacOS/Glass"
chmod +x "$APP/Contents/MacOS/Glass"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Stable identity so Accessibility grant survives rebuilds.
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Glass Developer'; then
  codesign --force --deep --sign "Glass Developer" "$APP"
fi

echo "$APP"
