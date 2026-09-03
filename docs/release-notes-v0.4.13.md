This release prepares Amanu for a wider public launch: it closes two ways a
recording could disappear from view, makes every data transfer explicit, and
puts the repository and website on the same standard as the signed app.

## What changed since v0.4.12

- **Interrupted recordings are visible from the CLI.** `amanu sessions` and
  `amanu process` now recover a recording whose owner died before inspecting
  it, instead of claiming that its folder is not a recording. The recovery
  manifest is written before capture starts, closing the smaller window in
  which audio could exist without a marker.

- **A silently unauthorized system tap is detected during the meeting.** macOS
  can create a healthy-looking process tap that writes digital zero after its
  permission is lost. Amanu now distinguishes that from ordinary quiet and
  posts a warning. The longer far-end silence check also applies when
  `system_audio` is `all`, and `amanu doctor` reports when the last deliberate
  system-audio tone test succeeded.

- **Privacy wording now matches the actual data flow.** Recording and the
  meeting library remain local. Setup, the macOS permission prompt, the README,
  and new English and Russian privacy pages now say plainly that cloud or CLI
  models receive the transcript and available meeting context when selected;
  local Parakeet and Ollama paths stay on the Mac.

- **Analytics can answer lifecycle questions without accepting free text.** A
  versioned schema adds release adoption, settings, capture failures, model
  downloads, transcription fallback, summary fallback, speaker naming, and
  artifact-opening events. Models, outcomes, failure reasons, and artifacts
  are closed allow-lists; private model names and error text cannot enter the
  payload. The site now counts release-link clicks without an identifier.
  Saved Umami funnels and a cross-session weekly digest make the new signals
  usable, while the complete public event catalogue remains enforced by tests.

- **The public surface is ready to share.** The website has Open Graph cards,
  a custom social preview, `robots.txt`, a sitemap, English and Russian privacy
  pages, a strict content-security policy, HSTS, and other defensive headers.
  The repository adds CI, Dependabot configuration, issue templates, security
  reporting, support and contribution notes. Dependency license texts are now
  included inside every application bundle.

- **Dark-mode live speaker labels follow the active appearance.** The labels
  no longer retain a resolved color from the appearance in which the window
  happened to be created; regenerated release screenshots cover both themes
  and both interface languages.

## Honest about what is untested

No live meeting was recorded for this release. The crash paths, CLI recovery,
digital-zero decision, grace period, both system-audio scopes, remembered tone
test, analytics catalogue, window appearance, website, and packaging are
covered by automated tests. A real TCC revocation while a call is in progress
cannot be reproduced inside the test process, so the new warning still needs a
live permission-reset check after installation. Intel hardware was not tested.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.13-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.13-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.13-macos-universal.dmg`
