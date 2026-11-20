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

# Signing precedence:
#   1. NOTCHSTATS_SIGN_IDENTITY when explicitly set,
#   2. Any valid code-signing certificate whose CN starts with "NotchStats"
#      (e.g. "NotchStats Dev" created by scripts/make-signing-cert.sh),
#   3. Ad-hoc signing (-) fallback. Never fails the build if no identity exists.
SIGN_IDENTITY="${NOTCHSTATS_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(NotchStats[^"]*\)".*/\1/p' \
    | head -1 || true)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with identity: $SIGN_IDENTITY"
  if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"; then
    echo "!! Signing with '$SIGN_IDENTITY' failed; falling back to ad-hoc" >&2
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "codesign skipped"
  fi
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "codesign skipped"
fi

echo "==> Built $APP"
