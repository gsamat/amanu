#!/bin/sh
# Build and sign AmanuSpike.app. It only builds and signs — nothing is
# launched, copied to /Applications, registered, or reset. RUNBOOK.md says who
# does what next.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"
app="$out/AmanuSpike.app"
identity=${SIGN_ID:-"Developer ID Application: Samat Galimov (47B25GR8V2)"}

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# macOS 15 is the floor the native app targets, and it is also the floor for
# the tap APIs this measures.
swiftc -O \
    -target arm64-apple-macos15.0 \
    -o "$app/Contents/MacOS/AmanuSpike" \
    "$here/main.swift" \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework ServiceManagement

# The Developer ID private key lives in its own keychain, which relocks itself.
# Without this, codesign fails with errSecInternalComponent while
# find-identity still cheerfully lists the certificate — it reads the
# certificate and never touches the key.
if [ -x "$HOME/.local/bin/unlock-signing-keychain" ]; then
    "$HOME/.local/bin/unlock-signing-keychain"
else
    echo "warning: $HOME/.local/bin/unlock-signing-keychain missing;" \
         "codesign may fail with errSecInternalComponent" >&2
fi

# --options runtime because that is what the shipped app will carry, and TCC
# treats a hardened, Developer ID-signed bundle as a stable identity — the
# whole point of the measurement. --timestamp for the same reason the Makefile
# uses it: the signature outlives the certificate.
codesign --force \
    --sign "$identity" \
    --identifier me.samat.amanu.spike \
    --options runtime \
    --timestamp \
    --entitlements "$here/AmanuSpike.entitlements" \
    "$app"

echo
codesign --verify --strict --verbose=2 "$app"
echo
codesign -dvvv --entitlements - "$app" 2>&1 | grep -Ev '^(Executable=|Format=|CodeDirectory v|Hash|CandidateCD|Page size|Sealed|Internal req|default$)'
echo
# Not notarized, so this is expected to say "rejected ... Unnotarized Developer
# ID". Gatekeeper is not what the spike measures; TCC attribution is.
spctl -a -vv "$app" || true
echo
echo "built: $app"
