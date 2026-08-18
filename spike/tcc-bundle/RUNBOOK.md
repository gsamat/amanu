# System-audio attribution spike — runbook

## The question

`.issues/rca-002` proved two things about the *bare binary*: run from a shell it
gets correctly clocked, digitally silent tap buffers, and run by `launchd` it
captures. It never tested a signed **application bundle**. The native-app design
(`docs/superpowers/specs/2026-08-18-native-macos-app-design.md`, "Architecture
decision gate") cannot proceed until someone measures two launches:

1. `AmanuSpike.app` started from **Finder / LaunchServices**.
2. The same bundle started by **`SMAppService.mainApp`** after a real login.

Both must report **NON-ZERO SAMPLES**. If either says DIGITAL SILENCE, the design
takes its documented fallback: an embedded LaunchAgent via
`SMAppService.agent(plistName:)`.

The spike carries bundle id `me.samat.amanu.spike` — **not** `me.samat.amanu` —
so nothing here consumes, resets, or disturbs the grants the real program holds.

## What it does on each launch

Plays a 440 Hz tone through the default output device, taps all system audio for
five seconds, and reports packets, samples, share of non-zero samples, peak and
RMS, plus its bundle id, parent pid, and **responsible pid** — the process TCC
attributes the tap to. Everything goes to
`~/Library/Logs/amanu-spike/run-<stamp>.log` (with the captured audio beside it
as `.caf`) and into an alert with three buttons: **Done**, **Register/Unregister
login item**, **Reveal log**.

No system audio needs to be playing; the tone is its own source, and a global tap
sees every process including this one. Output volume does not matter — the tap
reads the mix before hardware volume, so even a muted Mac should produce non-zero
samples. Play a video too if you want a second signal.

## Preconditions

- macOS 15 or later, Apple Silicon.
- The Developer ID keychain (`~/.local/bin/unlock-signing-keychain` exists).
- About ten minutes, one of which is a logout/login.

## Step 1 — build and sign

```sh
sh spike/tcc-bundle/build.sh
```

Builds `spike/tcc-bundle/build/AmanuSpike.app`, signs it Developer ID with
hardened runtime, `--timestamp`, and the audio-input entitlement, then prints
`codesign --verify --strict` and `spctl`.

`spctl` says **`rejected — source=Unnotarized Developer ID`**. That is expected
and irrelevant: the bundle is not notarized because it is never distributed.
Gatekeeper is not what the spike measures. `codesign --verify --strict` must say
*valid on disk* and *satisfies its Designated Requirement* — that is the part
that matters, because TCC keys the grant to that signature.

The script only builds and signs. It launches nothing.

## Step 2 — install where LaunchServices can see it

```sh
cp -R spike/tcc-bundle/build/AmanuSpike.app /Applications/
```

Required, not cosmetic:

- `tccutil` resolves bundle ids **through LaunchServices**; an app it does not
  know returns `OSStatus -10814` (rca-002 hit exactly this with the bare binary).
- `SMAppService.mainApp` records the path at registration time, so the bundle
  must already be where it will live.
- Copying locally leaves no `com.apple.quarantine` attribute, so there is no
  "unidentified developer" dialog and no app translocation. If one appears
  anyway, check `xattr -l /Applications/AmanuSpike.app` and open it once with
  right-click → **Open**.

## Step 3 — clear the way

Stop the existing amanu LaunchAgent so nothing else is holding a tap or a
recording indicator while you measure:

```sh
launchctl bootout gui/$UID/me.samat.amanu
```

(Bring it back in the rollback section.)

Then clear any previous decision **for the spike's own id**. On a first run there
is nothing to clear and it is a no-op; on a re-run it is what makes the prompt
appear again:

```sh
tccutil reset ScreenCapture me.samat.amanu.spike
tccutil reset AudioCapture  me.samat.amanu.spike   # the "System Audio Recording Only" list
```

Process taps are gated on the system-audio-capture service, which macOS surfaces
as **System Audio Recording Only** — a Screen Recording grant does not confer it
(rca-002). Different macOS builds accept one service name or the other; run both
and ignore an "unknown service" complaint from whichever is not supported. Never
run a service-wide `tccutil reset ScreenCapture` with no bundle id: that revokes
every other app on the machine.

## Step 4 — branch A, Finder launch

1. Double-click `/Applications/AmanuSpike.app` in Finder.
2. Expect a prompt naming **AmanuSpike**: *"AmanuSpike" would like to record
   this computer's screen and audio* (or *…record your system audio*). Approve
   it. macOS may ask you to quit and reopen the app — do that, and the second
   launch is the measured one.
3. Read the alert. The first line is the verdict.

A prompt that never appears is itself a result: it is the rca-002 signature of a
process being judged on someone else's identity. Check the `responsible pid` line
in the log — for a healthy bundle it must be the spike's own pid, marked
`[self]`.

Record: verdict, non-zero %, peak, and the responsible-pid line.

## Step 5 — branch B, login item

1. In the alert click **Register login item**. Confirm the follow-up says
   *Registered as a login item* (status `enabled`; `requires approval` means
   go to System Settings → General → Login Items and enable it).
2. Click **Done** to quit.
3. **Log out and log back in.** A reboot works too. Do not just relaunch — the
   point is that `launchd` starts the process at login.
4. After login the spike runs by itself and shows its alert. If you miss it:

```sh
ls -t ~/Library/Logs/amanu-spike/ | head
cat ~/Library/Logs/amanu-spike/$(ls -t ~/Library/Logs/amanu-spike | head -1)
```

5. Confirm in that log that `parent pid` is **1** — otherwise you measured
   another Finder launch, not the login item.

## Step 6 — reading the result

| Finder | Login item | Meaning |
|---|---|---|
| NON-ZERO | NON-ZERO | **Gate passes.** One normal application process; **Start at login** registers `SMAppService.mainApp`; no LaunchAgent ships. |
| either DIGITAL SILENCE | | **Fallback.** Embedded LaunchAgent via `SMAppService.agent(plistName:)`, launching the same executable inside the bundle. Note *which* branch failed and what its responsible pid was — that is the evidence the fallback rests on. |
| NO BUFFERS, or a `FAILED` verdict | | Not an attribution result at all: the tap or aggregate device errored, with an OSStatus in the log. Fix that first and re-run. |

"DIGITAL SILENCE" means well-formed packets arrived and every sample in them was
zero — an unauthorized tap, not a broken audio graph. "NON-ZERO SAMPLES" with the
tone playing should land somewhere near 100 % non-zero and a peak in the −20 dB
range; anything above 0 % settles the question.

Sanity-check the audio if you like: `afinfo ~/Library/Logs/amanu-spike/run-*.caf`
or `afplay` it — you should hear the tone.

Then record the numbers in the spec's decision gate before writing any app code.

## Rollback

Order matters: reset TCC **before** deleting the bundle, or `tccutil` can no
longer resolve the id.

```sh
# 1. Remove the login item — the alert's "Unregister login item" button, or:
#    System Settings → General → Login Items → Open at Login.

# 2. Forget the spike's permission decisions.
tccutil reset ScreenCapture me.samat.amanu.spike
tccutil reset AudioCapture  me.samat.amanu.spike

# 3. Delete the bundle.
rm -rf /Applications/AmanuSpike.app
rm -rf spike/tcc-bundle/build

# 4. Bring the real LaunchAgent back.
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/me.samat.amanu.plist

# 5. Optional — the logs are the evidence, keep them until the spec is updated.
rm -rf ~/Library/Logs/amanu-spike
```

After step 2 the spike disappears from System Settings → Privacy & Security →
Screen & System Audio Recording / System Audio Recording Only. Nothing here ever
touches `me.samat.amanu`, so the shipping program's grants are untouched
throughout.
