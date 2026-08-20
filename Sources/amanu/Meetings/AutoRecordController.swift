import Foundation

/// Decides on its own when a meeting starts and ends.
///
/// Two independent triggers, either of which is enough: a call app opens the
/// microphone and keeps it open, or a calendar event that looks like a call
/// just started. Stopping is deliberately reluctant — an auto-recording ends
/// only once nobody is holding the mic *and* nothing has come out of the
/// speakers for a while. Recording a few extra silent minutes costs megabytes;
/// stopping early costs the meeting.
///
/// Two backstops exist because the primary rule can be defeated by an app that
/// holds the microphone long after a call ends: silence on both tracks, and a
/// hard duration ceiling. mygranola shipped without the first one and produced
/// three back-to-back recordings totalling about fifteen hours in one night.
///
/// Manual recordings are never touched: if you pressed the button, only you
/// decide when it stops.
@MainActor
final class AutoRecordController {
    /// Asks the owner for state and tells it what to do. Kept as callbacks so
    /// this type holds no session of its own — there is exactly one recorder,
    /// and it lives in AppController.
    var currentSession: (() -> RecordingSession?)?
    var startRecording: ((RecordingSession.Trigger, MeetingContext) -> Void)?
    var stopRecording: ((String) -> Void)?

    /// What the controller is thinking, for the menu. "Why didn't it record?"
    /// is otherwise a question you can only answer with a debugger.
    private(set) var lastDecision = localised("ready", "готов")

    /// Runtime override from the menu bar, independent of the config file.
    /// Turning auto-record off in the menu must be instant and obvious.
    var enabled: Bool {
        didSet {
            if !enabled {
                lastDecision = localised("auto-record off", "автозапись выключена")
            }
            micActiveSince = nil
        }
    }

    private let calendar: CalendarWatcher?
    private var timer: Timer?
    private var micActiveSince: Date?
    private var micIdleSince: Date?
    private var handledEventIDs = Set<String>()
    private var cooldownUntil: Date?
    private var lastCalendarCheck = Date.distantPast
    private var currentEventEnd: Date?

    private static let tick: TimeInterval = 5
    /// A calendar query is the expensive part of the loop, and events don't
    /// start more precisely than this anyway.
    private static let calendarInterval: TimeInterval = 25
    /// How late an event may be picked up after its start time.
    private static let calendarWindow: TimeInterval = 3 * 60
    /// After a manual stop, don't immediately re-arm — the call is usually
    /// still open, and the user just said they didn't want it recorded.
    private static let manualStopCooldown: TimeInterval = 15 * 60
    /// How long the far end must have been quiet before a finished calendar
    /// event may end the recording. Named rather than written twice, because
    /// the discard rule below has to subtract exactly this number and a pair
    /// of literals drifts apart the first time one of them is tuned.
    nonisolated static let calendarEndQuiet: TimeInterval = 60

    init(settings: Config.AutoRecordSettings, calendar: CalendarWatcher?) {
        self.enabled = settings.enabled
        self.calendar = calendar
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The user started a recording by hand — don't treat it as ours.
    func noteManualStart() {
        currentEventEnd = nil
        cooldownUntil = nil
    }

    /// The user stopped a recording by hand. Whatever is holding the mic, they
    /// don't want it recorded; stay out of the way for a while, and consider
    /// the current calendar event dealt with.
    func noteManualStop() {
        cooldownUntil = Date().addingTimeInterval(Self.manualStopCooldown)
        micActiveSince = nil
        currentEventEnd = nil
        if let event = calendar?.bestMatch(for: Date()) {
            handledEventIDs.insert(event.id)
        }
    }

    // MARK: -

    private func tick() {
        let settings = Config.autoRecord()
        guard enabled, settings.enabled else {
            lastDecision = localised("auto-record off", "автозапись выключена")
            return
        }

        let now = Date()
        let mic = MicActivityMonitor.check(
            callApps: settings.callApps,
            ignoring: settings.ignoreApps
        )

        if mic.active {
            if micActiveSince == nil { micActiveSince = now }
            micIdleSince = nil
        } else {
            micActiveSince = nil
            if micIdleSince == nil { micIdleSince = now }
        }

        if let session = currentSession?() {
            evaluateStop(session: session, settings: settings, now: now, mic: mic)
        } else {
            evaluateStart(settings: settings, now: now, mic: mic)
        }
    }

    // MARK: - start

    private func evaluateStart(
        settings: Config.AutoRecordSettings,
        now: Date,
        mic: MicActivityMonitor.Result
    ) {
        if let until = cooldownUntil, now < until {
            lastDecision = localised(
                "paused after a manual stop", "пауза после ручной остановки")
            return
        }

        if settings.calendar, let calendar,
           now.timeIntervalSince(lastCalendarCheck) >= Self.calendarInterval {
            lastCalendarCheck = now
            let started = calendar.justStarted(now: now, window: Self.calendarWindow)
            if let event = started.first(where: { !handledEventIDs.contains($0.id) }) {
                handledEventIDs.insert(event.id)
                currentEventEnd = event.end
                lastDecision =
                    localised("started from calendar: ", "начала по календарю: ") + event.title
                // The call app usually grabs the mic a moment after the event
                // starts, so it may be nil here — the calendar carries the name.
                startRecording?(.calendar, MeetingContext(
                    meeting: event, app: mic.names.first, appFamilies: mic.families))
                return
            }
        }

        guard settings.micActivity else {
            lastDecision = localised("ready, watching the calendar", "готов, слежу за календарём")
            return
        }
        guard let since = micActiveSince else {
            lastDecision = mic.allHolders.isEmpty
                ? localised("ready", "готов")
                : localised("mic held by ", "микрофон занят: ")
                    + mic.allHolders.joined(separator: ", ")
                    + localised(" — not a call app", " — это не приложение для звонков")
            return
        }

        let held = now.timeIntervalSince(since)
        guard held >= settings.startDelay else {
            lastDecision = localised(
                "\(mic.names.joined(separator: ", ")) on the mic for \(Int(held))s",
                "\(mic.names.joined(separator: ", ")) держит микрофон \(Int(held)) с")
            return
        }
        let event = calendar?.bestMatch(for: now)
        currentEventEnd = event?.end
        lastDecision = localised(
            "started from mic activity (\(mic.names.first ?? "call app"))",
            "начала по микрофону (\(mic.names.first ?? "приложение звонка"))")
        startRecording?(.micActivity, MeetingContext(
            meeting: event, app: mic.names.first, appFamilies: mic.families))
    }

    // MARK: - stop

    private func evaluateStop(
        session: RecordingSession,
        settings: Config.AutoRecordSettings,
        now: Date,
        mic: MicActivityMonitor.Result
    ) {
        let elapsed = now.timeIntervalSince(session.startedAt)

        // The ceiling applies to manual recordings too: whatever this is, it
        // stopped being a meeting hours ago.
        if elapsed > settings.maxDuration {
            lastDecision = localised(
                "stopped at the duration ceiling", "остановила на пределе длительности")
            stopRecording?("max-duration")
            return
        }
        guard session.trigger != .manual else {
            lastDecision = localised("manual recording in progress", "идёт ручная запись")
            return
        }

        let micQuietFor = now.timeIntervalSince(session.lastMicSoundAt ?? session.startedAt)
        let farEndQuietFor = now.timeIntervalSince(session.lastSystemSoundAt ?? session.startedAt)

        // Backstop: nobody has said anything on either track for a long while.
        // Independent of who holds the microphone, which is the point — this is
        // what catches an app that never lets the device go.
        if session.levelsMeasurable, min(micQuietFor, farEndQuietFor) > settings.silenceStop {
            lastDecision = localised(
                "stopped after \(Int(settings.silenceStop / 60)) min of silence",
                "остановила после \(Int(settings.silenceStop / 60)) мин тишины")
            stopRecording?("silence")
            return
        }

        // The scheduled meeting is over, the mic is free, and the far end has
        // gone quiet: three agreeing signals, stop without waiting out the
        // full idle delay.
        if let end = currentEventEnd, now > end.addingTimeInterval(120),
           !mic.active, farEndQuietFor > Self.calendarEndQuiet {
            lastDecision = localised(
                "stopped — calendar event ended", "остановила — событие календаря кончилось")
            stopRecording?("calendar-event-ended")
            return
        }

        let micIdleFor = micIdleSince.map { now.timeIntervalSince($0) } ?? 0
        if !mic.active, micIdleFor > settings.stopDelay, farEndQuietFor > settings.stopDelay {
            lastDecision = localised("stopped — the call ended", "остановила — звонок кончился")
            stopRecording?("call-ended")
            return
        }

        lastDecision = mic.active
            ? localised("meeting in progress", "идёт встреча")
            : localised(
                "quiet for \(Int(min(micIdleFor, farEndQuietFor)))s",
                "тихо уже \(Int(min(micIdleFor, farEndQuietFor))) с")
    }

    // MARK: - discard

    /// The quiet an automatic recording had to sit through before this reason
    /// could fire. None of it was the meeting: `call-ended` means nobody
    /// touched the microphone for `stopDelay`, `silence` means neither track
    /// made a sound for `silenceStop`, and `calendar-event-ended` means the
    /// far end was quiet for `calendarEndQuiet` after the event was over.
    ///
    /// `nil` for every other reason, because the others say nothing about
    /// whether a meeting happened: "app-quit" and "max-duration" mean we
    /// stopped it, not that it ended. Treating those as evidence threw away
    /// the first fifteen seconds of a genuine call that happened to start
    /// while amanu was being reinstalled (2026.08.18).
    nonisolated static func trailingQuiet(
        for reason: String, settings: Config.AutoRecordSettings
    ) -> TimeInterval? {
        switch reason {
        case "call-ended": return settings.stopDelay
        case "silence": return settings.silenceStop
        case "calendar-event-ended": return calendarEndQuiet
        default: return nil
        }
    }

    /// Whether a finished recording was too short to have been a meeting.
    ///
    /// The length compared against `minDuration` is the meeting's, not the
    /// file's: the recording keeps running for as long as the stop rule waits,
    /// and the wait is a property of the rule rather than of the call. Left in
    /// terms of the file, the comparison could never be true — the shortest
    /// automatic recording that can exist is longer than the shortest wait
    /// that can end one — so the discard shipped unreachable and every
    /// nineteen-second join was kept (`.issues/008`).
    ///
    /// Measuring from the recording's start still under-counts the meeting by
    /// the `startDelay` of pre-roll that had already passed before we started,
    /// which errs a little towards throwing away — the direction the setting
    /// exists for.
    ///
    /// A parameter rather than a `Config.autoRecord()` call inside, and a free
    /// function rather than four lines inside the closure that stops a
    /// session, because a rule nothing can call is a rule nothing can check.
    nonisolated static func shouldDiscard(
        trigger: RecordingSession.Trigger,
        reason: String,
        duration: TimeInterval,
        settings: Config.AutoRecordSettings
    ) -> Bool {
        // If you pressed the button, only you decide what it was worth.
        guard trigger != .manual else { return false }
        guard let quiet = trailingQuiet(for: reason, settings: settings) else { return false }
        return duration - quiet < settings.minDuration
    }
}
