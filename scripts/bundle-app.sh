#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Builds Vigil.app from the Swift package into dist/.
#
#   scripts/bundle-app.sh            ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

version=${VERSION:-$(sed -nE 's/^## \[([0-9][^]]*)\].*/\1/p' CHANGELOG.md | head -1)}
version=${version:-0.1.0}
build=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
identity=${SIGN_IDENTITY:--}   # "-" = ad-hoc
app=dist/Vigil.app

swift build -c release --product Vigil --arch arm64 --arch x86_64
binary=$(swift build -c release --product Vigil --arch arm64 --arch x86_64 --show-bin-path)/Vigil

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Vigil"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Vigil</string>
    <key>CFBundleIdentifier</key><string>app.vigil.Vigil</string>
    <key>CFBundleName</key><string>Vigil</string>
    <key>CFBundleDisplayName</key><string>Vigil</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright 2026 The Vigil Authors. Apache License 2.0.</string>
</dict>
</plist>
PLIST

if [[ $identity == "-" ]]; then
    codesign --force --options runtime --timestamp=none --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
echo "Built $app ($(du -sh "$app" | cut -f1)), signed with: $identity"
