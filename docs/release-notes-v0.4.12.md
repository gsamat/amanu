This release adds transparent, anonymous product analytics and makes the first
launch from the disk image finish the installation instead of leaving Amanu on
a temporary volume.

## What changed since v0.4.11

- **Anonymous usage statistics are visible and optional.** A final switch in
  first-run setup, also available on the Setup tab in Settings, controls the
  feature and starts on. Amanu uses a random installation UUID to count how
  often features are used and where workflows fail.

- **Meeting content is never analytics data.** Recordings, transcripts,
  summaries, calendar contents, names, paths, API keys, device names, and error
  text are excluded. The complete event and property list is public in the
  repository, and `amanu analytics forget` replaces the local UUID.

- **Analytics stays first-party.** Events go to the self-hosted Umami service
  at `stats.amanu.me`. Unsent events are bounded and expire after seven days;
  the server removes stored statistics after one year.

- **Opening the disk image now offers to install Amanu.** A copy running from
  the read-only image asks to move itself into Applications before registering
  a login item, creating the CLI link, or enabling updates. Replacing an older
  installation is staged so an interrupted copy cannot leave half an app.

- **The update feed now lives with the product.** New builds read the signed
  Sparkle appcast from `amanu.me`. A byte-identical compatibility feed remains
  at the old `samat.me` address so every existing installation can cross onto
  the new URL.

## Verification

The full automated suite covers the analytics queue and whitelist, the setup
switch and its default, moving and replacing the application bundle, both
appcast locations, and the landing-page download links. The public Umami
endpoint was also exercised through HTTPS and checked against its PostgreSQL
rows before the diagnostic event was removed.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.12-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.12-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.12-macos-universal.dmg`
