#!/usr/bin/env bash
# NotchStats installer.
#
#   curl -fsSL https://raw.githubusercontent.com/notch-stats/notch-stats/main/scripts/install.sh | bash
#
# Override the source repo with NOTCHSTATS_REPO=owner/name.

set -euo pipefail

REPO="${NOTCHSTATS_REPO:-notch-stats/notch-stats}"
APP_NAME="NotchStats"
ASSET="${APP_NAME}.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "NotchStats is macOS only."

say "Finding the latest release of $REPO"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o "\"browser_download_url\": *\"[^\"]*$ASSET\"" \
  | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[[ -n "${URL:-}" ]] || die "No $ASSET asset found in the latest release."

say "Downloading $(basename "$URL")"
curl -fsSL "$URL" -o "$TMP/$ASSET"

say "Unpacking"
ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
SRC="$(find "$TMP/unpacked" -maxdepth 2 -name "$APP_NAME.app" -type d | head -1)"
[[ -n "$SRC" ]] || die "Could not find $APP_NAME.app in the archive."

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  say "No write access to /Applications — installing to $DEST"
fi

say "Installing to $DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "$SRC" "$DEST/$APP_NAME.app"

say "Removing quarantine attribute"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true

say "Installed $DEST/$APP_NAME.app"
printf 'Launch it with: open "%s/%s.app"\n' "$DEST" "$APP_NAME"
