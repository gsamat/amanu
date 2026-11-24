import Foundation
import whisper

/// One language decision shared by final-transcript engines. Legacy is a
/// read-only compatibility state, not another setting a new user must choose.
enum TranscriptionLanguagePolicy: Equatable, Sendable {
    case automatic
    case fixed(String)
    case legacy(primary: String)
    case invalid(String)

    struct ConfigurationError: TranscriptionFailure, CustomStringConvertible {
        let description: String
        var isPermanent: Bool { false }
        var isEnvironmental: Bool { true }
    }

    static func resolve(mode: String?, language: String?, legacyWhisperLanguage: String? = nil) -> Self {
        let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case "auto": return .automatic
        case "fixed":
            guard let code, validCode(code) else {
                return .invalid(
                    localised(
                        "Fixed language mode requires a two-letter language code, such as ru.",
                        "Для фиксированного режима выберите язык или укажите двухбуквенный код, например ru."))
            }
            return .fixed(code)
        case nil, "":
            if let old = legacyWhisperLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                !old.isEmpty, old != "auto"
            {
                // Preserve the old Whisper vocabulary as well as its value;
                // validation against Whisper happens before a model is loaded.
                return .fixed(old)
            }
            guard let code, !code.isEmpty else { return .automatic }
            return .legacy(primary: code)
        default:
            return .invalid(
                localised(
                    "transcription.language_mode must be auto or fixed.",
                    "transcription.language_mode должен быть auto или fixed."))
        }
    }

    private static func validCode(_ code: String) -> Bool {
        code.utf8.count == 2 && code.utf8.allSatisfy { (97...122).contains($0) }
            && languageCodes.contains(code)
    }

    private static let languageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

    var expectedLanguages: [String] {
        switch self {
        case .automatic, .invalid: return []
        case .fixed(let code): return [code]
        case .legacy(let primary): return MeetingLanguages.expected(primary: primary)
        }
    }

    var fixedLanguage: String? {
        if case .fixed(let code) = self { return code }
        return nil
    }

    var isLegacy: Bool {
        if case .legacy = self { return true }
        return false
    }

    /// A provider must not quietly turn a fixed language into a hint. In
    /// particular FluidAudio v3's language argument filters an alphabet, not
    /// a language; it cannot make the same promise as Whisper's language pin.
    func unsupportedReason(engine: String, model: String) -> String? {
        if case .invalid(let reason) = self { return reason }
        guard let code = fixedLanguage else { return nil }
        switch engine {
        case "parakeet":
            if model.contains("v2"), code == "en" { return nil }
            return localised(
                "This Parakeet model cannot fix the recognition language. Choose Auto or a different engine, such as Whisper.",
                "Эта модель Parakeet не умеет фиксировать язык распознавания. Выберите «Автоматически» или другой движок, например Whisper."
            )
        case "gigaam" where code != "ru":
            return localised("GigaAM recognises Russian only.", "GigaAM распознаёт только русский язык.")
        case "whisper" where whisper_lang_id(code) < 0:
            return localised("Whisper does not support language \(code).", "Whisper не поддерживает язык \(code).")
        default: return nil
        }
    }

    func validate(engine: String, model: String) throws {
        if let reason = unsupportedReason(engine: engine, model: model) {
            throw ConfigurationError(description: reason)
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return localised(
                "The engine detects the language from the audio. A saved language code is ignored in Auto mode.",
                "Движок определяет язык по аудио. Сохранённый код языка в автоматическом режиме не используется.")
        case .fixed(let code):
            return localised(
                "Recognition language: \(code). Use Auto for multilingual recordings.",
                "Язык распознавания: \(code). Для многоязычных записей выберите «Автоматически».")
        case .legacy(let primary):
            return localised(
                "Keeping the previous policy (\(MeetingLanguages.describe(MeetingLanguages.expected(primary: primary)))). Choose Auto or Fixed to replace it explicitly.",
                "Сохранён прежний режим (\(MeetingLanguages.describe(MeetingLanguages.expected(primary: primary)))). Чтобы изменить его, явно выберите автоматический или фиксированный режим."
            )
        case .invalid(let reason): return reason
        }
    }
}
