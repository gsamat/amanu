# Releasing amanu

Written for whoever ships the next one — most likely an agent, working alone,
at night, with nobody to ask. It is the runbook, not the design; the design is
in `docs/specs/2026-08-18-native-macos-app-design.md`, and the
mechanism is `scripts/release.sh`, which is commented.

Read the whole page before starting. Half of it is about failures, and the
failures are the part that costs hours.

## What a release is

Three artefacts, in this order of importance:

1. **The appcast**, `https://samat.me/amanu/appcast.xml`. This is what every
   installed copy reads once a day. It is the release as far as existing users
   are concerned; the GitHub page is for strangers.
2. **The disk image** on the GitHub release, which the appcast points at.
   Signed with Developer ID, hardened runtime, notarized, ticket stapled.
3. **The GitHub release page**, with the image and its checksum attached.

The appcast is served from `reina:/var/www/samat/amanu/` and tracked in the
`gsamat/samatme3` repository at `amanu/appcast.xml`. It is tracked there on
purpose: the site's own deploy uses `rsync --delete`, and an untracked
server-only file would be erased the next time somebody publishes the site.

## Before you start

Everything the release needs lives outside this repository. Check all of it
first — the script does too, but knowing what it is asking for saves a
diagnosis later.

| What | Where | If it is missing |
|---|---|---|
| Sparkle private key | `~/.appstoreconnect/amanu-sparkle-ed25519.key` | **Stop.** See *The key with no spare* below. |
| Notarization key | `~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8` | Same key the iOS projects use. |
| ASC ids | `.env.asc` in the repo root, gitignored | Copy one from any iOS project; they are all the same account. |
| Developer ID certificate | `~/Library/Keychains/developer-id.keychain-db` | `~/.local/bin/unlock-signing-keychain`; `make app` runs it already. |
| `gh`, authenticated | account `gsamat` | `gh auth status` |
| `ssh reina` | passwordless | this is where samat.me is served from |
| Site checkout | `~/Documents/проекты/samatme3`, on `main`, pushed | the script refuses otherwise |

## Doing it

```sh
# 1. Decide the version. Edit VERSION in the Makefile if this is not a rebuild.
# 2. Write the notes. The file name must match the tag exactly.
$EDITOR docs/release-notes-v0.3.0.md
# 3. Commit and push. The release refuses to run from a dirty tree.
git add -A && git commit && git push origin master
# 4. Rehearse. This notarizes for real but publishes nothing.
make release-dry
# 5. Ship.
make release
```

`VERSION` in the Makefile is the marketing version and the tag. The build
number is `git rev-list --count HEAD` and only ever goes up; Sparkle compares
build numbers, so two releases must never be built from the same commit.

Release notes are Markdown, and `scripts/notes-to-html.py` turns them into the
HTML shown inside Sparkle's window. It understands headings, bullets, links,
`code` and **bold**, and *refuses* anything else — fenced code blocks and
indented blocks make it exit rather than quietly ship mangled prose. Keep to
what it knows.

## The stages, and what a failure in each one means

The script runs eight stages and stops at the first failure. That ordering is
the whole design: **nothing is public until stage 8**, so a failure anywhere
before it costs time and nothing else. Do not "helpfully" reorder them.

1. **Tests.** `swift test`. Fix the tests.
2. **Build and sign.** `make app`. If codesign fails with
   `errSecInternalComponent`, the signing keychain relocked — run
   `~/.local/bin/unlock-signing-keychain`. Do not go looking at certificates:
   `security find-identity` shows the certificate as valid even when the
   private key is locked away, because it never touches the key.
3. **Verify the signature.** Identity, designated requirement, hardened
   runtime. A failure here almost always means nested code was signed in the
   wrong order — see *Signing order* below.
4. **Disk image.** `Amanu.app` plus an `/Applications` symlink, signed.
5. **Notarize.** Two to five minutes. `status: Accepted` is required; anything
   else, read `dist/notary.log`, and if it is unhelpful ask the notary service
   directly with `xcrun notarytool log <submission-id>`. Then staple, validate,
   and ask Gatekeeper for its own opinion.
6. **Draft the GitHub release.** Created as a **draft**, assets uploaded. If
   the tag already has a *published* release, the script stops and tells you to
   bump the version — replacing something people have already downloaded is not
   a thing it will do for you.
7. **Sign the appcast.** EdDSA over the exact bytes of the disk image, written
   into the site checkout. On a dry run it goes to `dist/appcast.xml` instead,
   so a rehearsal never leaves a signed feed pointing at a release that does
   not exist.
8. **Publish.** The GitHub release stops being a draft; then the appcast is
   committed, pushed and rsynced to reina; then the script fetches the live
   feed and compares it byte for byte with what it signed, and asks GitHub for
   the asset to confirm it answers 200.

If stage 8 fails *after* the GitHub release went public, nothing is broken:
installed copies keep reading the previous feed, the download works for anyone
who has the link, and re-running deployment is safe.

## Rules that are not negotiable

- **Never hand-edit `amanu/appcast.xml`.** The signature covers a specific
  file. Change a byte and every installed copy silently refuses the update —
  silently, because a failed signature check is exactly what the mechanism is
  supposed to do about a tampered feed.
- **Never publish the feed before the asset.** Between the two, every running
  copy that checks is downloading a 404.
- **Never force a release over a published one.** Ship a higher build instead.
  An update that has already installed somewhere cannot be recalled.
- **Never put the private key anywhere the repository can see it.**

## The key with no spare

`~/.appstoreconnect/amanu-sparkle-ed25519.key` is a base64 Ed25519 seed, mode
0600. Its public half is `SUPublicEDKey` in `Packaging/Amanu-Info.plist`, and
every copy of amanu in the world trusts exactly that key.

**Lose it and no existing installation can ever be updated again.** A new key
means a new `SUPublicEDKey`, which only reaches people who install a fresh
build by hand — which is the thing updates exist to avoid. Back it up wherever
the Developer ID material is backed up, and treat it with the same care.

It is not in the login keychain and was never generated by Sparkle's
`generate_keys`. Sparkle's own `sign_update --ed-key-file` reads this format,
which is why the release script never needs the keychain and never raises a
key-access dialog mid-build.

## Signing order

`codesign` seals what it finds. Sign the app first and the framework second and
the app's own seal is invalid — but `codesign --verify` on this machine may
still pass, and the failure surfaces as a Gatekeeper rejection on somebody
else's Mac. `make app` signs innermost first:

    Sparkle.framework/Versions/B/Autoupdate
    Sparkle.framework/Versions/B/Updater.app
    Sparkle.framework
    Amanu.app

Sparkle's `XPCServices` are deleted before signing. They exist so a *sandboxed*
app can download and install; amanu is not sandboxed, so they would be two more
binaries to sign, notarize and ship for nothing.

## Traps that have already cost time

- **`gh` picks a remote by itself.** This checkout has an `upstream` pointing
  at the project amanu was forked from, and the first release attempt tried to
  publish there. Every `gh` call in the script names `--repo`. Keep it that
  way, and do the same in anything you add.
- **`grep -q` in a pipeline under `set -o pipefail`.** `grep -q` exits at its
  first match, the writer takes a SIGPIPE, and a passing check reads as a
  failing one. The script captures command output into a variable and greps
  that. Do not "simplify" it back into a pipe.
- **The dirty-tree check is not bureaucracy.** The build number is stamped from
  the commit count, so a release built with uncommitted changes claims to be a
  commit it is not, forever, in a number the updater compares.
- **A running copy does not die when you delete its bundle.** Quit Amanu before
  replacing `/Applications/Amanu.app`, or the survivor keeps answering the
  doorbell the new copy is ringing.

## Afterwards

Verify as a stranger would, from a clean directory:

```sh
curl -fsSLO https://github.com/gsamat/amanu/releases/download/vX.Y.Z/amanu-vX.Y.Z-macos-arm64.dmg
curl -fsSLO https://github.com/gsamat/amanu/releases/download/vX.Y.Z/amanu-vX.Y.Z-macos-arm64.dmg.sha256
shasum -a 256 -c amanu-vX.Y.Z-macos-arm64.dmg.sha256
xcrun stapler validate amanu-vX.Y.Z-macos-arm64.dmg
spctl --assess --type open --context context:primary-signature -v amanu-vX.Y.Z-macos-arm64.dmg
```

Then verify the update itself, which is the only check that exercises the whole
chain at once. Keep an older build installed, or reinstall one, and use **Check
for updates…** from either menu. It should find the new version, show the
release notes rendered as HTML, download, verify, install and relaunch. If it
finds nothing, the build number did not go up. If it finds the update and then
refuses it, the feed and the asset disagree — re-sign and redeploy the feed.

Finally, tell `docs/HANDOFF.md` what changed. The next person starts there.
