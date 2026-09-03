# What amanu sends, and how to stop it

Every event and every field below is the complete list. Not "the main ones" —
the complete list. `AnalyticsCatalogueTests` fails the build if the program
sends anything that is not on this page, which is what lets that sentence
stand without hedging.

## The short version

**On by default.** Turn it off in the setup window, in Settings → Setup, or
with `amanu analytics off`.

**Never sent, under any setting:** the recordings, the transcripts, the
summaries, the names of meetings or of the people in them, calendar contents,
file paths, folder names, API keys, error text, or your address. Umami uses the
address transiently to form a session and derive coarse location, but does not
store it; Caddy removes it from this site's access log too.

**Kept for a year**, then deleted.

**Sent to** `stats.amanu.me`, which is an Umami instance on a machine we run.
No third party is involved.

This page describes analytics sent by the Amanu application. The separate
[privacy notice](../PRIVACY.md) also describes meeting-content providers and
the first-party page-view counter on `amanu.me`.

## What it is for

Nobody knew how amanu was being used: how many copies exist, how many people
get past the setup window, whether the live transcript is a feature or a
graveyard, what breaks on machines nobody here owns. Every decision was being
made from one person's use and from the complaints of the few strangers
annoyed enough to write in.

## The identifier

A random UUID, made on the first run, kept for good. It is in
`~/.config/amanu/analytics.json` and `amanu analytics` prints it.

On the wire, each event is paired with Umami's `identify` message carrying the
same UUID. That message adds no event or content of its own; it prevents two
installs behind one shared address from being counted as the same person.

This is the part with a cost, and it is worth stating plainly rather than
burying: with a permanent identifier the events are not a counter, they are a
history of one machine's use of amanu over time. That is why the list below is
short, why nothing on it names anything you recorded, and why the address is
discarded rather than stored.

To be forgotten on the server, quote your identifier and ask. To be forgotten
locally, `rm ~/.config/amanu/analytics*.json` — the next run starts as a
stranger.

The argument for all of this, including what was rejected, is in
[the design](specs/2026-08-22-analytics-design.md).

## The events

| Event | When | Fields |
|---|---|---|
| `installed` | the first run on this machine | — |
| `version_seen` | the first run of each packaged amanu version | — |
| `setup_opened` | the setup window appeared | — |
| `settings_opened` | Settings appeared | — |
| `setup_completed` | it was finished | `setup_version` |
| `mic_granted` | microphone allowed, when amanu asked | — |
| `mic_denied` | microphone refused, when amanu asked | — |
| `system_audio_heard` | the system-audio test made a round trip | — |
| `system_audio_silent` | it did not | `reason` when the tap was refused |
| `recording_started` | a recording began | `trigger` |
| `recording_start_failed` | capture could not begin | `trigger`, `component`, `reason` |
| `recording_finished` | it ended and `meta.json` was written | `trigger`, `duration_bucket`, `live_used`, `system_audio` |
| `recording_discarded` | too short to have been a meeting | `trigger`, `duration_bucket` |
| `transcript_finished` | a transcript was written | `engine`, `model`, `fallback_used` |
| `transcript_failed` | transcription gave up or deferred | `engine`, `model`, `reason`, `outcome` |
| `transcript_fallback` | auto moved a failed cloud transcript to the local engine | `from_engine`, `to_engine`, `reason` |
| `summary_finished` | a summary was written | `backend`, `model` |
| `summary_backend_failed` | one summary backend failed before the next was tried | `backend`, `model`, `reason` |
| `summary_failed` | no backend produced a summary | `backend`, `reason`, `outcome` |
| `speaker_names_finished` | a model pass wrote speaker-name results | `backend`, `model` |
| `speaker_names_failed` | no backend produced speaker-name results | `backend`, `model`, `reason`, `outcome` |
| `model_download_started` | a local speech-model download began | `asset` |
| `model_download_finished` | that model became ready | `asset` |
| `model_download_failed` | the download failed or was incomplete | `asset`, `reason` |
| `artifact_opened` | a recordings window or folder was opened from amanu | `artifact` |
| `system_track_silent` | a recording over a minute long whose system track never carried sound | `duration_bucket` |
| `session_interrupted` | a recording recovered after a crash | `trigger`, `duration_bucket` |
| `setting_changed` | a setting on the reportable list changed | `key`, `value` |

Every event also carries `surface`, which is `app` or `cli`.

## The fields

| Field | Values |
|---|---|
| `surface` | `app`, `cli` |
| `trigger` | `manual`, `mic-activity`, `calendar` |
| `duration_bucket` | `under_5m`, `5_15m`, `15_30m`, `30_60m`, `1_2h`, `over_2h` |
| `live_used` | true or false |
| `system_audio` | true or false — whether the far end was ever heard |
| `engine` | the transcription engine's name |
| `backend` | the summary backend's name |
| `model` | a known public model name, or `default`, `custom`, `custom-local`, `unknown` |
| `fallback_used` | true or false |
| `from_engine`, `to_engine` | `assemblyai`, `openai`, `parakeet`, or `auto` when selection failed before an engine existed |
| `component` | `system_audio`, `microphone`, or `unknown` |
| `outcome` | `deferred` or `gave_up` |
| `asset` | `parakeet-v2`, `parakeet-v3`, or `nemotron-live` |
| `artifact` | `recordings_window`, `recordings_root`, or `session_folder` |
| `reason` | `no_network`, `no_key`, `no_model`, `usage_limit`, `audio_missing`, `audio_too_short`, `refused`, `timed_out`, `http_error`, `quit`, `unknown` |
| `setup_version` | which version of the setup window was completed |
| `key` | a setting name, from the reportable list below |
| `value` | that setting's new value, or `default` when it was cleared |

Durations are buckets and not numbers on purpose: an exact meeting length is a
fingerprint, and no question anybody asked needs one.

`reason` is a closed list, again on purpose. The underlying error text is
written to the session log on your machine and never travels — error strings
carry paths, host names and occasionally an API key, and there is no way of
sanitising them that stays true as the code changes.

Model names are closed in the same way. The transcript and local logs keep the
exact model as provenance, but analytics sends only public models amanu knows.
An unrecognised cloud or fine-tuned model becomes `custom`; an unrecognised
Ollama model becomes `custom-local`. Registry namespaces and arbitrary config
text never travel.

## Which settings are reportable

Toggles and fixed choices only. That is a rule, not a list, so it covers
settings added later: a value that can only be *on*, *off*, or one of a
handful of named options carries nothing about you.

Everything else is excluded by its own shape — the recordings folder, the
meeting language, your name, the call-app list, model names, every key-file
path, and every number. The analytics switch itself is also never reported:
sending an event because somebody just turned reporting off would be
indefensible whatever it taught us.

## What is attached to the install

Resent with every event, so it is never stale:

`analytics_schema_version`, `app_version`, `macos_version`, `arch`,
`interface_language`, `live_transcription`, `speaker_names`, `auto_record`,
`transcription_engine`, `transcription_enabled`,
`transcription_cloud_provider`, `summary_backend`, `summary_enabled`,
`speaker_names_backend`, `keep_audio`.

This is how "does anyone use the live transcript" and "does anyone touch
diarization" get answered without an event of their own.

## Where it goes and when

Events buffer in memory and go every thirty seconds, on quitting, and at the
next launch for whatever did not get through. What fails to send is held in
`~/.config/amanu/analytics-pending.json` for at most seven days and at most
five hundred events, then dropped. Turning analytics off deletes that file
along with everything in it.

The server runs a daily retention job that removes events, properties,
identifier links, and orphaned sessions once they are a year old.
