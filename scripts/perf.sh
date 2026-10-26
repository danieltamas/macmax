#!/bin/bash
# Idle cost of the running MacMax app and its children: CPU used over a window (default 60 s, PLAN.md uses 600) and resident
# memory. Budget with the panel closed: under 1 percent of one core. Run it with the panel closed.
set -euo pipefail

# CPU time of the app plus the children it has already finished with (the short nettop run each tick), from the kernel's
# resource usage: a ps snapshot would miss a child that starts and exits between two readings.
cpu_seconds() {
    python3 - "$1" <<'PY'
import ctypes, struct, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class Timebase(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
base = Timebase(); libc.mach_timebase_info(ctypes.byref(base))
buffer = ctypes.create_string_buffer(512)
if libc.proc_pid_rusage(int(sys.argv[1]), 2, buffer) != 0: sys.exit(1)
fields = struct.unpack_from("<12Q", buffer.raw, 16)  # RUSAGE_INFO_V2 after the 16-byte uuid
ticks = fields[0] + fields[1] + fields[10] + fields[11]  # user, system, child user, child system
print("%.2f" % (ticks * base.numer / base.denom / 1e9))
PY
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
