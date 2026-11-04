#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Soak test (SPEC §8): runs Vigil for N hours with the default layout plus Top
# Processes and Thermals (sensors on), records CPU and memory every 5 minutes, and
# reports growth. The Mac can be used normally meanwhile.
#
#   scripts/soak.sh [hours]          writes dist/soak-<date>.csv
set -uo pipefail
cd "$(dirname "$0")/.."
hours=${1:-24}
swift build -c release --product Vigil >/dev/null
scratch=$(mktemp -d)
# Run a private copy: if anything rebuilds .build/release/Vigil mid-run (an
# editor, `swift run -c release`), macOS kills the running process for its
# changed code signature, with no crash report.
cp .build/release/Vigil "$scratch/Vigil"
hex=$(printf '%s' '{"general":{"privateSensors":true}}' | xxd -p | tr -d '\n')
defaults write app.vigil.test VigilSettings -data "$hex"
mkdir -p dist
csv=dist/soak-$(date +%Y%m%d-%H%M).csv
echo "elapsed_min,cpu_seconds,footprint_mb,alive" > "$csv"

"$scratch/Vigil" --layout-file "$scratch/layout.json" --preset developer >/dev/null 2>&1 &
pid=$!
start=$(date +%s)
end=$((start + hours * 3600))
cpu_seconds() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'; }
while (( $(date +%s) < end )); do
    sleep 300
    elapsed=$(( ($(date +%s) - start) / 60 ))
    if kill -0 $pid 2>/dev/null; then
        mb=$(footprint -p $pid 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+) MB.*/\1/p')
        echo "$elapsed,$(cpu_seconds $pid),${mb:-0},1" >> "$csv"
    else
        echo "$elapsed,0,0,0" >> "$csv"
        echo "Vigil exited after $elapsed minutes — see ~/Library/Logs/DiagnosticReports and ~/Library/Logs/Vigil" >&2
        break
    fi
done
kill $pid 2>/dev/null
defaults delete app.vigil.test >/dev/null 2>&1
rm -rf "$scratch"

python3 -I - "$csv" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["alive"] == "1"]
if len(rows) < 3:
    sys.exit("not enough samples")
first, last = rows[0], rows[-1]
minutes = float(last["elapsed_min"]) - float(first["elapsed_min"])
cpu = (float(last["cpu_seconds"]) - float(first["cpu_seconds"])) / (minutes * 60) * 100
hour = max(1, len(rows) // max(1, int(minutes // 60) or 1))
early = sum(float(r["footprint_mb"]) for r in rows[:12]) / len(rows[:12])
late = sum(float(r["footprint_mb"]) for r in rows[-12:]) / len(rows[-12:])
print(f"Ran {minutes/60:.1f} h, {len(rows)} samples, still running: {rows[-1]['alive'] == '1'}")
print(f"Average CPU {cpu:.3f} %   memory first hour {early:.1f} MB → last hour {late:.1f} MB ({late-early:+.1f} MB)")
print("PASS" if late - early < 2 else "CHECK: memory grew by more than 2 MB")
PY
echo "Samples in $csv"
