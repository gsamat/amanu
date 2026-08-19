import Foundation

/// What language amanu's own windows are in, and how that is decided.
///
/// This is not `transcription.language` — the language meetings are held in —
/// and not `summary.language` — the language summaries are written in. Those
/// two are about other people's words; this one is about amanu's. The three
/// live far apart in the config file and are named apart in the windows for
/// that reason, because they are three separate questions and the only thing
/// they share is the word "language".
///
/// The Mac's own languages decide it, and the config file can overrule them.
/// Both halves earn their place. Somebody whose Mac is in Russian should not
/// have to find a setting written in English to be spoken to in Russian; and
/// somebody who keeps their Mac in one language and wants amanu in another has
/// nowhere else to say so — the per-app override in Language & Region only
/// works for a bundle carrying `.lproj` resources, and amanu's strings are in
/// its code rather than in a resource nobody could read at `swift test` time.
///
/// There is a history here worth not repeating. The setup window used to put
/// `Locale.current` into the *meeting* language field, where it was an
/// operating system answering a question it cannot know — nothing about a
/// Mac's language says what language its owner holds meetings in — and it was
/// taken out. This is the other question: what language to talk to a person
/// in is exactly what a Mac's language list is for.
enum InterfaceLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case russian = "ru"

    /// What the config file may say. `auto` is the default and means "ask the
    /// Mac"; the rest are the languages above, by the same two-letter code the
    /// rest of amanu uses.
    static let automatic = "auto"
    static var configuredValues: [String] { [automatic] + allCases.map(\.rawValue) }

    /// The language in force. English until the application says otherwise:
    /// `Run` resolves it once at startup, before a window exists, and nothing
    /// changes it afterwards.
    ///
    /// Which is also what makes the test suite readable. A test looks for the
    /// row that says "Keep the audio after transcribing", and it finds it on
    /// any Mac, in any country, because nothing in a test process ever sets
    /// this — the language of a window is a property of the program's start,
    /// not of the machine the suite happens to run on.
    static var current: InterfaceLanguage {
        get { store.value }
        set { store.value = newValue }
    }

    /// Read the config and the Mac, and settle it. Called once, at startup.
    static func adoptFromSystem() {
        current = choose(
            configured: Config.interfaceLanguage(),
            preferred: Locale.preferredLanguages)
    }

    /// The whole decision, as a function of its two inputs and nothing else —
    /// which is what lets every branch of it be tested without a config file
    /// or a Mac set to Portuguese.
    ///
    /// `preferred` is `Locale.preferredLanguages`: identifiers like `en-GB` or
    /// `ru-RU`, most wanted first. A language amanu has no words for is passed
    /// over rather than being taken as English, because the next one down the
    /// list may well be one it has.
    static func choose(configured: String?, preferred: [String]) -> InterfaceLanguage {
        if let configured, configured != automatic, !configured.isEmpty {
            if let named = InterfaceLanguage(rawValue: configured) { return named }
            FileHandle.standardError.write(Data(
                "warning: unknown interface_language \"\(configured)\" — asking the Mac instead\n"
                    .utf8))
        }
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
                ?? identifier.prefix(while: { $0 != "-" && $0 != "_" }).lowercased()
            if let known = InterfaceLanguage(rawValue: code) { return known }
        }
        return .english
    }

    /// Shared mutable state behind a lock rather than an actor, for the same
    /// reason `Tooling` does it: every caller is synchronous, and half of them
    /// — the banners a finished transcription posts — are not on the main
    /// actor, so isolating the words to it would make writing a label an
    /// `await`.
    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var language: InterfaceLanguage = .english

        var value: InterfaceLanguage {
            get {
                lock.lock()
                defer { lock.unlock() }
                return language
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                language = newValue
            }
        }
    }
}

/// One thing amanu says, in both languages it can say it in.
///
/// The pair sits where the words are used rather than in a table of keys
/// somewhere else. A key table means every window is written in identifiers
/// and read somewhere else, and the sentence a person actually sees stops
/// being visible in the code that puts it on screen — which for a form whose
/// whole design is in its wording would be the wrong trade. Here the two
/// versions are one line apart, and a wrong translation is caught by reading
/// the form rather than by reading two files at once.
///
/// Not everything goes through this. Names of things stay as they are —
/// AssemblyAI, OpenAI, Ollama, parakeet, amanu — and so do prices, paths and
/// version numbers: translating a name is how a window ends up naming
/// something that does not exist.
func localised(_ english: String, _ russian: String) -> String {
    switch InterfaceLanguage.current {
    case .english: return english
    case .russian: return russian
    }
}
