#!/bin/zsh
# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Builds a distributable dist/Vigil-<version>.dmg.
#
#   scripts/release.sh
#       Ad-hoc signed DMG for testing. Other Macs will block it (Gatekeeper).
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=vigil scripts/release.sh
#       Signed with Developer ID, notarized by Apple, ticket stapled: opens
#       normally on any Mac. One-time setup for the notary profile:
#         xcrun notarytool store-credentials vigil --apple-id … --team-id … --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${SIGN_IDENTITY:--}
profile=${NOTARY_PROFILE:-}
version=${VERSION:-$(sed -nE 's/^## \[([0-9][^]]*)\].*/\1/p' CHANGELOG.md | head -1)}
version=${version:-0.1.0}

echo "==> Testing"
swift test --quiet

echo "==> Building Vigil.app $version"
VERSION=$version SIGN_IDENTITY=$identity scripts/bundle-app.sh

echo "==> Making the disk image"
dmg=dist/Vigil-$version.dmg
staging=$(mktemp -d)
cp -R dist/Vigil.app "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Vigil $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
rm -rf "$staging"
if [[ $identity != "-" ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
fi

if [[ -n $profile && $identity != "-" ]]; then
    echo "==> Notarizing (this can take a few minutes)"
    keychain=()
    [[ -n ${NOTARY_KEYCHAIN:-} ]] && keychain=(--keychain "$NOTARY_KEYCHAIN")  # CI's temporary keychain
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" "${keychain[@]}" --wait
    xcrun stapler staple "$dmg"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
    echo "==> Skipping notarization (needs SIGN_IDENTITY with a Developer ID and NOTARY_PROFILE)."
    echo "    This DMG is for testing on this Mac; other Macs will refuse to open the app."
fi

shasum -a 256 "$dmg"
echo "Built $dmg ($(du -h "$dmg" | cut -f1))"
