#!/usr/bin/env bash
# Measures a process's true CPU usage over a window, in % of one core.
# usage: scripts/cpu.sh <pid> [seconds]
set -euo pipefail
PID="$1"
SECS="${2:-5}"

read_t() { ps -o time= -p "$PID" | tr -d ' '; }

to_seconds() {
  awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }' <<<"$1"
}

A="$(read_t)"
A_S="$(to_seconds "$A")"
sleep "$SECS"
B="$(read_t)"
B_S="$(to_seconds "$B")"

awk -v a="$A_S" -v b="$B_S" -v s="$SECS" \
  'BEGIN { printf "cpu: %.1f%% over %ss  (rss: ", (b-a)/s*100, s }'
ps -o rss= -p "$PID" | awk '{ printf "%.1f MB )\n", $1/1024 }'
