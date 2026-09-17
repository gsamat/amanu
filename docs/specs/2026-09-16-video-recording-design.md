# Optional video recording

Design for the third track: what a meeting looks like on screen, recorded next
to the two audio tracks that were already there. Shipped as `video.*` settings,
the **Record video** / **Start recording with video** items in the feather's
menu, `video.mp4` in the session folder, and the background `meeting.mp4`.

## The one architectural decision, and the proposal it rejects

The proposal this started from unified media ingestion under one `SCStream`
carrying both audio and video. **That part is rejected.** Amanu's audio capture
is a Core Audio process tap plus `AVAudioEngine`, and both carry scar tissue the
proposal would discard:

- Voice processing must survive capture restarts (`docs/pitfalls.md`, rca-003 —
  a raw restart once put the far end at −3 dB on our own track).
- Silence pads belong after the attach, or every buffer after a restart is
  written 0.37 s early, permanently.
- The mic follows route changes and the call app's own device; neither is
  something an `SCStream` audio tap does.

So the video stream is **video-only** (`capturesAudio = false`). Audio stays
exactly where it is. One meeting still produces independent artifacts in one
folder; video is a third track, not a replacement container — and when the
picture fails, the meeting is still recorded.

## What a session looks like

```
yyyy.MM.dd-HHmm Title/
  .recording.json   (manifest, unchanged)
  mic.caf           (unchanged)
  system.caf        (unchanged)
  video.mp4         (new, only when video ran)
  meeting.mp4       (new, when the merge ran)
  meta.json         (gains the keys below)
```

`meta.json` additions, written by `stop()`:

```json
{
  "video": "video.mp4",
  "video_capture": "window",
  "video_start_offset_ms": 240,
  "video_frames_dropped": 3
}
```

`video` is deliberately a **top-level key, not an entry in `files`**.
`TranscriptionCoordinator.SessionMeta` reads `files["mic"]` and `files["system"]`
by name, so a new `files` entry would be harmless today — but that dict is the
transcription contract, and a video is not a transcript input. Keeping video out
of it costs nothing and removes a way for a future `files` consumer to ingest an
MP4 as audio.

Only a *finished* video is named: a file deleted for having no frames, or one
lost to a writer that never sealed, must not be promised in a folder whose
whole job is to say what happened. The session state carries the rest —
`merged`, `merge_failed`, `raw_video_removed` — and `SessionInventory` turns
that plus the files on disk into the recordings table's Video column.

## Where the picture comes from

Two ways, and the second one exists because the first is a guess:

**The automatic pick** (`video.capture: window`, the default) is the meeting
window owned by one of the call-app families — the same family rule the
system-audio tap follows, so the two tracks stay pointed at the same call.
A candidate is on screen, on the normal window layer, larger than a pixel, and
owned by a family. Preference is the app's own active window first, then area,
then window id: activity first because a launcher that opened before the meeting
used to win on size alone and record the wrong half of the call. No candidate
means the main display, and `video_capture` records which was chosen. The pick
is re-run every watchdog tick (15 s) while recording, so a launcher captured at
the start gives way to the meeting window when it opens; the stream's filter is
swapped in place, so the file stays one recording with one timeline.

**The system picker** (`SCContentSharingPicker`, macOS 14+) is what the menu
opens, by hand, before or during a meeting. A call app has a launcher, a meeting
window, a toolbar and a chat panel in one family, and no heuristic outside Apple
can say which of them somebody means — so the question goes to the person, in
the same UI screen sharing uses. It excludes amanu's own bundle id (recording
the person watching amanu), and it stays available while the picture runs: the
next selection it delivers re-points the same stream in place, through
`SCStream.updateContentFilter`, and the session log records that it changed.

## The writer's contract

- **The first frame decides the size.** A writer built on a guess dies later
  with the encoder refusing every frame (`-16122`), taking the whole video with
  it. So the file's dimensions are the first buffer's, scaled down to
  `video.height` at most and never up.
- **Frames that cannot go in are dropped and counted**, not fed to the encoder:
  a stream lifecycle event or a static gap (anything but `SCFrameStatus.complete`
  or without an image buffer), and a frame in another size than the file's — the
  shape a re-picked window can deliver. `video_frames_dropped` says how many.
- **Pause is a jump cut.** Frames are dropped while paused; the stream keeps
  running and timestamps do not shift.
- **The file is sealed at stop**, synchronously — a recording is not stopped
  until its file is playable — with a 15 second ceiling on `finishWriting`. A
  video with nothing in it is cancelled and deleted rather than left as a husk
  that reads as a recording, and `failureNote` says why in the session log.
- H.264 at 30 fps, cursor included, ~2.5 Mbps at 1080p scaled by area and
  floored at 800 kbps. H.264 rather than HEVC because Intel Macs without Quick
  Sync must not be asked to software-encode HEVC.

## The merged file

A second decision taken while building: each video session also gets
`meeting.mp4` — the picture with both audio sides on one stereo track — built in
the background after the recording stops, so there is one file to send someone.
It is deliberately two pieces the program already trusts: the audio is
`TrackCompressor.encodeStereo` (the same mix `keep_audio` archives), and the
picture is **remuxed, not re-encoded** — `AVAssetReader` → `AVAssetWriter` with
the source's `sourceFormatHint` for passthrough. `AVAssetExportSession` is
avoided outright: it is documented in `AudioMixer` as the thing that triggers
Photos and Music TCC prompts in this app.

The sources are never deleted by the merge: the audio stays the durable
artifact and `video.mp4` stays the silent original, unless `video.remove_raw`
says otherwise — and that only ever happens after the merge threw nothing.

## Settings

| key | default | what it decides |
|---|---|---|
| `video.start_automatically` | off | every recording also records video |
| `video.capture` | `window` | the meeting window, or the main display |
| `video.height` | 1080 | a ceiling on the picture, never an upscale |
| `video.merge_audio` | on | write `meeting.mp4` after the recording |
| `video.remove_raw` | off | delete `video.mp4` once it has been merged |

`video.enabled` from the draft did not survive: a switch that means "video by
itself" and a menu item that means "video now" are different questions, and one
key answering both would have made the menu item write config.

## Failure modes, stated up front

- **A crash loses the video, always.** AVAssetWriter has no fragmented-movie
  mode; without `finishWriting` there is no moov atom and the MP4 is
  unplayable. The audio CAFs remain the durable artifact, crash recovery
  ignores `video.mp4`, and the README says the video is best-effort.
- **Permission denied mid-meeting** (revoked in System Settings): the stream
  delivers nothing. Delivery of frames is the test, not
  `CGPreflightScreenCaptureAccess` — the preflight has been seen to answer no on
  a Mac whose pane says yes. So a start that produces no frames within five
  seconds is stopped, announced once, and the audio carries on.
- **No meeting window found**: the main display, with `video_capture` saying so.
- **Intel**: `SCStream` and H.264 work; on a Mac without hardware encode the
  encoder costs real CPU. Not measured yet — `docs/old-macs.md` gains a
  paragraph when it is, and this paragraph is the promise that it will.

## Testing

- `VideoWindowPicker`'s choice is pure data in, target out — family match,
  on-screen and layer rules, activity over size, display fallback — so it is
  tested with no TCC grant at all.
- The writer is tested by feeding generated `CMSampleBuffer`s, including the
  sizes and statuses a real stream sends when a window is re-picked: a frame in
  another size must cost one frame and not the file.
- The merge is tested end to end on manufactured bytes: a finalized video, two
  PCM tracks with an offset, and assertions on the file that comes out.
- A real capture needs a person. `docs/testing/live-pass.md` § C2 is that
  checklist: the grant, the right window, the follow, the hand-started paths,
  pause, the display fallback, and a `kill -9` that must cost the video and
  spare the audio.
