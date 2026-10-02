import Foundation

/// Where this Mac stands against what setup asks of it: what is still owed,
/// what the wizard's one button should do next, and what it should say.
///
/// A value built from a snapshot of the machine, and nothing else. The form
/// used to answer these three questions from three computed properties that
/// each asked macOS for themselves, and they agreed only because each was
/// written to walk the same order as the others. Here the order is written
/// once, and every branch of it can be checked without granting, revoking or
/// downloading anything.
struct SetupProgress: Equatable {
    /// What the machine said, read once for one redraw.
    struct Machine: Equatable {
        var loginItem: LoginItem.State = .enabled
        var microphone: SetupPermissions.State = .granted
        var systemAudio: SetupPermissions.SystemAudioResult? = .heard
        /// The local engine that is wanted and not on this Mac, by its
        /// config name; nil when nothing local is owed.
        var missingLocalModel: String?
        var localModelDownloading = false
        var liveModelWanted = false
        var liveModelReady = false
        var liveModelDownloading = false
        /// Summaries are on and whatever was chosen to write them isn't here.
        var summaryToolMissing = false
    }

    /// What the primary button does.
    enum Step: Equatable {
        case startAtLogin
        case askMicrophone
        case testSystemAudio
        case downloadLocalModel
        case downloadLiveModel
    }

    /// One thing the machine still owes.
    ///
    /// A case rather than the words for it, because the words are read by a
    /// person and the case is read by the program: the footer button asks
    /// whether the local model is on this list, and it asked by comparing
    /// against the string the window was showing. That worked while there
    /// was one language to show it in.
    enum Missing: Sendable, Equatable {
        case startAtLogin
        case microphone
        case systemAudio
        /// The local engine that is chosen and not downloaded, by its config
        /// name. It used to be `parakeet` whatever was chosen, so a Mac
        /// waiting for Whisper was told parakeet was missing.
        case localModel(String)
        case liveModel
        /// Summaries are on, and whatever was chosen to write them isn't here.
        case summaryTool

        /// The default engine, which is most of the time the one missing.
        static var parakeet: Missing { .localModel("parakeet") }

        var described: String {
            switch self {
            case .startAtLogin: return localised("start at login", "запуск при входе")
            case .microphone: return localised("microphone", "микрофон")
            case .systemAudio: return localised("system audio", "звук системы")
            // A name, and names are not translated.
            case .localModel(let engine): return SetupProgress.modelName(engine)
            case .liveModel:
                return localised("live model", "модель для расшифровки на лету")
            case .summaryTool:
                return localised("something to summarise with", "чем писать саммари")
            }
        }

        var isLocalModel: Bool {
            if case .localModel = self { return true }
            return false
        }
    }

    let machine: Machine

    init(_ machine: Machine) { self.machine = machine }

    private var needsStartAtLogin: Bool {
        SetupPermissions.needsStartAtLogin(loginItem: machine.loginItem)
    }

    /// What the machine still owes, in the order it has to be dealt with.
    var outstanding: [Missing] {
        var left: [Missing] = []
        if needsStartAtLogin { left.append(.startAtLogin) }
        if machine.microphone != .granted { left.append(.microphone) }
        if machine.systemAudio != .heard { left.append(.systemAudio) }
        if let engine = machine.missingLocalModel { left.append(.localModel(engine)) }
        if machine.liveModelWanted, !machine.liveModelReady { left.append(.liveModel) }
        // The window used to say everything was granted while the card it had
        // chosen to write the summaries said "not here" three inches above.
        if machine.summaryToolMissing { left.append(.summaryTool) }
        return left
    }

    /// What the primary button will do, or nil when there is nothing left to
    /// offer. The order is the order things must happen in: the agent first,
    /// because a grant given to the wrong process is worse than none.
    var next: Step? {
        if needsStartAtLogin { return .startAtLogin }
        if machine.microphone == .notAsked { return .askMicrophone }
        if SetupPermissions.needsSystemAudioTest(machine.systemAudio) { return .testSystemAudio }
        if machine.missingLocalModel != nil, !machine.localModelDownloading {
            return .downloadLocalModel
        }
        if machine.liveModelWanted, !machine.liveModelReady, !machine.liveModelDownloading {
            return .downloadLiveModel
        }
        return nil
    }

    /// Whether a model is coming down right now — the work a host must not
    /// offer to start a second time.
    var isDownloading: Bool { machine.localModelDownloading || machine.liveModelDownloading }

    /// What the primary button says, given where things stand.
    var nextTitle: String {
        if needsStartAtLogin {
            return machine.loginItem == .needsApproval
                ? localised("Open Login Items", "Открыть объекты входа")
                : localised("Start at login", "Запускать при входе")
        }
        if machine.microphone == .notAsked {
            return localised("Allow microphone", "Разрешить микрофон")
        }
        if SetupPermissions.needsSystemAudioTest(machine.systemAudio) {
            return localised("Allow and test", "Разрешить и проверить")
        }
        // Named separately from the live model because the two downloads
        // can be outstanding at once, and a button that offers a download
        // already running has nothing left to do but close the window under
        // the person reading it.
        if machine.localModelDownloading {
            return localised("Downloading local model…", "Скачивается локальная модель…")
        }
        if outstanding.contains(where: \.isLocalModel) {
            return localised("Download local model", "Скачать локальную модель")
        }
        if machine.liveModelDownloading {
            return localised("Downloading live model…", "Скачивается модель…")
        }
        if outstanding.contains(.liveModel) {
            return localised("Download live model", "Скачать модель")
        }
        return localised("Done", "Готово")
    }

    /// The list in a sentence, for whatever is showing it.
    ///
    /// Both windows say this, so both say it the same way: the setup window
    /// in its footer, the settings window under the Setup tab. It says the
    /// good news as well as the bad, because most of the time somebody opens
    /// that tab to be reassured rather than to repair anything, and a line
    /// that only ever appears when something is wrong leaves them counting
    /// green ticks to find out whether it is.
    var sentence: String { Self.sentence(for: outstanding) }

    static func sentence(for outstanding: [Missing]) -> String {
        let named = outstanding.map(\.described)
        switch named.count {
        case 0:
            return localised(
                "Everything amanu needs is granted.", "Всё, что нужно amanu, разрешено.")
        case 1:
            return localised("One thing left: ", "Осталось одно: ") + named[0]
        default:
            return localised("Left: ", "Осталось: ") + named.joined(separator: ", ")
        }
    }

    /// A local engine as a person knows it. Parakeet keeps its lower case
    /// because that is how it has always been written in this window.
    static func modelName(_ engine: String) -> String {
        switch engine {
        case "whisper": return "Whisper"
        case "gigaam": return "GigaAM"
        default: return "parakeet"
        }
    }
}
