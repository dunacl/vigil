#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Regenerates the README screenshots in assets/screenshots/:
#
#   panels-glass.png         six medium panels in Liquid Glass
#   panels-solid-btop.png    the same with solid backgrounds and the btop theme
#   panel-sizes.png          medium, small and extra small panels
#   settings-appearance.png  Settings → Appearance
#
#   tools/screenshots/make-screenshots.sh [output-dir]      (or: make screenshots)
#
# Vigil runs with a scratch layout and settings (your own are untouched) and its
# panels float above your windows for about WAIT seconds (default 240, so the
# graphs have history), ignoring clicks. A gradient backdrop goes behind them and
# only that area is captured: no wallpaper, icons or other windows appear.
# Images are at the main display's scale (2x on Retina). The Terminal needs
# Screen Recording permission (System Settings → Privacy & Security).
#
# Tip: the Top Processes panel shows your busiest processes; quit anything you'd
# rather not publish first.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:-assets/screenshots}
wait_seconds=${WAIT:-240}
here=tools/screenshots

if pgrep -x Vigil >/dev/null; then
    echo "Quit Vigil first: a running copy would show up in the shots." >&2
    exit 1
fi

echo "==> Building"
swift build -c release --product Vigil >/dev/null
work=$(mktemp -d)
vigil_pid=""
backdrops=()
cleanup() {
    [[ -n $vigil_pid ]] && kill $vigil_pid 2>/dev/null
    for pid in $backdrops; do kill $pid 2>/dev/null; done
    defaults delete app.vigil.test >/dev/null 2>&1
    [[ -n $work && -d $work ]] && rm -rf "$work"
}
trap cleanup EXIT INT TERM

# A private copy, so a rebuild meanwhile can't kill the running app.
cp .build/release/Vigil "$work/Vigil"
swiftc -O -o "$work/backdrop" $here/backdrop.swift
swiftc -O -o "$work/windows" $here/windows.swift
python3 -I $here/scene.py "$work/layout.json"
# Scratch settings (used with --layout-file): sensors on, so Thermals shows a temperature.
hex=$(printf '%s' '{"general":{"privateSensors":true}}' | xxd -p | tr -d '\n')
defaults write app.vigil.test VigilSettings -data "$hex"
mkdir -p "$out"

echo "==> Panels (about $wait_seconds s)"
"$work/Vigil" --layout-file "$work/layout.json" >/dev/null 2>&1 &
vigil_pid=$!
sleep 8
# Group the floating panels (window level 3) into scenes (separated by more than 40 pt vertically)
# and add a 40 pt margin: one capture region "x,y,w,h" per scene, top to bottom.
regions=("${(@f)$("$work/windows" | awk -F'\t' '$2 == 3' | sort -t$'\t' -k4,4n | awk -F'\t' '
    function flush() { if (n) printf "%d,%d,%d,%d\n", x0 - 40, y0 - 40, x1 - x0 + 80, y1 - y0 + 80 }
    { x = $3; y = $4; r = $3 + $5; b = $4 + $6
      if (n && y > y1 + 40) { flush(); n = 0 }
      if (!n) { x0 = x; y0 = y; x1 = r; y1 = b; n = 1 }
      if (x < x0) x0 = x; if (r > x1) x1 = r; if (b > y1) y1 = b }
    END { flush() }')}")
if (( ${#regions} != 3 )); then
    echo "Expected 3 panel groups on screen, found ${#regions}: ${regions[*]}" >&2
    exit 1
fi
for region in $regions; do
    "$work/backdrop" ${(s:,:)region} &
    backdrops+=($!)
done
sleep $wait_seconds
names=(panels-glass panels-solid-btop panel-sizes)
for i in 1 2 3; do
    screencapture -x -R "${regions[$i]}" "$out/${names[$i]}.png"
done
kill $vigil_pid $backdrops 2>/dev/null || true
vigil_pid=""
backdrops=()
sleep 2

# Settings in its own run, so the panels above don't inflate Vigil's own numbers.
echo "==> Settings"
"$work/Vigil" --layout-file "$work/settings-layout.json" --preset standard --settings appearance >/dev/null 2>&1 &
vigil_pid=$!
sleep 20
settings=$("$work/windows" | awk -F'\t' '$7 == "Vigil Settings" { print $1; exit }')
if [[ -z $settings ]]; then
    echo "Settings window not found" >&2
    exit 1
fi
screencapture -x -o -l "$settings" "$out/settings-appearance.png"

echo "==> Wrote"
ls -l "$out"/{panels-glass,panels-solid-btop,panel-sizes,settings-appearance}.png
