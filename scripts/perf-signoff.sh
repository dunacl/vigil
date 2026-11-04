#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Release performance sign-off (SPEC §6): measures both reference layouts against
# the budgets and prints PASS/FAIL. Run on an IDLE Mac (no video, scrolling or
# typing): WindowServer numbers are meaningless otherwise. About 12 minutes.
#
#   scripts/perf-signoff.sh [seconds-per-scenario]
set -uo pipefail
cd "$(dirname "$0")/.."
seconds=${1:-90}
warmup=15
swift build -c release --product Vigil >/dev/null && swift build -c release --product vigil-probe >/dev/null
scratch=$(mktemp -d)
# Run a private copy: if anything rebuilds .build/release/Vigil mid-run (an
# editor, `swift run -c release`), macOS kills the running process for its
# changed code signature, with no crash report.
cp .build/release/Vigil "$scratch/Vigil"
app=$scratch/Vigil
defaults delete app.vigil.test >/dev/null 2>&1  # default settings for every run
pkill -x Vigil 2>/dev/null; sleep 1

ws_seconds() { ps -o time= -p "$(pgrep -x WindowServer)" | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'; }
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'; }
now() { python3 -c 'import time; print(time.time())'; }
results=()
check() {  # name, value, budget, unit
    local verdict=PASS
    (( $(echo "$2 > $3" | bc -l) )) && verdict=FAIL
    results+=("$(printf '%-44s %8.3f %-3s  budget ≤ %-6s %s' "$1" "$2" "$4" "$3" "$verdict")")
}

# Idle WindowServer baseline (no Vigil).
w0=$(ws_seconds); t0=$(now); sleep $seconds; w1=$(ws_seconds); t1=$(now)
baseline=$(echo "($w1 - $w0) / ($t1 - $t0) * 100" | bc -l)
results+=("$(printf '%-44s %8.3f %%' "WindowServer idle baseline (no Vigil)" "$baseline")")
idle=1
if (( $(echo "$baseline > 3" | bc -l) )); then
    idle=0
    results+=("WARNING: the Mac wasn't idle (baseline > 3 %); WindowServer rows are unreliable. Re-run when idle.")
fi

measure() {  # label, budget-cpu, budget-ws, budget-mb, args...
    local label=$1 cpu_budget=$2 ws_budget=$3 mb_budget=$4; shift 4
    rm -f "$scratch/layout.json" "$scratch/layout.json.bak"
    $app --layout-file "$scratch/layout.json" "$@" >/dev/null 2>&1 &
    local pid=$!
    sleep $warmup
    local a=$(cpu_seconds $pid) w0=$(ws_seconds) t0=$(now)
    # Idle wakeups (as Activity Monitor counts them) during the measurement.
    local wakeups=$(top -l 2 -s $seconds -pid $pid -stats pid,idlew | awk -v p=$pid '$1 == p { w = $2 } END { print w + 0 }')
    if ! kill -0 $pid 2>/dev/null; then
        # Never report numbers computed from a process that's gone.
        results+=("$label: FAIL — Vigil exited during the measurement (quit, killed or crashed; check ~/Library/Logs/DiagnosticReports)")
        return
    fi
    local b=$(cpu_seconds $pid) w1=$(ws_seconds) t1=$(now)
    local mb=$(footprint -p $pid 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+) MB.*/\1/p')
    kill $pid; wait $pid 2>/dev/null; sleep 2
    local elapsed=$(echo "$t1 - $t0" | bc -l)
    check "$label: Vigil CPU" "$(echo "($b - $a) / $elapsed * 100" | bc -l)" "$cpu_budget" "%"
    if [[ -n $ws_budget ]]; then
        if (( idle )); then
            check "$label: WindowServer added" "$(echo "($w1 - $w0) / $elapsed * 100 - $baseline" | bc -l)" "$ws_budget" "%"
        else
            results+=("$(printf '%-44s %8s %-3s  budget ≤ %-6s %s' "$label: WindowServer added" "—" "%" "$ws_budget" "NOT MEASURED (Mac busy)")")
        fi
    fi
    [[ -n $mb_budget ]] && check "$label: memory" "${mb:-0}" "$mb_budget" "MB"
    check "$label: wakeups" "$(echo "${wakeups:-0} / $seconds" | bc -l)" "0.6" "/s"
}

measure "Default layout, visible" 0.3 0.3 40 --preset standard
desktops=$($app --list-spaces 2>/dev/null | grep -c "Desktop ")
if (( desktops > 1 )); then
    measure "Default layout, on another desktop" 0.05 "" "" --preset standard --desktop 2
else
    results+=("Default layout, on another desktop: skipped (needs a second desktop in Mission Control)")
fi
measure "btop preset (solid)" 0.8 0.8 60 --preset btop

# Sampling path (all collectors incl. processes).
p95=$(.build/release/vigil-probe --only cpu,memory,network,disk,volumes,processes --bench 2000 | sed -nE 's/tick p95 +([0-9.]+) ms.*/\1/p')
check "Sampling tick p95 (all collectors)" "$p95" 2 "ms"
size=$(du -sk dist/Vigil.app 2>/dev/null | cut -f1)
[[ -n $size ]] && check "App bundle size" "$(echo "$size / 1024" | bc -l)" 8 "MB"

echo
printf '%s\n' "${results[@]}"
rm -rf "$scratch"
print -l "${results[@]}" | grep -q FAIL && exit 1 || exit 0
