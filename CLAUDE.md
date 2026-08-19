# amanu

A local-first meeting recorder for macOS. One SwiftPM package that is both the
application and its command line; `make app` wraps the binary in `Amanu.app`.

## Start here

- `docs/pitfalls.md` — the constraints that are not visible from the code that
  depends on them, and the places believed correct on reasoning alone. Read it
  before changing anything about signing, the bundle, or where keys live.
- `.issues/` — what is known to be wrong, `status:` in the frontmatter. The
  `rca-*` files are post-mortems and worth reading for the failure modes even
  where they are closed.
- `docs/releasing.md` — how to cut a release. **Read it in full before running
  `make release`.** Publishing is one command, and the failures are all in the
  parts that are not.
- `docs/specs/2026-08-18-native-macos-app-design.md` — the design,
  including the places the code deliberately went its own way.
- `docs/old-macs.md` — what runs on Intel and on older macOS, what sets each
  limit, and which of it has actually been measured. Read it before answering
  any question that starts "does amanu work on…".

## Working on it

```sh
make app                                 # build + sign .build/Amanu.app
cp -R .build/Amanu.app /Applications/    # replace the installed copy
swift test                               # 197, of which 3 only run for shots
```

Quit the running app before replacing `/Applications/Amanu.app` — deleting a
bundle does not stop the process using it, and the survivor answers the
doorbell the new copy is ringing.

Audio paths can only be tested by making a recording by hand. Everything else
is covered by tests, and `docs/testing/setup-window-manual-checklist.md` covers
the setup window — most of it can be driven from a script, and the items that
genuinely need a person are marked. Before changing that window, read
`docs/testing/window-shots.md`: it renders both windows to PNG in both
appearances, and every layout defect this project has found was found by
looking at one.

## Two standing decisions

- **The Unix socket is cancelled.** The interface is the distributed-
  notification doorbell (`SetupRequest`, `RecordRequest`, `SingleInstance`) plus
  the `~/.local/bin/amanu` symlink into the bundle. If something seems to need
  structured IPC, that is a new argument to make, not a plan to finish.
- **The bundle is assembled by `make app`**, not by an Xcode target. A second
  build system would have to be kept in step with the first.

## Commit messages

One prose sentence saying what changed and, where it is not obvious, why —
imperative or declarative, no `feat:`/`fix:` prefixes, no bullet lists in the
subject. A body is welcome when the reason is worth more than the diff. Read
`git log` before writing one; the voice is consistent and it is meant to be.

Comments in the code follow the same rule: they explain why, in full sentences.
