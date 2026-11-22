import Foundation

extension Config {
    /// Something wrong with the config file that the person needs to hear
    /// about, because amanu is doing something other than what the file says.
    ///
    /// Every surface that could be the one somebody looks at says it: the
    /// menu, the status window, the setup form, the settings window and
    /// `amanu doctor`. A config problem shown in only one of them is shown to
    /// nobody who happened to look at the others.
    enum Problem: Equatable {
        /// The file is there and is not JSON — see `Config.File`.
        case unreadable(reason: String)
        /// A setting whose value is not of a kind amanu can use — `"enabled":
        /// "false"`, a string where a switch belongs — so the default applies
        /// instead. It used to apply without a word, and a quoted `"false"`
        /// reads as off to anybody but a JSON parser.
        case unusable(key: String, found: String, expected: String)

        /// One line, for the menu and the status window, where there is room
        /// for the fact and not for its explanation.
        var headline: String {
            switch self {
            case .unreadable:
                return localised(
                    "config.json can't be read — transcription and summaries are waiting",
                    "config.json не читается — расшифровка и саммари ждут")
            case .unusable:
                return localised(
                    "config.json has a setting amanu can't use — see Settings",
                    "в config.json есть настройка, которую amanu не может использовать, — "
                        + "см. настройки")
            }
        }

        /// The whole account, for the windows with room for it and for the
        /// doctor: what is wrong, and what amanu is doing instead.
        var explanation: String {
            switch self {
            case .unreadable(let reason):
                return localised(
                    "config.json can't be read (\(reason)). Until it is fixed, amanu keeps to "
                        + "the settings it last read from it — its defaults, with auto-record "
                        + "off, if it never could — and keeps recording, but holds transcription "
                        + "and summaries, sends no usage statistics, and saves no changed settings.",
                    "config.json не читается (\(reason)). Пока файл не исправлен, amanu держится "
                        + "настроек, прочитанных из него в последний раз (а если не смогла "
                        + "прочитать ни разу — настроек по умолчанию с выключенной автозаписью), "
                        + "и продолжает записывать, но расшифровка и саммари ждут, статистика не "
                        + "отправляется, а изменённые настройки не сохраняются.")
            case .unusable(let key, let found, let expected):
                return localised(
                    "\(key) in config.json is \(found), which amanu can't use: it expects "
                        + "\(expected), so the default applies.",
                    "\(key) в config.json — \(found), а amanu ждёт там \(expected), поэтому "
                        + "действует значение по умолчанию.")
            }
        }
    }

    /// Everything wrong with the file as it is now, most serious first.
    static func problems() -> [Problem] {
        switch file() {
        case .absent: return []
        case .parsed(let json): return unusableValues(in: json)
        case .unreadable(let reason): return [.unreadable(reason: reason)]
        }
    }

    /// Every value in the file that amanu passes over for the default.
    ///
    /// For switches, numbers, lists and text the test is the reader's own — a
    /// toggle is read `as? Bool`, so whatever fails that fails here — which
    /// keeps this from naming a value that is in fact obeyed. A choice is held
    /// to its option list, which is stricter than a reader that takes any
    /// string: a misspelt engine is obeyed as a name nothing answers to, and
    /// that is worth hearing about just as much.
    static func unusableValues(in json: [String: Any]) -> [Problem] {
        var problems: [Problem] = []
        let entries = Dictionary(
            SettingsSchema.everyEntry.map { ($0.path.joined(separator: "."), $0) },
            uniquingKeysWith: { first, _ in first })
        for key in Key.allCases {
            guard let found = value(key, in: json) else { continue }
            // An empty string is how a setting is cleared by hand, and every
            // reader treats it as absent.
            if let string = found as? String,
               string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let expected: String?
            switch entries[key.rawValue]?.kind {
            case .toggle?:
                let isBoolean = (found as? NSNumber).map {
                    CFGetTypeID($0) == CFBooleanGetTypeID()
                } == true
                expected = (key == .localDiarization ? isBoolean : found as? Bool != nil)
                    ? nil : localised("true or false", "true или false")
            case .number?:
                let isFiniteNumber = (found as? NSNumber).map {
                    CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite
                } == true
                expected = (key == .diarizationThreshold ? isFiniteNumber : found as? Double != nil)
                    ? nil : localised("a number", "число")
            case .choice(let options)?:
                expected = (found as? String).map(options.contains) == true
                    ? nil
                    : localised("one of ", "одно из: ") + options.joined(separator: ", ")
            case .list?:
                expected = found as? [String] != nil
                    ? nil : localised("a list of strings", "список строк")
            case .text?, .multilineText?, nil:
                expected = found as? String != nil
                    ? nil : localised("a string", "строку")
            }
            if let expected {
                problems.append(.unusable(
                    key: key.rawValue, found: describe(found), expected: expected))
            }
        }
        return problems
    }

    /// A value as it would look in the file, short enough for one line.
    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string.prefix(40))\"" }
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        else { return "\(value)" }
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast().prefix(40))
    }
}
