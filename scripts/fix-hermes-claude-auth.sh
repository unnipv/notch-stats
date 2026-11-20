#!/usr/bin/env bash
# Stops Hermes from borrowing and rotating Claude Code's macOS Keychain OAuth
# refresh token by setting `adopt_external_logins: false` in ~/.hermes/config.yaml.
#
# Dry-run by default. Pass `--apply` to write the change (with a timestamped
# backup first). Never reads or prints secrets and never modifies ~/.claude/.
#
# Usage:
#   scripts/fix-hermes-claude-auth.sh [--config PATH] [--apply]
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

CONFIG_PATH="${HERMES_HOME:-$HOME/.hermes}/config.yaml"
APPLY=0

usage() {
  cat <<'EOF'
Usage: scripts/fix-hermes-claude-auth.sh [--config PATH] [--apply]

Checks ~/.hermes/config.yaml for `adopt_external_logins: true`. When enabled,
Hermes borrows Claude Code's macOS Keychain OAuth login (`Claude Code-credentials`)
and refreshes its single-use refresh token on ~8h expiry using a separate lock
file (`~/.claude/.credentials.lock`) and un-scoped refresh request, causing the
next Claude Code CLI session to clear its credentials and require `/login`.

Options:
  --config PATH   Path to Hermes config.yaml (default: ~/.hermes/config.yaml)
  --apply         Write `adopt_external_logins: false` (default: dry-run only)
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      shift
      CONFIG_PATH="${1:-}"
      ;;
    --apply)
      APPLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -f "$CONFIG_PATH" ]; then
  printf 'Hermes config not found at %s — nothing to change.\n' "$CONFIG_PATH"
  exit 0
fi

current_line="$(grep -nE '^[[:space:]]*adopt_external_logins:' "$CONFIG_PATH" | head -n 1 || true)"

if [ -z "$current_line" ]; then
  printf 'No explicit `adopt_external_logins` key found in %s.\n' "$CONFIG_PATH"
  printf 'Note: Hermes defaults `auth.adopt_external_logins` to true when omitted.\n'
  printf 'Add the following under `auth:` in %s:\n\n  auth:\n    adopt_external_logins: false\n' "$CONFIG_PATH"
  exit 0
fi

printf 'Found in %s:\n  %s\n' "$CONFIG_PATH" "$current_line"

if printf '%s\n' "$current_line" | grep -qE 'adopt_external_logins:[[:space:]]*false'; then
  printf 'Already disabled (`adopt_external_logins: false`). No changes needed.\n'
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  printf '\nDry run — no file was modified.\n'
  printf 'Re-run with `--apply` to back up %s and set `adopt_external_logins: false`.\n' "$CONFIG_PATH"
  printf 'After applying:\n'
  printf '  1. Restart the Hermes gateway so the new config takes effect.\n'
  printf '  2. If Hermes itself needs Anthropic models, give it its own login: `hermes auth add anthropic`.\n'
  printf '  3. Run `claude` and verify `/status` (or `/login` once if currently signed out).\n'
  exit 0
fi

backup="${CONFIG_PATH}.bak-$(date '+%Y%m%dT%H%M%S')"
cp -p "$CONFIG_PATH" "$backup"
printf 'Backup written to %s\n' "$backup"

tmp="${CONFIG_PATH}.tmp.$$"
awk '
  BEGIN { done = 0 }
  !done && /^[[:space:]]*adopt_external_logins:[[:space:]]*true([[:space:]]*(#.*)?)?$/ {
    sub(/adopt_external_logins:[[:space:]]*true/, "adopt_external_logins: false")
    done = 1
  }
  { print }
' "$CONFIG_PATH" > "$tmp"

chmod --reference="$CONFIG_PATH" "$tmp" 2>/dev/null || chmod 600 "$tmp"
mv "$tmp" "$CONFIG_PATH"

printf 'Updated %s:\n' "$CONFIG_PATH"
grep -nE '^[[:space:]]*adopt_external_logins:' "$CONFIG_PATH" | head -n 5
printf '\nNext steps:\n'
printf '  1. Restart the Hermes gateway so the new config takes effect.\n'
printf '  2. If Hermes itself needs Anthropic models, give it its own login: `hermes auth add anthropic`.\n'
printf '  3. Run `claude` and verify authentication (or `/login` once if currently signed out).\n'
