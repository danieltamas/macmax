#!/bin/bash
# Idle cost of the running MacMax app: CPU used over a window (default 60 s, PLAN.md uses 600) and resident
# memory. Budget with the panel closed: under 1 percent of one core. Run it with the panel closed.
set -euo pipefail

cpu_seconds() {
    ps -o time= -p "$1" | awk '{ n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; printf "%.2f", s }'
}

main() {
    local seconds="${1:-60}" pid
    pid="$(pgrep -x MacMax | head -n 1 || true)"
    [[ -n "$pid" ]] || { echo "perf: MacMax is not running" >&2; exit 2; }
    local before after rss
    before="$(cpu_seconds "$pid")"
    sleep "$seconds"
    after="$(cpu_seconds "$pid")" || { echo "perf: MacMax exited" >&2; exit 2; }
    rss="$(ps -o rss= -p "$pid" | tr -d ' ')"
    local average
    average=$(awk -v a="$after" -v b="$before" -v s="$seconds" 'BEGIN { printf "%.2f", (a - b) / s * 100 }')
    echo "perf: pid $pid, ${seconds} s, average CPU ${average}%, resident $((rss / 1024)) MB"
    awk -v a="$average" 'BEGIN { exit (a < 1.0) ? 0 : 1 }' || { echo "perf: over the 1 percent budget" >&2; exit 1; }
}

main "$@"
