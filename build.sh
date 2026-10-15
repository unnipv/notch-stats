#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="NotchStats"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$NAME.app"
CONFIG="${1:-release}"

echo "==> Building $NAME ($CONFIG, universal)"
cd "$ROOT"

if swift build -c "$CONFIG" --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
else
  echo "!! universal build failed, falling back to host arch"
  swift build -c "$CONFIG"
  BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
BIN="$BIN_DIR/$NAME"

if [ ! -f "$BIN" ]; then
  echo "!! expected binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "codesign skipped"

echo "==> Built $APP"
