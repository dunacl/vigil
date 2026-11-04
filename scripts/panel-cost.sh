#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Panel cost (SPEC §2.1, §6): Vigil's footprint and CPU with 0, 1, 6 and 12
# floating (always visible) Medium CPU panels at the default 2 s interval.
# Per-panel cost = difference between rows. Takes about 5 minutes.
#
# The WindowServer column is the CPU WindowServer used during the run; it is
# only meaningful on an otherwise idle Mac (other apps dominate it).
#
#   scripts/panel-cost.sh [measure-seconds] [warmup-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."
seconds=${1:-60}
warmup=${2:-10}
swift build -c release --product Vigil >/dev/null
# Run a private copy: if anything rebuilds .build/release/Vigil mid-run (an
# editor, `swift run -c release`), macOS kills the running process for its
# changed code signature, with no crash report.
private=$(mktemp -d)
trap 'rm -rf "$private"' EXIT
cp .build/release/Vigil "$private/Vigil"
app=$private/Vigil

# WindowServer CPU time in seconds (ps prints [[dd-]hh:]mm:ss.cc).
ws_seconds() {
    ps -o time= -p "$(pgrep -x WindowServer)" | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'
}

printf "%6s %12s %10s %14s\n" panels footprintMiB "cpu%" "windowserver%"
for panels in 0 1 6 12; do
    ws_before=$(ws_seconds)
    start=$(date +%s.%N 2>/dev/null || python3 -c 'import time; print(time.time())')
    json=$($app --measure --panels "$panels" --warmup "$warmup" --seconds "$seconds" | tail -1)
    end=$(date +%s.%N 2>/dev/null || python3 -c 'import time; print(time.time())')
    ws_after=$(ws_seconds)
    ws_percent=$(echo "($ws_after - $ws_before) / ($end - $start) * 100" | bc -l)
    footprint=$(echo "$json" | sed -E 's/.*"footprintMiB":([0-9.]+).*/\1/')
    cpu=$(echo "$json" | sed -E 's/.*"cpuPercent":([0-9.]+).*/\1/')
    printf "%6s %12s %10s %14.3f\n" "$panels" "$footprint" "$cpu" "$ws_percent"
done
