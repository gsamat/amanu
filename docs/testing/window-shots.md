# Seeing the windows

`Tests/amanuTests/WindowShots.swift` renders every window amanu has to PNG
files, and writes a listing of where every view in the setup window ended up.
It asserts nothing. It exists because the defects these
windows produce are not the kind a test catches: a label whose descenders sit
on the hairline below it, a border still painted in the appearance the Mac has
left, two rows nobody thought to compare that came out different heights. Each
of those was found by rendering the window and looking at it.

```sh
mkdir -p /tmp/shots && AMANU_SHOTS=/tmp/shots swift test --filter 'Window(Shots|Gallery)'
```

Two suites live in that file. `WindowShots` is the diagnostic one — the setup
and settings windows at the wrong sizes on purpose, and through a change of
appearance. `WindowGallery` is the other errand: the status window and the
recordings window, which produce no layout defects and so were never in the
first suite, plus the setup window at the exact height of its own form. Filter
to one of them by name when only one is wanted; the two write into the same
directory.

The directory has to exist: the suite writes into it rather than creating it,
so a first run without the `mkdir` fails on the first PNG.

`AMANU_SHOTS_LANGUAGE=ru` builds the windows in Russian instead. Everything
else about the run is the same, filenames included, so give it a directory of
its own:

```sh
mkdir -p /tmp/shots-en /tmp/shots-ru
AMANU_SHOTS=/tmp/shots-en swift test --filter 'Window(Shots|Gallery)'
AMANU_SHOTS_LANGUAGE=ru AMANU_SHOTS=/tmp/shots-ru swift test --filter 'Window(Shots|Gallery)'
```

`AMANU_SHOTS` both switches the suite on and says where to write; without it
`swift test` skips the whole thing, which is why it can live in the test target
without lengthening the suite. It is in the test target because that is the only
place that can see `SetupWindow` and `SettingsWindow`: they are internal, and
making them public so a command-line tool could open them would be widening the
program to suit its instruments.

## What comes out

| File | What it is |
| --- | --- |
| `setup-{light,dark}-window.png` | The setup window at 700×760, the size a person gets. |
| `setup-{light,dark}-full.png` | The same at 700×1600 — taller than the form, which is where anchoring mistakes show. |
| `setup-switched-to-dark.png`, `setup-switched-back-to-light.png` | One window built in light and handed to the other appearance and back. |
| `settings-setup-{light,dark}.png` | The settings window's first tab: the same form in another window. |
| `settings-advanced-{light,dark}.png` | The Advanced tab, and `-narrow` at the minimum width the window allows. |
| `settings-advanced-{light,dark}-bottom.png` | The same tab scrolled to its end, which is the only picture the models-on-disk block appears in. |
| `settings-setup-switched-*.png` | The settings window through the same change of appearance. |
| `about-{light,dark}.png` | The About window, which sizes itself to its words — so this pair is where a Russian line that outgrew the width would show. |
| `setup-{light,dark}-whole.png` | The setup window closed onto its own form: the whole screen, one image, no scrollbar and no empty band. This is the one to show somebody. |
| `status-idle-{light,dark}.png` | The status window as it sits all day. |
| `status-recording-{light,dark}.png` | The same window recording, with the live transcript that borrows its height. |
| `recordings-{light,dark}.png` | The recordings window over four sessions made for the picture — finished, waiting, refused, and one whose names are half filled in — with the newest selected so the detail half is not blank. |
| `tree.txt` | Every view in the setup window with its frame, in window coordinates. |

## How to read them

**The switched pictures are the point of the exercise.** A layer colour is a
resolved number rather than a living rule (`docs/pitfalls.md`, *A `CGColor` is a
number, not a colour*), so a window can go on wearing the appearance it was born
in. Compare each `*switched*` file against the file for the appearance it ended
in: they should be **identical to the pixel**. Any difference is that bug.

**Compare the two languages against each other, not against yesterday.**
Russian runs about a fifth longer than English, and the labels in these
windows have both a wrapping width and a line limit: past the limit a row
either truncates or grows and pushes everything under it down. Neither shows
in one picture — a row looks like a row. The pair from one run shows it at
once, and the two `tree.txt` files settle it: every frame in the two listings
should match, and a row that has grown is a translation to shorten rather than
a line limit to raise.

**Do not read a switch's state off a picture.** An `NSSwitch` is drawn by
SwiftUI and comes out in the off position offscreen whatever it is set to. Every
switch in these files looks off. `tree.txt` reports the real state, and it is
the only place to read it.

**Measure in `tree.txt`, not with your eyes.** Rows are wrong by two or three
points at a time, which is exactly the range where looking is unreliable and a
frame is not. A row's insets are the gap between its own frame and the frame of
the words inside it.

**The tab picker at the top of the settings window comes out as a white
rectangle.** It draws itself in a way `cacheDisplay` does not reach. Nothing
else in these files does that, so it is the one thing to ignore rather than
report.

Everything else in a picture is real, including the background: a plain view
painted in `windowBackgroundColor` goes in behind the form for the length of the
exposure, because `cacheDisplay` renders views and not the window under them,
and a dark window without that comes out as white text on nothing.

## What they cannot tell you

The pictures show this Mac, now. Which permissions are granted, which keys are
present, whether the local model is downloaded — all of it is read from the
machine, and all of it changes what the window says and how tall its rows are.
Two runs on different days differ for reasons that are not the code. When
comparing across commits, compare runs taken close together, and check
`tree.txt` before concluding that a layout moved.

**The recordings window is posed, and the rest are not.** Its four sessions are
written into a folder of its own for the exposure and deleted afterwards —
these files get shown to people, and the real recordings folder is full of the
names of actual meetings. Everything else in these pictures is this Mac saying
what is true about it.

**A download in progress is not among the states it can take.** The local
model's row grows a progress bar and swaps its size for a running count while
parakeet is being fetched, and that is a layout worth a picture — but the tool
cannot pose it. The windows own their form privately, so nothing here can reach
the switch's seams to say "no model, and this is how to pretend to fetch it";
the bar would read zero anyway, because it is the cache directory's size and a
pretended download writes no bytes; and by the rule above, the switch that
started it comes out looking off whatever it is set to. Seeing that row mid-
download means turning the switch on in the real window with no model on the
Mac, which is also the only way to see it at all.

Which is why no picture from this tool belongs in the repository as a
reference to compare against: it would be a picture of one machine on one day,
and it would disagree with the next machine for reasons nobody could act on.
The tool is here; its output is not. If these ever run unattended, the
comparison to make is two runs on the same machine — before a change and after
it — never a run against a file in git.
