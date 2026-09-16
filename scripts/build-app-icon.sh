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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/amanu-app-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/compiled" "$OUTPUT_DIR"

# actool ships with Xcode only, not with the Command Line Tools. A machine
# building locally with CLT alone still gets the classic icon; what it loses
# is only the layered appearance variants for Tahoe and later.
if xcrun --find actool >/dev/null 2>&1; then
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
else
    echo "actool unavailable (Command Line Tools only) — shipping the classic icon without Assets.car" >&2
fi
cp "$FALLBACK_ICON" "$OUTPUT_DIR/Amanu.icns"
