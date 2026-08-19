import FluidAudio
import Foundation

/// The languages a meeting can be held in, and what naming one actually means.
///
/// The setting reads as "meetings are mostly in Russian", and *mostly* is the
/// load-bearing word. Every engine here identifies the language itself; what a
/// hard pin buys is not accuracy but a confident, unreadable transcript on the
/// day the meeting turns out to be in the other language — and with
/// `keep_audio` off by default, that transcript is all that survives the
/// meeting. So a choice here is read as the set of languages to *expect*, and
/// the engine still decides which one it heard.
///
/// English is expected alongside whatever is picked, because it is the second
/// language of almost every meeting that has one. Somebody whose other
/// language is German is served by the config file; somebody who picks English
/// expects only English, which is the same rule with nothing to add.
enum MeetingLanguages {
    /// The five that get their own place at the top of the menu, in this
    /// order, ahead of the alphabet. Frequency, not politics: these are the
    /// languages amanu is actually used in, and a menu you scroll to reach
    /// your own language every time is a menu that was sorted for the
    /// alphabet's benefit rather than yours.
    static let pinned = ["en", "ru", "de", "fr", "es"]

    /// One offered language: the code that goes into the config file, and the
    /// name it is offered under.
    struct Choice: Equatable, Sendable {
        let code: String
        /// The language's name in itself — Deutsch, not German. What macOS
        /// does in Language & Region, and the only naming that works for a
        /// person who is here because the app is not in their language.
        let name: String
    }

    /// Autonyms, written out rather than asked of `Locale`: ICU returns them
    /// lowercased ("русский", "français"), macOS shows them capitalised, and
    /// the difference would have to be patched back in per-language anyway.
    private static let names: [String: String] = [
        "en": "English", "ru": "Русский", "de": "Deutsch",
        "fr": "Français", "es": "Español",
        "be": "Беларуская", "bg": "Български", "bs": "Bosanski",
        "cs": "Čeština", "da": "Dansk", "el": "Ελληνικά",
        "et": "Eesti", "fi": "Suomi", "hr": "Hrvatski",
        "hu": "Magyar", "it": "Italiano", "lt": "Lietuvių",
        "lv": "Latviešu", "mt": "Malti", "nl": "Nederlands",
        "pl": "Polski", "pt": "Português", "ro": "Română",
        "sk": "Slovenčina", "sl": "Slovenščina", "sr": "Српски",
        "sv": "Svenska", "uk": "Українська",
    ]

    /// What to offer, in the order to offer it: the five above, then the rest
    /// by name.
    ///
    /// The list is FluidAudio's own, not one of ours, so a language cannot be
    /// offered that the default engine has never heard of. If that library
    /// learns a new one, `menu` drops it for want of a name and the test says
    /// so — a missing menu entry is a smaller failure than a menu entry that
    /// silently means nothing.
    static let menu: [Choice] = {
        let known = Language.allCases.map(\.rawValue)
        let top = pinned.compactMap { code in
            known.contains(code) ? names[code].map { Choice(code: code, name: $0) } : nil
        }
        let rest = known
            .filter { !pinned.contains($0) }
            .compactMap { code in names[code].map { Choice(code: code, name: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return top + rest
    }()

    static func name(for code: String) -> String? { names[code] }

    /// The languages to expect from a meeting, given what the config names.
    ///
    /// Empty means "no expectation" — every engine here can identify a
    /// language unaided, and an empty set says to let it.
    static func expected(primary: String?) -> [String] {
        guard let raw = primary?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, names[raw] != nil
        else { return [] }
        return raw == "en" ? [raw] : [raw, "en"]
    }

    /// The same set as a sentence, for the places that report what amanu is
    /// about to do rather than do it — `amanu doctor`, and the line under the
    /// setup window's menu.
    static func describe(_ expected: [String]) -> String {
        let named = expected.map { names[$0] ?? $0 }
        guard let last = named.last, named.count > 1 else { return named.first ?? "any language" }
        return named.dropLast().joined(separator: ", ") + " and " + last
    }
}
