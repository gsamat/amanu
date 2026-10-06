# Windows audio devices — approved design

Samat approved this design on 6 October 2026. The trigger is Windows 10 feedback:
Amanu recorded the laptop microphone rather than the headset, and omitted the
other side of the call. The diagnosis is not confirmed on that user's hardware.

## Main window

Keep the existing recording status, start/stop and pause controls, automatic
recording checkbox, and live transcript. The Russian live transcript label is
**Расшифровка на лету**.

Between automatic recording and the existing action buttons, add two sections:

1. **Микрофон**: a full-width device dropdown; below it, **Проверить микрофон**
   on the left and **Уровень звука** with a segmented meter on the right.
2. **Звук собеседника**: a full-width output-device dropdown; below it,
   **Проверить звук** on the left and the same level meter on the right.

Both dropdowns contain **Как в Windows (resolved device name)** and the available
physical devices. Persist endpoint IDs rather than display names. Keep a selected
unavailable device visible; never silently select a different microphone.

The four existing full-width buttons stay in their existing order below audio:
**Импортировать…**, **Открыть папку записей**, **Управление записями…**,
**Настройки…**. Keep their existing handlers. Below them is the live transcript.

Samat specifically rejected the extra **Что записывать** control and redundant
audio settings/navigation buttons. Do not add them back. Preserve the native WPF
theme, localized English/Russian strings, keyboard controls and accessibility.
Keep the whole window reachable on a small laptop screen, with scrolling when
needed rather than clipping existing controls.

## Audio behavior

- The saved microphone and output choices must affect actual capture. A change
  during recording resumes the affected track within the same meeting, preserving
  existing audio and timing. The other track continues.
- Automatic selection follows Windows default-device changes. A fixed selection
  must not silently fall back to a laptop microphone/output when disconnected.
  Report device loss and allow replacement through the same dropdowns.
- Silence is not a device failure. Show measured levels for both captured tracks;
  no stale nonzero level after pause, silence, disconnection or stop.
- Checking the microphone without recording temporarily opens it, shows its
  level, and closes it when checking ends or the window hides. No session or
  audio file is created. Checking during a meeting must not interrupt capture.
- Checking output plays a short finite test signal through the selected output
  and shows its captured level. Release playback and preview resources on stop,
  device change, hide and app exit. Do not change the system volume.
- Windows 10 needs a supported endpoint-loopback path. Preserve existing
  `system_audio=app` choices: do not silently broaden an existing automatic
  recording to all audio. If selecting an output or recovering from unsupported
  process capture requires endpoint capture, explicitly explain that music and
  notifications on that device are included and let the user choose. A permission
  failure is not a reason to broaden capture.
- Record interruptions locally with the meeting, so missing audio can be
  explained after capture. Never imply that lost audio has been recovered.

## Implementation and validation

Use a clean checkout of the latest `origin/codex/ready-0.6.3`. Keep this feature
on a separate branch/worktree from the active release in the chat **windows 1**.
Do not modify that chat's checkout, release version, workflows or release channel.
Do not publish a release for this task.

Start with failing regression tests. Cover persisted/reset/invalid device choices,
selected endpoint capture, default changes, pinned-device loss, replacing one
track without truncating either WAV, format/timeline continuity, stale callback
and disposal races, preview teardown, pause/silence meter behavior, and refusal
to silently broaden process capture after failure.

Run the relevant build and tests on the Windows host and inspect the actual WPF
window with Computer Use. Verify microphone preview, selected-device test signal,
real two-track capture and a device change/disconnection using the devices that
are actually available. Clearly report hardware checks that cannot be performed.

## Work prepared on the Mac

The controls and endpoint capture are implemented in this feature branch.
The microphone/output settings are empty-by-default endpoint ID strings,
validated through the existing schema and saved only when different from defaults.
The capture uses a fixed float format so device replacement preserves WAV and
live-stream formats. Device changes and losses are recorded in a local journal.

On macOS, the 145 core tests and 12 audio tests pass. The settings tests, device
switching tests and event-journal test were observed failing before their fixes.
The audio tests use a controlled endpoint factory because WASAPI is Windows-only;
the real recorder, WAV writers, switching logic and level meters are exercised.
The Windows app and Windows UI test assembly cross-compile without warnings.
A Windows-only UI regression checks that both selectors and test buttons coexist
with all four existing actions, and that the window can scroll on small screens.
`windows-audio-validation.yml` runs builds and all three test projects on Windows
without signing, packaging or publishing anything.

The Windows host's real audio capture, test signal, device loss/replacement and
actual rendered interface are still unverified. The chat **windows 1** is busy
releasing another version. The requested chat **windows 2** was not visible in
the available chat list during implementation; no message was sent to windows 1.
