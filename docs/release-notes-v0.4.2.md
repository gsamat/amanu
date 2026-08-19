The models are visible now, and can be taken off the disk. The setup window
stopped being slow, for a reason worth reading about. The live transcript gets
out of the way when the meeting ends. And the Russian that shipped yesterday
had five holes in it, which are closed — along with the reason nothing had
noticed them.

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
  header brings the text back if you want it. The design document had been
  promising the new behaviour for a while; the code was doing the other thing.
- **Five things were still in English on a Russian Mac**: the labels **You**
  and **Them** above the live transcript and the link that shows and hides it;
  what the menu bar says while a recording is being transcribed; where a
  speaker's name came from, in the recordings window; and the date beside a
  permission row in setup.

## What looking for them found

Yesterday's translation was checked by a test that builds the setup form in
both languages and reports anything that comes out the same. It missed all
five, and the two reasons are worth naming because they are the kind of hole
that stays open:

- It never walked into the status window at all. The window says almost
  nothing until something is said to it, so the test now drives it through
  every recorder state and every state of the transcription engine, and clicks
  the link to see its second half.
- It compared the transcript as one block of text. One translated separator
  inside the block made the whole block differ between the languages, and the
  English speaker labels hid behind it. It reads line by line now. Comparing
  whole blocks gives a false "translated", and that is the part to remember.

The menu bar, the application menu and the recordings window were read by eye
and looked complete — which is exactly the assurance that was not enough for
the status window, so they are walked now too. That turned up three more, and
the same shape of hole a third time: `manual · 1 turns` against
`вручную · реплик: 1` differs as a whole, so the English word hid behind the
translated one beside it. The walk now splits on the separator and compares
phrase by phrase, and two of the three only appeared once it did.

The date was the odd one. It was formatted by a `static let`, made the first
time anything asked and keeping whatever language was in force at that moment
— which happens to be right in a program that settles its language before it
opens a window, and would stop being right the moment anything changed it. A
formatter that is correct by luck is worth less than one that is correct by
construction, and two dates a person opens a window to read are not a rate
worth caching for.

## Honest about what is untested

**Deleting a model has not been done to a real one.** The code is exercised
against temporary directories that the tests create and remove; doing it for
real means erasing more than a gigabyte belonging to whoever runs it, which is
their decision and not something to rehearse on their behalf. The confirmation,
the switch it turns off, and the recalculation are covered by tests.

**Four windows are walked; the alerts are not.** The two confirmations in the
recordings window cannot be opened from a test without trapping a modal loop.
They are translated, and that was checked by eye — the assurance this release
spent three rounds learning not to trust.

**The application was not launched for this release.** The windows were
rendered off screen in both languages and both appearances and looked at, and
the measurements above were taken in a signed bundle — but nothing here was
clicked in a running copy.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.2-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.2-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.2-macos-universal.dmg`
