import Foundation

/// Everything amanu reports about how it is used, listed once.
///
/// The list is a pair of enumerations rather than a convention about strings,
/// so "we only send what is written down" is checked by the compiler instead
/// of by care. `docs/analytics.md` is the same list in prose, and
/// `AnalyticsCatalogueTests` fails the build when the two drift — which is
/// what lets the README promise a complete list without hedging.
///
/// The design, and the argument for a permanent identifier and for being on
/// by default, is in `docs/specs/2026-08-22-analytics-design.md`. The short
/// version: this buys the only view anyone has of what the first run does to
/// people, and it costs a durable handle on one machine's habits, which is
/// paid for with full disclosure, a visible switch, no stored addresses, and
/// a year's retention.
enum Analytics {
    /// Every event that exists. There is no `track(String)`.
    enum Event: String, CaseIterable, Sendable {
        /// The first launch on this machine — the run that found no
        /// identifier file and made one.
        case installed

        case setupOpened = "setup_opened"
        case setupCompleted = "setup_completed"
        case micGranted = "mic_granted"
        case micDenied = "mic_denied"
        case systemAudioHeard = "system_audio_heard"
        case systemAudioSilent = "system_audio_silent"

        /// No `first_recording` and no `first_transcript`: a funnel is built
        /// from the first occurrence of each step per person, and the
        /// identifier is exactly what makes that possible. This is the whole
        /// return on the decision — the event list stays short.
        case recordingStarted = "recording_started"
        case recordingFinished = "recording_finished"
        case recordingDiscarded = "recording_discarded"
        case transcriptFinished = "transcript_finished"
        case summaryFinished = "summary_finished"

        case transcriptFailed = "transcript_failed"
        case summaryFailed = "summary_failed"
        case systemTrackSilent = "system_track_silent"
        case sessionInterrupted = "session_interrupted"

        case settingChanged = "setting_changed"
    }

    /// Every property key that may accompany an event.
    enum Property: String, CaseIterable, Sendable {
        /// `manual`, `mic_activity`, `calendar` — from `RecordingSession.Trigger`.
        case trigger
        /// `app` or `cli`.
        case surface
        /// Coarse on purpose: an exact length is a fingerprint, and no
        /// question anybody asked needs one.
        case durationBucket = "duration_bucket"
        case liveUsed = "live_used"
        case systemAudio = "system_audio"
        case engine
        case backend
        /// Always from `Reason`, never an error string. Error text carries
        /// paths, host names and occasionally an API key, and there is no
        /// sanitising of it that stays true as the code changes.
        case reason
        case setupVersion = "setup_version"
        /// For `setting_changed` only, and only ever a key from
        /// `AnalyticsCatalogue.reportableSettings`.
        case key
        case value
    }

    /// Why something failed, as a closed set.
    enum Reason: String, Sendable {
        case noNetwork = "no_network"
        case noKey = "no_key"
        case noModel = "no_model"
        case audioMissing = "audio_missing"
        case audioTooShort = "audio_too_short"
        case refused
        case timedOut = "timed_out"
        case httpError = "http_error"
        case quit
        case unknown
    }

    enum Value: Sendable, Equatable {
        case text(String)
        case number(Double)
        case flag(Bool)

        var json: Any {
            switch self {
            case .text(let string): return string
            case .number(let double): return double
            case .flag(let bool): return bool
            }
        }
    }

    /// Where an exact duration turns into something that describes a lot of
    /// meetings rather than one.
    static func durationBucket(seconds: Double) -> Value {
        switch seconds {
        case ..<300: return .text("under_5m")
        case ..<900: return .text("5_15m")
        case ..<1800: return .text("15_30m")
        case ..<3600: return .text("30_60m")
        case ..<7200: return .text("1_2h")
        default: return .text("over_2h")
        }
    }

    /// Begin reporting. Loads whatever failed to send last time, starts the
    /// flush timer, and — on a machine that has never run amanu — sends
    /// `installed` before anything else can.
    static func start(surface: Surface) {
        AnalyticsSink.shared.start(surface: surface)
    }

    enum Surface: String, Sendable {
        case app
        case cli
    }

    static func track(_ event: Event, _ properties: [Property: Value] = [:]) {
        AnalyticsSink.shared.record(event, properties)
    }

    /// A setting a person changed, if it is one of the settings that can be
    /// reported at all.
    ///
    /// Called from `Config.update`, which every write already passes through,
    /// so a setting added later cannot be quietly left out — or quietly let
    /// in. Free text never reaches here: `AnalyticsCatalogue.reportableSettings`
    /// admits toggles and fixed choices only, which is what keeps paths, key
    /// files, app lists and names out by construction rather than by review.
    static func settingChanged(path: [String], value: Any?) {
        guard let change = reportableChange(path: path, value: value) else { return }
        track(.settingChanged, [.key: .text(change.key), .value: change.value])
    }

    /// The decision on its own, so that "a path can never travel" is a thing
    /// a test can assert rather than a thing a reviewer has to notice.
    ///
    /// Nil means the change is not reportable, which is the answer for every
    /// free-text setting, every number, every list, the analytics switch
    /// itself, and any value that does not match the kind the schema declares.
    static func reportableChange(path: [String], value: Any?) -> (key: String, value: Value)? {
        let key = path.joined(separator: ".")
        guard let kind = AnalyticsCatalogue.reportableSettings[key] else { return nil }
        switch (kind, value) {
        case (_, .none):
            // Cleared, which in this config file means "back to the default"
            // rather than "unset" — see `SettingsSchema.resolve`.
            return (key, .text("default"))
        case (.toggle, .some(let raw)):
            guard let flag = raw as? Bool else { return nil }
            return (key, .flag(flag))
        case (.choice(let allowed), .some(let raw)):
            guard let string = raw as? String, allowed.contains(string) else { return nil }
            return (key, .text(string))
        }
    }

    /// Send what is buffered, waiting only briefly. Called on the way out.
    ///
    /// The wait is capped because quitting is the user's instruction and
    /// analytics does not get to argue with it; whatever does not go now is
    /// on disk and goes at the next launch.
    static func flushOnExit() {
        AnalyticsSink.shared.flush(waitingUpTo: 1.5)
    }

    static var isEnabled: Bool { AnalyticsIdentity.isEnabled() }

    static var identifier: String { AnalyticsIdentity.identifier() }
}
