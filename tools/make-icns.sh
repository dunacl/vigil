#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
# Renders the icon and builds assets/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swift tools/make-icon.swift "$work/1024.png" >/dev/null
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o assets/AppIcon.icns
cp "$work/1024.png" assets/AppIcon-1024.png
rm -rf "$work"
echo "Built assets/AppIcon.icns ($(du -h assets/AppIcon.icns | cut -f1))"
