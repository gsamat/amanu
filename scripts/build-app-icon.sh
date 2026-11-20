#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: build-app-icon.sh <adaptive.icon> <fallback.icns> <output-dir> <minimum-macos>" >&2
    exit 2
fi

ADAPTIVE_ICON=$1
FALLBACK_ICON=$2
OUTPUT_DIR=$3
MINIMUM_MACOS=$4

test -f "$ADAPTIVE_ICON/icon.json" || {
    echo "adaptive icon is missing: $ADAPTIVE_ICON/icon.json" >&2
    exit 1
}
test -f "$FALLBACK_ICON" || {
    echo "classic icon is missing: $FALLBACK_ICON" >&2
    exit 1
}

# A local code-only build can reuse the catalog from a trusted installed app.
# This is explicit, never an automatic fallback that could hide stale artwork
# in a release. The ordinary path below still compiles the adaptive icon.
if [ -n "${AMANU_PREBUILT_ICON_RESOURCES:-}" ]; then
    PREBUILT=$AMANU_PREBUILT_ICON_RESOURCES
    test -s "$PREBUILT/Assets.car" || {
        echo "precompiled Assets.car is missing or empty" >&2
        exit 1
    }
    cmp -s "$FALLBACK_ICON" "$PREBUILT/Amanu.icns" || {
        echo "precompiled icon does not match the current classic icon" >&2
        exit 1
    }
    mkdir -p "$OUTPUT_DIR"
    cp "$PREBUILT/Assets.car" "$OUTPUT_DIR/Assets.car"
    cp "$FALLBACK_ICON" "$OUTPUT_DIR/Amanu.icns"
    echo "reusing precompiled icons from $PREBUILT (explicit local build)"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/amanu-app-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/compiled" "$OUTPUT_DIR"

xcrun actool \
    --compile "$WORK/compiled" \
    --platform macosx \
    --minimum-deployment-target "$MINIMUM_MACOS" \
    --app-icon Amanu \
    --output-partial-info-plist "$WORK/partial.plist" \
    "$ADAPTIVE_ICON" >/dev/null

test -s "$WORK/compiled/Assets.car" || {
    echo "actool did not produce Assets.car" >&2
    exit 1
}

# Assets.car gives Tahoe and later the layered appearance variants. Keep the
# hand-tuned classic icon beside it instead of actool's flattened fallback, so
# Sonoma and Sequoia retain the exact icon they already know.
cp "$WORK/compiled/Assets.car" "$OUTPUT_DIR/Assets.car"
cp "$FALLBACK_ICON" "$OUTPUT_DIR/Amanu.icns"
