# Analytics: what people do with amanu, and the price of knowing

2026-08-22

## Why

Nobody knows how amanu is used. Not how many copies exist, not how many of
them ever get past the setup window, not whether the live transcript is a
feature or a graveyard, not what breaks on other people's machines. Every
decision so far has been made from one person's use and from the issues
strangers were annoyed enough to file, which is a sample of the unhappy.

The three questions worth money are the same three everybody wants: how many
installs, where the first run loses people, and what the working population
actually does afterwards.

## The decision that shapes everything

The obvious privacy-preserving design is anonymous counters — events with no
identifier, funnels reconstructed from one-shot milestones, a weekly snapshot
carrying the state of an install. It works, it is defensible in public, and it
is a lot of machinery.

It was considered and rejected. amanu sends a **persistent random identifier**
and analytics is **on by default**, because the questions above are worth more
than the machinery is, and because the answers are only as good as the sample.

That decision is not free, and the rest of this document is mostly about paying
for it honestly rather than pretending it costs nothing.

### What it costs

**A random UUID tied to a device is personal data.** Pseudonymisation does not
take data out of the GDPR, and an IP address has counted as personal data since
*Breyer*. More sharply: storing the identifier on the machine at all is what
Article 5(3) of the ePrivacy Directive governs — it is about "storing of
information in the terminal equipment", not about cookies specifically, and the
EDPB's 2023 guidelines on its technical scope say so at length. There,
legitimate interest is not a basis; prior consent is. On by default is exactly
the configuration that is hardest to defend in the EU. This is not legal
advice, and it is worth an hour of a lawyer's time before the release that
carries it, not after.

**The reputational exposure is larger than the legal one.** amanu is a meeting
recorder whose README promises that nothing leaves the machine, with public
source and an audience that reads diffs. Audacity in 2021 is the near
precedent: a local audio tool, telemetry on by default, and it cost them two
forks and a month of "spyware" headlines. They had a base large enough to
survive that.

**A behavioural journal accumulates whether or not it was wanted.** With a
permanent identifier the event stream is not a counter, it is "this install
records on weekdays between ten and seven, about three hours a day, and went
quiet for two weeks in July". That is one person's working timetable, so the
analytics host must not retain the network address beside it.

### What is done about it

Four things, none of which are decoration.

The **identifier is disclosed, and so is every event**. `docs/analytics.md`
lists every event name and every property, and a test fails the build if the
code sends anything that is not on that list. That is the difference between a
promise and a fact.

The **switch is visible before it matters** — a checked box in the setup window
on the first run, not a preference buried three tabs deep, and a toggle in
settings afterwards.

**No IP addresses are stored.** Umami uses the address transiently for session
assignment and coarse location, then stores the derived fields rather than the
address. Caddy does not log the address for this site either.

**Nothing is kept for ever.** A year, enforced by a daily PostgreSQL retention
timer for events, properties, identity links, and orphaned sessions.

## What is sent

A permanent identifier is worth having partly because of what it removes:
Umami builds a funnel from the *first* occurrence of each step per person, so
"first recording" and "first transcript" need no events of their own. The list
stays short.

### The first-run funnel

`installed`, `setup_opened`, `mic_granted` or `mic_denied`,
`system_audio_heard` or `system_audio_silent`, `setup_completed` carrying the
setup version, then `recording_started`, `transcript_finished`,
`summary_finished` — the last three are ordinary events that the funnel reads
the first of.

### The routine

`recording_started` carries `trigger`: `manual`, `mic_activity`, `calendar` or
`cli`. That is the answer to whether anyone uses automatic recording, and it
comes free from `RecordingSession.Trigger`, which already distinguishes them.

`recording_finished` carries a bucketed duration, whether the live transcript
was on, and whether the system track had sound. `recording_discarded` fires for
one too short to be a meeting. `transcript_finished` carries the engine,
`summary_finished` the backend.

"How many recordings does a person make" needs no event at all: it is the count
of `recording_finished` per identifier, which is what the identifier bought.

### What breaks

`transcript_failed`, `summary_failed`, `system_track_silent`,
`session_interrupted`. Each carries a `reason` drawn from a closed enumeration.
No error text, ever — error strings carry paths, host names and occasionally
API keys, and there is no way to sanitise them that stays true as the code
changes.

### Settings

`setting_changed` with `key` and `value`, sent from `Config.update` — the one
funnel every write already passes through, so no future setting can be added
and quietly forgotten. Only toggles and fixed choices are reportable. Anything
free-text is off the list by construction: paths, language codes, model names,
app lists, and the key paths.

### The state of an install

Sent as Umami event properties with every event: app version, macOS version,
architecture, interface language, `live_transcription`, `speaker_names`,
`auto_record`, transcription engine, summary backend, `keep_audio`.

This is where "does anyone use the live transcript" and "does anyone touch
diarization" are answered — as a filter over people, with no event needed.

## The client

A new `Sources/amanu/Analytics/`. `Analytics.track(_:_:)` is the whole surface;
when analytics is off it allocates no queue and touches no `URLSession`.

**No SDK.** Umami's batch API is one JSON `POST` to `/api/batch`; the small
sender can be read end to end and checked against the documentation page. Each
event is paired with an `identify` payload carrying the same UUID and timestamp
so Umami links it correctly even when several installs share an address. No
autocapture, cookies, session replay, or browser tracker is present.

The identifier lives in `~/.config/amanu/analytics.json`, beside `setup.json`
and for the reason `SetupState` gives: `config.json` holds decisions a person
made, and a generated UUID is not one. The decision — the switch — does live in
`config.json`, as `"analytics": false`. Settings are only written when they
differ from their default, so somebody who leaves it on never gets a line, and
somebody who turns it off gets one line they can read.

Events buffer in memory, flush on a timer and at exit; what fails to send is
written to disk and retried at the next launch, capped at five hundred events
and seven days, and dropped silently past that. Analytics may not block, may
not delay quitting, and may not fail loudly. A recording is the product;
analytics is a by-product and behaves like one.

The command line reports under the same identifier with `surface: cli`.

`amanu analytics` prints whether it is on and what the identifier is — so
somebody who wants their data deleted can say which data is theirs.

## The server

Umami 3.3.0 and PostgreSQL 16 run by docker compose on `misch` (8 vCPU, 31 GB),
bound to `127.0.0.1:8095`. The existing system Caddy serves
`stats.amanu.me`; its site log filters client addresses. Database, application,
and 2FA secrets are generated on the host and kept out of the repository. The
default Umami administrator password is replaced before the dashboard is made
public.

The image is pinned rather than following `latest`. The database has a named
Docker volume; losing it loses graphs, not recordings or other product data.
The daily systemd timer runs the checked-in retention SQL.

## Testing

The white list test is the important one — it enumerates every allowed event
name and property key and fails if the code sends anything else, which is what
keeps `docs/analytics.md` true. Beside it: that a disabled client builds no
queue and opens no connection, that the queue drops the oldest past its cap,
that a failed send survives a restart, that the body matches the capture API's
shape, and that no free-text setting reaches `setting_changed`.

Nothing here needs a network to test. The sender takes its transport as a
parameter, the way `AssemblyAIEngineTests` already does.

## What is not built

No automated user-facing deletion endpoint — `amanu analytics` prints the
identifier and a person asks. No crash reporting: it is a different problem
with a different answer, and folding it in here would double the disclosure
surface for a question nobody has asked yet.
