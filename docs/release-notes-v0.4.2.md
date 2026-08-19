The models are visible now, and can be taken off the disk. The setup window
stopped being slow, for a reason worth reading about. The live transcript gets
out of the way when the meeting ends. And three sentences that yesterday's
Russian had left in English are in Russian now, along with the reason nothing
had noticed them.

## What changed since v0.4.1

- **Models on disk, in Advanced.** What parakeet and the live model each weigh,
  measured rather than quoted, what they come to together, where they are, and
  a **Delete** for each. Deleting one turns off the switch that wanted it —
  otherwise it downloads itself again at the next meeting and the space comes
  straight back. A parakeet version left behind by changing
  `transcription.model` shows up here too, which is the only place it is
  visible at all.
- **The rows say how big the model is** — "downloaded · 461 MB" rather than
  just "downloaded".
- **The setup window is no longer slow.** Clicking a card blocked for a quarter
  of a second while doing nothing: the form was asking macOS about permissions
  it already knew. A click is now 45 ms rather than 265, and the window opens
  in 78 ms rather than 203. The count that explains it: one click redrew the
  form twice, and each redraw asked about the login item, the microphone and
  the calendar six times over — twelve round trips to answer a question whose
  answer cannot change without the person leaving for System Settings and
  coming back.
- **The live transcript folds away when the recording stops.** The window used
  to stay 460 points tall around text nobody was reading until the next
  meeting started. It returns to its own height, and a link in the section
  header brings the text back if you want it. The window's own comment had
  described this behaviour all along — "borrows it while it runs and gives it
  back afterwards" — while the design document promised the opposite. The
  document was the one that was wrong, and it has been corrected.
- **Three sentences were still in English on a Russian Mac**: the labels
  **You** and **Them** above the live transcript, what the menu bar and the
  status window say while a recording is being transcribed, and where a
  speaker's name came from, in the recordings window.
- **A voice is named in the window's language.** Where the recordings window
  showed `me` and `them A` it now says «я» and «они A». The files keep the
  original keys — `transcript.md` and `speakers.json` are unchanged — and
  since it is the letter that tells two voices apart, a line in the window
  still finds its line in the file.

## What looking for them found

Yesterday's translation was checked by a test that builds the setup form in
both languages and reports anything that comes out the same. It missed all
three, and the two reasons are worth naming because they are the kind of hole
that stays open:

- It never walked into the status window at all. The window says almost
  nothing until something is said to it, so the test now drives it through
  every recorder state and every state of the transcription engine, and clicks
  the link to see its second half.
- It compared whole lines. Almost every line in these windows is several
  independent phrases with a separator between them, so an English phrase hides
  behind a translated one beside it and the line as a whole looks translated.
  `manual · 1 turns` against `вручную · реплик: 1` differs completely, which
  is how `manual` survived. The walk splits on the separator and compares
  phrase by phrase now. Compare the smallest thing that is a sentence, not the
  largest thing that is a line.

The menu bar, the application menu and the recordings window were read by eye
and looked complete — which is exactly the assurance that was not enough for
the status window, so they are walked now too.

Two more things turned up there that were not costing anyone anything yet. The
link that shows and hides the transcript is new in this release and would have
shipped in English if nothing had looked. And the date beside a permission row
was formatted by a `static let`, made the first time anything asked and
keeping whatever language was in force at that moment — which is right in a
program that settles its language before it opens a window, and stops being
right the moment anything changes it. On a Russian Mac that date read
correctly; it was a trap that had not sprung. It is built per use now: a
formatter that is right by luck is worth less than one that is right by
construction, and two dates a person opens a window to read are not a rate
worth caching for.

## Honest about what is untested

**Deleting a model has not been done to a real one.** The code is exercised
against temporary directories that the tests create and remove; doing it for
real means erasing more than a gigabyte belonging to whoever runs it, which is
their decision and not something to rehearse on their behalf. The confirmation,
the switch it turns off, and the recalculation are covered by tests.

**Three windows and two menus are walked; the alerts are not.** The setup
form, the status window, the recordings window, the menu bar and the
application menu each go through their states in both languages and report
anything that comes out the same. The two confirmations in the recordings
window cannot be opened from a test without trapping a modal loop. They are
translated, and that was checked by eye — the assurance this release spent
three rounds learning not to trust.

**The application was not launched for this release.** Windows were rendered
off screen and looked at, but no window went through all four combinations:
the setup and settings windows in both appearances, in English; the status and
recordings windows in both languages, in the light one. The timings above were
measured in a signed bundle. Nothing here was clicked in a running copy.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.2-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.2-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.2-macos-universal.dmg`
