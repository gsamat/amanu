import AppKit
import Foundation
import Testing

@testable import amanu

/// How the windows decide what language to be in, and whether anything in
/// them was left behind in the other one.
///
/// The suite is serialised and puts the language back where it found it: the
/// language is one value for the whole program, and a test that changed it
/// underneath another would fail the other one for reasons that have nothing
/// to do with it.
@Suite(.serialized)
struct InterfaceLanguageTests {
    /// Every branch of the decision, without a config file or a Mac set to
    /// anything in particular.
    @Test("The config decides, and where it says nothing the Mac does")
    func choosing() {
        // The Mac, when nothing overrules it.
        #expect(InterfaceLanguage.choose(configured: nil, preferred: ["ru-RU"]) == .russian)
        #expect(InterfaceLanguage.choose(configured: nil, preferred: ["en-GB"]) == .english)
        #expect(InterfaceLanguage.choose(configured: "auto", preferred: ["ru"]) == .russian)

        // A language amanu has no words for is passed over rather than being
        // taken for English: the next one down the list may well be one it
        // has, and that list is in order of preference for a reason.
        #expect(InterfaceLanguage.choose(configured: nil, preferred: ["de-DE", "ru-RU"]) == .russian)
        #expect(InterfaceLanguage.choose(configured: nil, preferred: ["ja-JP"]) == .english)
        #expect(InterfaceLanguage.choose(configured: nil, preferred: []) == .english)

        // The config overrules the Mac in both directions.
        #expect(InterfaceLanguage.choose(configured: "ru", preferred: ["en-US"]) == .russian)
        #expect(InterfaceLanguage.choose(configured: "en", preferred: ["ru-RU"]) == .english)

        // Something hand-edited into the file is complained about and then
        // ignored, which leaves the Mac's answer standing rather than a
        // window nobody can read.
        #expect(InterfaceLanguage.choose(configured: "klingon", preferred: ["ru-RU"]) == .russian)
        #expect(InterfaceLanguage.choose(configured: "", preferred: ["ru-RU"]) == .russian)
    }

    /// The suite reads windows by the English they contain — "Keep the audio
    /// after transcribing", "Setup…", "Meetings are mostly in" — and it finds
    /// them on any Mac in any country because nothing in a test process ever
    /// resolves the language from the machine. Said out loud, because it is
    /// the sort of assumption that is only noticed when the suite fails
    /// somewhere else.
    @Test("A test process is in English, whatever the Mac it runs on is in")
    func testsAreEnglish() {
        #expect(InterfaceLanguage.current == .english)
    }

    /// The one that would actually catch a sentence left untranslated.
    ///
    /// A table of keys can only promise that every key has both columns; it
    /// cannot promise that a window went through the table at all. So build
    /// the form twice, once in each language, and walk it: every string a
    /// person can read has to have changed, except the ones that are the same
    /// in both languages on purpose — names, prices in dollars, paths, and
    /// the meeting languages, which are named in themselves and never
    /// translated.
    @Test("Nothing in the setup form is left in English when the form is Russian")
    @MainActor
    func theFormIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) { Self.readable(SetupForm()) }
        let russian = Self.inLanguage(.russian) { Self.readable(SetupForm()) }

        #expect(english.count == russian.count, "the two forms are not the same form")
        var untranslated: [String] = []
        for (before, after) in zip(english, russian)
        where before == after && !Self.sameInBothLanguages(before) {
            untranslated.append(before)
        }
        #expect(untranslated.isEmpty, "still English in a Russian window: \(untranslated)")
    }

    /// And the same question of the status window, which the walk above does
    /// not reach and which is the window a person actually keeps open.
    ///
    /// It says almost nothing until it is spoken to — the recorder's state,
    /// the live session's status, who is talking — so building one and
    /// reading it proves only that its checkboxes were translated. Drive it
    /// through every state it has instead, and read it after each.
    @Test("Nothing in the status window is left in English when the window is Russian")
    @MainActor
    func theStatusWindowIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) { Self.readableStatusWindow() }
        let russian = Self.inLanguage(.russian) { Self.readableStatusWindow() }

        #expect(english.count == russian.count, "the two windows are not the same window")
        var untranslated: [String] = []
        for (before, after) in zip(english, russian)
        where before == after && !Self.sameInBothLanguages(before) {
            untranslated.append(before)
        }
        #expect(untranslated.isEmpty, "still English in a Russian window: \(untranslated)")
    }

    /// And the same question of the Advanced tab, which is written from
    /// `SettingsSchema` rather than by hand. No window needed: the schema is
    /// the list, and the window renders it whole.
    @Test("Every setting's label and description are translated too")
    func theSchemaIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) { Self.readable(SettingsSchema.sections) }
        let russian = Self.inLanguage(.russian) { Self.readable(SettingsSchema.sections) }

        #expect(english.count == russian.count)
        var untranslated: [String] = []
        for (before, after) in zip(english, russian) where before == after {
            untranslated.append(before)
        }
        #expect(untranslated.isEmpty, "still English under Advanced: \(untranslated)")
    }

    /// The footer sentence and the button under it, which are computed rather
    /// than written into a view and would otherwise be missed by the walk
    /// above.
    @Test("What is outstanding is said in the window's own language")
    @MainActor
    func theOutstandingSentenceIsTranslated() {
        #expect(Self.inLanguage(.english) { SetupForm.sentence(for: []) }
            == "Everything amanu needs is granted.")
        #expect(Self.inLanguage(.russian) { SetupForm.sentence(for: []) }
            == "Всё, что нужно amanu, разрешено.")

        // A name stays a name in either language; what surrounds it does not.
        let left = Self.inLanguage(.russian) {
            SetupForm.sentence(for: [.parakeet, .microphone])
        }
        #expect(left == "Осталось: parakeet, микрофон")
    }

    // MARK: - the machinery of the two above

    /// The models on disk are the one block on that tab written by hand
    /// rather than rendered from the schema, so the test above walks straight
    /// past them.
    @Test("The models-on-disk block is in the window's language too")
    @MainActor
    func theModelsBlockIsTranslated() {
        let english = Self.inLanguage(.english) { SettingsWindow().modelLines }
        let russian = Self.inLanguage(.russian) { SettingsWindow().modelLines }

        #expect(english.count == russian.count)
        var untranslated: [String] = []
        for (before, after) in zip(english, russian)
        where before == after && !Self.sameInBothLanguages(before) {
            untranslated.append(before)
        }
        #expect(untranslated.isEmpty, "still English under Advanced: \(untranslated)")
    }

    /// A size is half number and half word, and the word is not the only
    /// thing that changes: Russian writes the decimal separator the other
    /// way, and `String(format:)` does not know that.
    @Test("Model sizes are written the way each language writes them")
    func sizesAreTranslated() {
        #expect(Self.inLanguage(.english) { ModelStorage.describe(bytes: 461 * 1_048_576) }
            == "461 MB")
        #expect(Self.inLanguage(.russian) { ModelStorage.describe(bytes: 461 * 1_048_576) }
            == "461 МБ")
        #expect(Self.inLanguage(.english) { ModelStorage.describe(bytes: 1_147_483_648) }
            == "1.1 GB")
        #expect(Self.inLanguage(.russian) { ModelStorage.describe(bytes: 1_147_483_648) }
            == "1,1 ГБ")
    }

    /// Every state the status window has, read after each one.
    ///
    /// The speech itself is `amanu` throughout: what was said in a meeting is
    /// not amanu's to translate, so a sentence that differed between the two
    /// runs would be the test lying about what it checks, and one that did
    /// not differ would be reported as untranslated. A name is neither.
    @MainActor
    private static func readableStatusWindow() -> [String] {
        _ = NSApplication.shared
        let window = StatusWindow()
        var found: [String] = []
        func read() {
            guard let view = window.view else { return }
            view.layoutSubtreeIfNeeded()
            found.append(contentsOf: strings(in: view))
        }

        for state in [MenuBarController.State.idle, .recording, .paused] {
            window.update(state: state, elapsed: "1:23")
            read()
        }
        window.updateTranscription(nil)
        window.updateAutoRecord(enabled: true, decision: nil)

        var transcript = LiveTranscriptState()
        transcript.beginRecording(enabled: true)
        transcript.applyPartial(
            speaker: .you, text: "amanu", startMilliseconds: 0, epoch: transcript.epoch)
        transcript.setEnabled(false)
        transcript.setEnabled(true)
        transcript.applyPartial(
            speaker: .them, text: "amanu", startMilliseconds: 10, epoch: transcript.epoch)

        func snapshot(
            recording: Bool, status: LiveTranscriptionCoordinator.Status
        ) -> LiveTranscriptionCoordinator.Snapshot {
            LiveTranscriptionCoordinator.Snapshot(
                isRecording: recording, isEnabled: true,
                entries: transcript.entries, status: status)
        }

        // A failure carries a message from CoreML, which arrives in whatever
        // language CoreML wrote it in; only the words around it are amanu's.
        let statuses: [LiveTranscriptionCoordinator.Status] = [
            .idle, .paused, .loading, .live, .modelMissing, .overloaded, .error("CoreML"),
        ]
        for status in statuses {
            window.updateLive(snapshot(recording: true, status: status))
            read()
        }

        // And after the recording, where the folded-away transcript keeps a
        // link back to itself — first the link, then what it says once the
        // text is showing again.
        window.updateLive(snapshot(recording: false, status: .idle))
        read()
        for view in window.view?.allDescendants ?? []
        where view.identifier?.rawValue == "live-reveal" {
            (view as? NSButton)?.performClick(nil)
        }
        read()
        return found
    }

    private static func inLanguage<T>(_ language: InterfaceLanguage, _ body: () -> T) -> T {
        let previous = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = previous }
        return body()
    }

    /// Everything in the form a person can read, in the order the views are
    /// in — which is the same order in both languages, because it is the same
    /// form built twice.
    @MainActor
    private static func readable(_ form: SetupForm) -> [String] {
        form.view.layoutSubtreeIfNeeded()
        return [form.nextActionTitle, form.outstandingSentence] + strings(in: form.view)
    }

    /// Everything a person can read inside a view, in the order the views are
    /// in. `NSTextView` is in the list for the live transcript, which is the
    /// one place amanu writes running text into a window rather than a label.
    @MainActor
    private static func strings(in root: NSView) -> [String] {
        var found: [String] = []
        for view in root.allDescendants {
            switch view {
            case let field as NSTextField:
                found.append(field.stringValue)
                found.append(field.placeholderString ?? "")
            case let popup as NSPopUpButton:
                found.append(contentsOf: popup.itemTitles)
            case let segmented as NSSegmentedControl:
                found.append(contentsOf: (0..<segmented.segmentCount).map {
                    segmented.label(forSegment: $0) ?? ""
                })
            case let button as NSButton:
                found.append(button.title)
            case let text as NSTextView:
                // Line by line rather than whole. A transcript is one string
                // with several sentences in it, and comparing it whole lets a
                // line left in English hide behind a line beside it that was
                // translated — which is exactly what "You" and "Them" did.
                found.append(contentsOf: text.string.components(separatedBy: "\n"))
            default:
                break
            }
        }
        return found
    }

    private static func readable(_ sections: [SettingsSchema.Section]) -> [String] {
        sections.flatMap { section in
            [section.title] + section.entries.flatMap { [$0.label, $0.help] }
        }
    }

    /// The strings that are deliberately the same in both languages.
    private static func sameInBothLanguages(_ text: String) -> Bool {
        if text.isEmpty { return true }
        // Names of things, and the shape of a key nobody translates.
        let names = [
            "AssemblyAI", "OpenAI", "Anthropic", "Claude Code", "Codex", "Ollama",
            "sk-ant-…", "sk-…", "amanu",
            // The models, named the way their release notes name them.
            "parakeet v3", "parakeet v2", "NVIDIA nemotron",
        ]
        if names.contains(text) { return true }
        // The meeting languages are named in themselves — English, Русский,
        // Deutsch — because that answers "what is spoken here", not "what is
        // this window in". See `MeetingLanguages`.
        if MeetingLanguages.menu.contains(where: { $0.name == text }) { return true }
        // A path is a path.
        if text.hasPrefix("~/") || text.hasPrefix("/") { return true }
        return false
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
