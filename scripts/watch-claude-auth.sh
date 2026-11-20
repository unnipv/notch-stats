#!/usr/bin/env bash
# Read-only observer for Claude Code macOS authentication stability.
#
# Logs (at most once per interval) only non-secret metadata:
#   - keychain `Claude Code-credentials` existence and `mdat` timestamp
#     (uses `security find-generic-password` WITHOUT `-w` or `-g`, so
#     secret material is never read or printed)
#   - `~/.claude/.credentials.json` presence, size, and mtime
#   - `~/.claude/.credentials.lock` (Hermes) and `.oauth_refresh.lock`
#     (Claude Code) presence and mtimes
#   - running `claude`, `hermes`, and `NotchStats` PIDs
#
# Usage:
#   scripts/watch-claude-auth.sh [--interval 60] [--once] [--log FILE]
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

INTERVAL=60
ONCE=0
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/watch-claude-auth.sh [--interval SECONDS] [--once] [--log FILE]

Monitors Claude Code credential metadata without ever reading or printing
any token or secret material.

Options:
  --interval SECONDS   Poll interval in seconds (default: 60)
  --once               Print one sample and exit
  --log FILE           Append output to FILE as well as stdout
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      shift
      INTERVAL="${1:-60}"
      ;;
    --once)
      ONCE=1
      ;;
    --log)
      shift
      LOG_FILE="${1:-}"
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

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

file_meta() {
  local path="$1"
  if [ -e "$path" ]; then
    local mtime size
    mtime="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$path" 2>/dev/null || printf 'unknown')"
    size="$(stat -f '%z' "$path" 2>/dev/null || printf '?')"
    printf 'present(%sB,%s)' "$size" "$mtime"
  else
    printf 'absent'
  fi
}

keychain_mdat() {
  # Attributes-only lookup: never passes -w or -g, so no secret is read.
  local out mdat
  if ! out="$(security find-generic-password -s 'Claude Code-credentials' 2>/dev/null)"; then
    printf 'absent'
    return
  fi
  mdat="$(printf '%s\n' "$out" | sed -n 's/.*"mdat"<timedate>=.*"\([^\\"]*\)\\000".*/\1/p' | head -n 1)"
  if [ -n "$mdat" ]; then
    printf 'present(%s)' "$mdat"
  else
    printf 'present(unknown)'
  fi
}

pids_matching() {
  local pattern="$1"
  local pids
  # Use ps instead of pgrep so long argv lines (e.g. python3 -m hermes_cli.main)
  # are matched reliably on macOS.
  pids="$(ps -eo pid=,args= 2>/dev/null | awk -v pat="$pattern" -v self="$$" '
    $1 != self && $0 !~ /watch-claude-auth\.sh/ && $0 ~ pat {
      if (out != "") out = out ","
      out = out $1
    }
    END { print out }
  ' || true)"
  if [ -n "$pids" ]; then
    printf '%s' "$pids"
  else
    printf 'none'
  fi
}

emit() {
  local line="$1"
  printf '%s\n' "$line"
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

sample() {
  local now kc cred_file hermes_lock claude_lock claude_pids hermes_pids notch_pids
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  kc="$(keychain_mdat)"
  cred_file="$(file_meta "$CLAUDE_DIR/.credentials.json")"
  hermes_lock="$(file_meta "$CLAUDE_DIR/.credentials.lock")"
  claude_lock="$(file_meta "$CLAUDE_DIR/.oauth_refresh.lock")"
  claude_pids="$(pids_matching 'claude-code/bin/claude|(^|/)claude($| )')"
  hermes_pids="$(pids_matching 'hermes_cli\.main|Hermes\.app/Contents/MacOS/Hermes')"
  notch_pids="$(pids_matching 'NotchStats\.app/Contents/MacOS/NotchStats')"

  emit "$now | keychain=$kc | file=$cred_file | hermes_lock=$hermes_lock | claude_lock=$claude_lock | pids(claude=$claude_pids hermes=$hermes_pids notchstats=$notch_pids)"
}

emit "# watch-claude-auth.sh started (read-only metadata; no secrets read) claude_dir=$CLAUDE_DIR interval=${INTERVAL}s"

if [ "$ONCE" -eq 1 ]; then
  sample
  exit 0
fi

prev_kc=""
prev_file=""
while true; do
  line="$(sample)"
  # sample already emitted; also flag keychain mdat or file transitions
  kc_now="$(printf '%s' "$line" | sed -n 's/.*keychain=\([^ ]*\).*/\1/p')"
  file_now="$(printf '%s' "$line" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
  if [ -n "$prev_kc" ] && [ "$kc_now" != "$prev_kc" ]; then
    emit "# CHANGE: keychain mdat changed: $prev_kc -> $kc_now"
  fi
  if [ -n "$prev_file" ] && [ "$file_now" != "$prev_file" ]; then
    emit "# CHANGE: .credentials.json changed: $prev_file -> $file_now"
  fi
  prev_kc="$kc_now"
  prev_file="$file_now"
  sleep "$INTERVAL"
done
