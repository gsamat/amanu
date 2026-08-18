#!/usr/bin/env bash
#
# Release amanu: one command, fail-closed.
#
# The stages run in the order below and a failure in any of them prevents
# every later one. That ordering is the whole design. Nothing is public until
# stage 8: the GitHub release is created as a draft, and the appcast — the
# file that actually tells installed copies an update exists — is deployed
# last, after the download it points at is already reachable. Do it the other
# way round and every running copy of amanu spends the gap downloading a 404.
#
#   scripts/release.sh                 build, notarize, publish
#   scripts/release.sh --dry-run       everything except publishing
#
# What it needs, all of which lives outside this repository:
#   ~/.appstoreconnect/amanu-sparkle-ed25519.key   the Sparkle private key
#   ~/.appstoreconnect/private_keys/AuthKey_*.p8   notarization
#   .env.asc                                       ASC key and issuer ids
#   gh, authenticated as the owner of gsamat/amanu
#   ssh reina                                      where samat.me is served

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Named explicitly: this checkout also has an `upstream` remote pointing at the
# project amanu was forked from, and gh picks a remote on its own — which meant
# the first release attempt tried to publish into somebody else's repository.
REPO="gsamat/amanu"
VERSION=$(sed -n 's/^VERSION *?= *//p' Makefile)
BUILD=$(git rev-list --count HEAD)
TAG="v$VERSION"
DMG="dist/amanu-$TAG-macos-arm64.dmg"
VOLNAME="amanu $VERSION"
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")"
SPARKLE_KEY="$HOME/.appstoreconnect/amanu-sparkle-ed25519.key"
SPARKLE_BIN=$(find .build/artifacts/sparkle -type d -name bin 2>/dev/null | head -1)
SITE="$HOME/Documents/проекты/samatme3"
NOTES="docs/release-notes-$TAG.md"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$SPARKLE_KEY" ] || die "no Sparkle signing key at $SPARKLE_KEY"
[ -f .env.asc ] || die "no .env.asc — copy one from an iOS project"
[ -f "$NOTES" ] || die "no release notes at $NOTES"
# shellcheck disable=SC1091
. ./.env.asc
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[ -f "$ASC_KEY" ] || die "no notarization key at $ASC_KEY"

# A release built from a dirty tree cannot be reproduced from its own tag, and
# the build number it stamps into the bundle is a lie about which commit it is.
[ -z "$(git status --porcelain)" ] || die "working tree is dirty"

step "1/8  tests"
AMANU_NO_NOTIFY=1 swift test 2>&1 | tail -3

step "2/8  building and signing $VERSION (build $BUILD)"
make app

step "3/8  verifying the signature"
codesign --verify --deep --strict --verbose=2 .build/Amanu.app
# Captured rather than piped: `grep -q` closes the pipe on its first match,
# codesign takes a SIGPIPE for it, and under `set -o pipefail` a successful
# check then reads as a failed one.
DETAILS=$(codesign -dvvv .build/Amanu.app 2>&1)
REQUIREMENT=$(codesign -d -r- .build/Amanu.app 2>&1)
grep -E 'Identifier|Authority=Developer ID|TeamIdentifier' <<<"$DETAILS"
grep -q 'me.samat.amanu' <<<"$REQUIREMENT" \
    || die "designated requirement does not name me.samat.amanu"
# The hardened runtime is not optional: without it the notary service rejects
# the submission, and it does so after the upload rather than before it.
grep -q 'flags=.*runtime' <<<"$DETAILS" || die "hardened runtime missing"

step "4/8  building the disk image"
rm -rf dist/stage "$DMG"
mkdir -p dist/stage
cp -R .build/Amanu.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -volname "$VOLNAME" -srcfolder dist/stage \
    -ov -format UDZO -quiet "$DMG"
rm -rf dist/stage
codesign --force --sign "$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')" \
    --timestamp "$DMG"

step "5/8  notarizing"
xcrun notarytool submit "$DMG" \
    --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --timeout 30m | tee dist/notary.log
grep -q 'status: Accepted' dist/notary.log || die "notarization was not accepted"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# Gatekeeper's own opinion, which is the one a stranger's Mac will ask for.
GATEKEEPER=$(spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1)
grep -q 'accepted' <<<"$GATEKEEPER" || die "Gatekeeper rejected the disk image: $GATEKEEPER"

shasum -a 256 "$DMG" | sed "s|dist/||" > "$DMG.sha256"
SIZE=$(stat -f%z "$DMG")
SHA=$(cut -d' ' -f1 < "$DMG.sha256")
echo "  $(basename "$DMG") · $((SIZE / 1024 / 1024)) MB · $SHA"

step "6/8  drafting the GitHub release"
if [ "$DRY_RUN" = 1 ]; then
    echo "  (dry run: skipping)"
else
    # Re-running the script is normal; clobbering a release people have
    # already downloaded is not. A draft is ours to replace, a published one
    # is not.
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        [ "$(gh release view "$TAG" --repo "$REPO" --json isDraft -q .isDraft)" = "true" ] \
            || die "$TAG is already published — bump VERSION in the Makefile"
        gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag=false
    fi
    git tag -f "$TAG"
    git push -q origin "$TAG" --force
    gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO" \
        --draft --title "amanu $TAG" --notes-file "$NOTES"
fi

step "7/8  signing the appcast"
SIGNATURE=$("$SPARKLE_BIN/sign_update" -p --ed-key-file "$SPARKLE_KEY" "$DMG")
mkdir -p "$SITE/amanu"
PUBDATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
NOTES_HTML=$(python3 scripts/notes-to-html.py "$NOTES")
cat > "$SITE/amanu/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>amanu</title>
        <link>https://samat.me/amanu/appcast.xml</link>
        <description>Updates for amanu, a local-first meeting recorder for macOS.</description>
        <language>en</language>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$NOTES_HTML]]></description>
            <enclosure
                url="$ASSET_URL"
                sparkle:version="$BUILD"
                sparkle:shortVersionString="$VERSION"
                sparkle:edSignature="$SIGNATURE"
                length="$SIZE"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
XML
xmllint --noout "$SITE/amanu/appcast.xml" || die "the appcast is not well-formed"
echo "  signed $VERSION (build $BUILD) → $SITE/amanu/appcast.xml"

if [ "$DRY_RUN" = 1 ]; then
    step "dry run: stopping before anything becomes public"
    exit 0
fi

step "8/8  publishing"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
# Only now, with the download live, does the feed start pointing at it.
git -C "$SITE" add amanu/appcast.xml
git -C "$SITE" commit -q -m "amanu $VERSION in the appcast" || true
git -C "$SITE" push -q
rsync -az "$SITE/amanu/" reina:/var/www/samat/amanu/

step "verifying what the world now sees"
curl -fsS https://samat.me/amanu/appcast.xml > dist/published-appcast.xml
diff -q "$SITE/amanu/appcast.xml" dist/published-appcast.xml \
    || die "the published feed is not the file we signed"
ASSET_HEAD=$(curl -fsSIL "$ASSET_URL")
grep -qE '^HTTP/[0-9.]+ 200' <<<"$ASSET_HEAD" \
    || die "the release asset the feed points at is not downloadable"
echo
echo "amanu $TAG is out."
echo "  https://github.com/$REPO/releases/tag/$TAG"
echo "  https://samat.me/amanu/appcast.xml"
