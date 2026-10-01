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
/// What the controller needs to know about the recording in progress. A
/// protocol so the stop rules can be run against a recording with no audio
/// behind it — they are where an automatic recording either ends too early or
/// never ends, and neither can be arranged on purpose with a real one.
@MainActor
protocol AutoRecordedSession: AnyObject {
    var startedAt: Date { get }
    var trigger: RecordingSession.Trigger { get }
    var lastMicSoundAt: Date? { get }
    var lastSystemSoundAt: Date? { get }
    var levelsMeasurable: Bool { get }
}

extension RecordingSession: AutoRecordedSession {}

/// The two questions the controller asks the calendar, so a test can answer
/// them with meetings of its own.
@MainActor
protocol MeetingCalendar: AnyObject {
    func justStarted(now: Date, window: TimeInterval) -> [CalendarWatcher.Meeting]
    func bestMatch(for date: Date) -> CalendarWatcher.Meeting?
}

extension CalendarWatcher: MeetingCalendar {}

@MainActor
final class AutoRecordController {
    /// Asks the owner for state and tells it what to do. Kept as callbacks so
    /// this type holds no session of its own — there is exactly one recorder,
    /// and it lives in AppController.
    var currentSession: (() -> AutoRecordedSession?)?
    /// Returns whether a recording actually started. A refusal is not rare —
    /// a microphone another app has exclusively, a tap the system will not
    /// create — and what follows one is decided here, not by the caller.
    var startRecording: ((RecordingSession.Trigger, MeetingContext) -> Bool)?
    var stopRecording: ((String) -> Void)?

    /// What the controller is thinking, for the menu. "Why didn't it record?"
    /// is otherwise a question you can only answer with a debugger.
    private(set) var lastDecision = localised("ready", "готов")

    /// `auto_record.enabled`, as last read. The config file is the only place
    /// this is decided: the menu, the status window and Settings all write it
    /// there and read it back, so none of them can show a switch that the
    /// others — or the next launch — disagree with. It used to be a runtime
    /// override beside the file, and the two drifted: turned on in Settings,
    /// the loop never started until a relaunch while the window said On, and
    /// turned on in the menu with the file saying off, the menu showed a tick
    /// while every tick said "auto-record off".
    private(set) var enabled: Bool

    /// Where the loop is, explicitly. Timestamps alone used to stand in for
    /// this, and they re-armed by themselves: a backstop stop left the mic
    /// clock running, so an app that never let go of the microphone — exactly
    /// what the backstops exist for — was recording again five seconds later,
    /// with a new banner, for as long as it held on.
    enum Phase: Equatable {
        /// Nothing of ours is recording and nothing holds the loop back.
        case watching
        /// A recording is running, ours or the user's; the stop rules own it.
        case recording
        /// A recording ended while its call may well still be going: the user
        /// stopped it, or a backstop did. Nothing starts again until the mic
        /// has been let go for `stopDelay` — the call is over, and the next
        /// one is a new call.
        case standingDown(StandDown)
        /// A start was refused. Nothing is tried again before this moment.
        case backingOff(until: Date)
    }

    enum StandDown: Equatable {
        case manualStop
        /// The stop reason that ended it: `max-duration` or `silence`.
        case backstop(String)
    }

    private(set) var phase: Phase = .watching

    private let calendar: MeetingCalendar?
    private let loadSettings: () -> Config.AutoRecordSettings
    private let saveEnabled: (Bool) -> Bool
    private let canStartRecording: () -> Bool
    private let checkMic: (Config.AutoRecordSettings) -> MicActivityMonitor.Result
    private let now: () -> Date
    private var timer: Timer?
    private var micActiveSince: Date?
    private var micIdleSince: Date?
    /// Calendar occurrences already dealt with, keyed by event and start, and
    /// holding the start so old ones can be forgotten. An event identifier is
    /// shared by every occurrence of a recurring event, so keying by it alone
    /// skipped a weekly meeting from its second week until amanu restarted.
    private var handledOccurrences: [String: Date] = [:]
    private var lastCalendarCheck = Date.distantPast
    private var currentEventEnd: Date?
    /// Refused starts in the current held-mic episode. Reset by a start that
    /// works, or by the mic being let go for `stopDelay`.
    private var startFailures = 0
    /// The recording the stop rules last looked at, and whether a call app
    /// has held the mic at any point since it began.
    private var observedSession: ObjectIdentifier?
    private var micTakenDuringSession = false

    /// Poll often enough to honour the default three-second start delay.
    private static let tick: TimeInterval = 1
    /// A calendar query is the expensive part of the loop, and events don't
    /// start more precisely than this anyway.
    private static let calendarInterval: TimeInterval = 25
    /// How late an event may be picked up after its start time.
    private static let calendarWindow: TimeInterval = 3 * 60
    /// How long the far end must have been quiet before a finished calendar
    /// event may end the recording. Named rather than written twice, because
    /// the discard rule below has to subtract exactly this number and a pair
    /// of literals drifts apart the first time one of them is tuned.
    nonisolated static let calendarEndQuiet: TimeInterval = 60
    /// How long a recording the calendar started waits for somebody to join
    /// before "nobody is holding the mic" may end it. The event starts the
    /// recording at its start time; people open the call a few minutes late,
    /// and the mic had been idle since long before the event, so without this
    /// the recording ended as call-ended twenty seconds in. Bounded, because
    /// an event nobody joins is not a meeting either, and the silence
    /// backstop is ten minutes on its own.
    nonisolated static let calendarJoinGrace: TimeInterval = 10 * 60
    /// Waits after a refused start: the first retry is soon, in case the
    /// refusal was a device in the middle of changing hands; after that each
    /// wait doubles, up to the ceiling.
    nonisolated static let firstRetry: TimeInterval = 30
    nonisolated static let longestRetry: TimeInterval = 10 * 60
    /// Stop reasons after which the call is presumed to be still going.
    nonisolated static let backstopReasons: Set<String> = ["max-duration", "silence"]

    init(
        settings: Config.AutoRecordSettings,
        calendar: MeetingCalendar?,
        loadSettings: @escaping () -> Config.AutoRecordSettings = Config.autoRecord,
        saveEnabled: @escaping (Bool) -> Bool = AutoRecordController.writeEnabled,
        canStartRecording: @escaping () -> Bool = { true },
        checkMic: @escaping (Config.AutoRecordSettings) -> MicActivityMonitor.Result = {
            MicActivityMonitor.check(callApps: $0.callApps, ignoring: $0.ignoreApps)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.enabled = settings.enabled
        self.calendar = calendar
        self.loadSettings = loadSettings
        self.saveEnabled = saveEnabled
        self.canStartRecording = canStartRecording
        self.checkMic = checkMic
        self.now = now
    }

    /// Start the loop. It runs whether or not auto-record is on, and a tick
    /// with it off costs one read of the config file: that is what lets the
    /// switch in any window take effect on the next tick rather than at the
    /// next launch.
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - the switch

    /// Turn auto-record on or off from the menu or the status window. The
    /// answer is written to the config file and read back, so what the menu
    /// shows afterwards is what the file says — including when the write
    /// failed and nothing changed.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        let saved = saveEnabled(on)
        reloadSettings()
        return saved
    }

    /// Re-read `auto_record.enabled`. Called on every tick and whenever the
    /// config file changes, so a switch flipped anywhere is obeyed at once.
    func reloadSettings() {
        apply(enabled: loadSettings().enabled)
    }

    private func apply(enabled newValue: Bool) {
        guard newValue != enabled else { return }
        enabled = newValue
        // Either way the loop starts again from nothing: a mic held while it
        // was off must be held for the full delay again before it counts.
        micActiveSince = nil
        startFailures = 0
        if !newValue {
            if phase != .recording { phase = .watching }
            lastDecision = localised("auto-record off", "автозапись выключена")
        }
    }

    /// How `auto_record.enabled` is written: cleared when on, since on is the
    /// default and a config file is meant to read as a list of the things
    /// somebody changed — the same convention the setup form uses.
    nonisolated static func writeEnabled(_ on: Bool) -> Bool {
        Config.update(path: ["auto_record", "enabled"], value: on ? nil : false)
    }

    // MARK: - what the user did

    /// The user started a recording by hand — don't treat it as ours.
    func noteManualStart() {
        currentEventEnd = nil
        phase = .watching
    }

    /// The user stopped a recording by hand. Whatever is holding the mic, they
    /// don't want it recorded; stay out of the way until that call actually
    /// ends, and consider the current calendar event dealt with.
    func noteManualStop() {
        phase = .standingDown(.manualStop)
        micActiveSince = nil
        currentEventEnd = nil
        if let event = calendar?.bestMatch(for: now()) {
            markHandled(event)
        }
    }

    /// The Mac is going to sleep. Whatever held the microphone before it has
    /// to hold it again, for the whole start delay, after it: the clock kept
    /// from before would otherwise read the sleep as the mic being held, and
    /// start a recording on the first tick after wake.
    func noteSystemSleep() {
        micActiveSince = nil
        micIdleSince = nil
    }

    // MARK: -

    func tick() {
        let settings = loadSettings()
        apply(enabled: settings.enabled)
        let now = now()

        // Before the switch, because the ceiling is not part of automatic
        // recording: it applies to every recording, a manual one included,
        // and with auto-record off it used to apply to none of them.
        if let session = currentSession?(),
           now.timeIntervalSince(session.startedAt) > settings.maxDuration {
            lastDecision = localised(
                "stopped at the duration ceiling", "остановила на пределе длительности")
            stop("max-duration")
            return
        }

        guard enabled else {
            lastDecision = localised("auto-record off", "автозапись выключена")
            return
        }

        let mic = checkMic(settings)

        if mic.active {
            if micActiveSince == nil { micActiveSince = now }
            micIdleSince = nil
        } else {
            micActiveSince = nil
            if micIdleSince == nil { micIdleSince = now }
        }

        if let session = currentSession?() {
            observe(session, mic: mic)
            evaluateStop(session: session, settings: settings, now: now, mic: mic)
        } else {
            // A recording that ended without the loop being told — the app
            // quitting, a stop from somewhere this type does not see — leaves
            // nothing to stand down for.
            if phase == .recording { phase = .watching }
            observedSession = nil
            evaluateStart(settings: settings, now: now, mic: mic)
        }
    }

    private func observe(_ session: AutoRecordedSession, mic: MicActivityMonitor.Result) {
        let id = ObjectIdentifier(session)
        if observedSession != id {
            observedSession = id
            micTakenDuringSession = false
        }
        if mic.active { micTakenDuringSession = true }
        phase = .recording
    }

    // MARK: - start

    private func evaluateStart(
        settings: Config.AutoRecordSettings,
        now: Date,
        mic: MicActivityMonitor.Result
    ) {
        let idleFor = micIdleSince.map { now.timeIntervalSince($0) } ?? 0
        let callOver = !mic.active && idleFor > settings.stopDelay
        // A new call is a new episode: whatever was refused during the last
        // one says nothing about this one.
        if callOver { startFailures = 0 }

        switch phase {
        case .standingDown(let why):
            guard callOver else {
                switch why {
                case .manualStop:
                    lastDecision = localised(
                        "paused after a manual stop until the call ends",
                        "пауза после ручной остановки до конца звонка")
                case .backstop:
                    lastDecision = localised(
                        "stopped by a safety limit — waiting for the call app to let go of the mic",
                        "остановлено ограничителем — жду, пока приложение освободит микрофон")
                }
                return
            }
            phase = .watching
        case .backingOff(let until):
            guard now >= until else {
                lastDecision = localised(
                    "couldn't start recording — trying again in \(Int(until.timeIntervalSince(now).rounded(.up)))s",
                    "не удалось начать запись — повторю через \(Int(until.timeIntervalSince(now).rounded(.up))) с")
                return
            }
            phase = .watching
        case .watching, .recording:
            break
        }

        // Do not raise microphone permission prompts behind setup or keep
        // retrying a denied grant. Once access is granted, the next tick can
        // record the call that is already in progress.
        guard canStartRecording() else {
            lastDecision = localised("waiting for microphone access", "жду разрешения на микрофон")
            return
        }

        if settings.calendar, let calendar,
           now.timeIntervalSince(lastCalendarCheck) >= Self.calendarInterval {
            lastCalendarCheck = now
            let started = calendar.justStarted(now: now, window: Self.calendarWindow)
            if let event = started.first(where: { !isHandled($0) }) {
                // The call app usually grabs the mic a moment after the event
                // starts, so it may be nil here — the calendar carries the name.
                let context = MeetingContext(
                    meeting: event, app: mic.names.first, appFamilies: mic.families)
                if attemptStart(.calendar, context, now: now) {
                    markHandled(event)
                    currentEventEnd = event.end
                    lastDecision =
                        localised("started from calendar: ", "начала по календарю: ") + event.title
                }
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
        let context = MeetingContext(meeting: event, app: mic.names.first, appFamilies: mic.families)
        if attemptStart(.micActivity, context, now: now) {
            currentEventEnd = event?.end
            lastDecision = localised(
                "started from mic activity (\(mic.names.first ?? "call app"))",
                "начала по микрофону (\(mic.names.first ?? "приложение звонка"))")
        }
    }

    /// Ask the owner to start, and decide what a refusal means. The owner
    /// does not retry on its own: it used to be asked again on the very next
    /// tick, and every five seconds after that each refusal cost a banner and
    /// an empty folder.
    private func attemptStart(
        _ trigger: RecordingSession.Trigger, _ context: MeetingContext, now: Date
    ) -> Bool {
        if startRecording?(trigger, context) == true {
            phase = .recording
            startFailures = 0
            return true
        }
        startFailures += 1
        let wait = Self.retryDelay(afterFailures: startFailures)
        phase = .backingOff(until: now.addingTimeInterval(wait))
        lastDecision = localised(
            "couldn't start recording — trying again in \(Int(wait))s",
            "не удалось начать запись — повторю через \(Int(wait)) с")
        return false
    }

    /// 30 s, 1 min, 2 min, 4 min, 8 min, then every 10 minutes.
    nonisolated static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let doublings = Double(max(0, min(failures - 1, 16)))
        return min(firstRetry * pow(2, doublings), longestRetry)
    }

    // MARK: - calendar occurrences

    private static func occurrenceKey(_ event: CalendarWatcher.Meeting) -> String {
        "\(event.id)@\(Int(event.start.timeIntervalSince1970))"
    }

    private func isHandled(_ event: CalendarWatcher.Meeting) -> Bool {
        handledOccurrences[Self.occurrenceKey(event)] != nil
    }

    private func markHandled(_ event: CalendarWatcher.Meeting) {
        handledOccurrences[Self.occurrenceKey(event)] = event.start
        // Nothing older than a day can be picked up again anyway — the window
        // is minutes — so there is no reason to remember it for the life of
        // the process.
        let cutoff = now().addingTimeInterval(-24 * 60 * 60)
        handledOccurrences = handledOccurrences.filter { $0.value > cutoff }
    }

    // MARK: - stop

    private func evaluateStop(
        session: AutoRecordedSession,
        settings: Config.AutoRecordSettings,
        now: Date,
        mic: MicActivityMonitor.Result
    ) {
        let elapsed = now.timeIntervalSince(session.startedAt)

        // The ceiling is `tick`'s, ahead of the switch. What is left here is
        // automatic recording's own business.
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
            stop("silence")
            return
        }

        // The scheduled meeting is over, the mic is free, and the far end has
        // gone quiet: three agreeing signals, stop without waiting out the
        // full idle delay.
        if let end = currentEventEnd, now > end.addingTimeInterval(120),
           !mic.active, farEndQuietFor > Self.calendarEndQuiet {
            lastDecision = localised(
                "stopped — calendar event ended", "остановила — событие календаря кончилось")
            stop("calendar-event-ended")
            return
        }

        // A recording the calendar started before anyone joined: the mic has
        // been idle since before the event, which says nothing about whether
        // the call is over, because it has not begun.
        if session.trigger == .calendar, !micTakenDuringSession,
           elapsed < Self.calendarJoinGrace {
            lastDecision = localised(
                "waiting for the call to be joined", "жду, когда подключатся к звонку")
            return
        }

        let micIdleFor = micIdleSince.map { now.timeIntervalSince($0) } ?? 0
        if !mic.active, micIdleFor > settings.stopDelay, farEndQuietFor > settings.stopDelay {
            lastDecision = localised("stopped — the call ended", "остановила — звонок кончился")
            stop("call-ended")
            return
        }

        lastDecision = mic.active
            ? localised("meeting in progress", "идёт встреча")
            : localised(
                "quiet for \(Int(min(micIdleFor, farEndQuietFor)))s",
                "тихо уже \(Int(min(micIdleFor, farEndQuietFor))) с")
    }

    /// End the recording and decide what the loop does next. After a backstop
    /// the call is presumed still going — that is what a backstop is for — so
    /// the loop stands down until the mic is let go; after the others the call
    /// is over and the next one may start as soon as it begins.
    private func stop(_ reason: String) {
        stopRecording?(reason)
        observedSession = nil
        currentEventEnd = nil
        micActiveSince = nil
        phase = Self.backstopReasons.contains(reason)
            ? .standingDown(.backstop(reason))
            : .watching
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
