#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Where does WindowServer's per-panel cost come from? Runs 6 floating Medium CPU
# panels in several variants and reports the CPU each variant added to
# WindowServer over an idle baseline. Run on an IDLE Mac (no video, no
# scrolling, no animations): other screen activity swamps the signal.
# Takes about 9 minutes.
#
#   scripts/windowserver-ab.sh [previous-build-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
before=${1:-}
seconds=60
warmup=10
swift build -c release --product Vigil >/dev/null
# Run a private copy: if anything rebuilds .build/release/Vigil mid-run (an
# editor, `swift run -c release`), macOS kills the running process for its
# changed code signature, with no crash report.
private=$(mktemp -d)
trap 'rm -rf "$private"' EXIT
cp .build/release/Vigil "$private/Vigil"
app=$private/Vigil

ws_seconds() {
    ps -o time= -p "$(pgrep -x WindowServer)" | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'
}
now() { python3 -c 'import time; print(time.time())'; }

run() {  # label, binary, args...
    local label=$1 binary=$2; shift 2
    local w0 t0 json w1 t1
    w0=$(ws_seconds); t0=$(now)
    json=$($binary --measure --warmup $warmup --seconds $seconds "$@" | tail -1)
    w1=$(ws_seconds); t1=$(now)
    local cpu=$(echo "$json" | sed -E 's/.*"cpuPercent":([0-9.]+).*/\1/')
    printf "%-34s vigil %7s%%   windowserver %6.3f%%\n" "$label" "$cpu" $(echo "($w1 - $w0) / ($t1 - $t0) * 100" | bc -l)
}

w0=$(ws_seconds); t0=$(now); sleep $((seconds + warmup)); w1=$(ws_seconds); t1=$(now)
printf "%-34s %21s %6.3f%%\n" "idle baseline (no Vigil)" "windowserver" $(echo "($w1 - $w0) / ($t1 - $t0) * 100" | bc -l)
run "0 panels" $app --panels 0
[[ -n $before ]] && run "6 glass, previous build" $before --panels 6
run "6 glass" $app --panels 6
run "6 glass, static content" $app --panels 6 --static
run "6 clear glass" $app --panels 6 --material clearGlass
run "6 solid" $app --panels 6 --material solid
run "6 solid, static content" $app --panels 6 --material solid --static
