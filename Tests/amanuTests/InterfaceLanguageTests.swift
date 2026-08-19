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
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian window: \(Self.untranslated(english, russian))")
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
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian window: \(Self.untranslated(english, russian))")
    }

    /// The menu in the top-right corner, which is the surface amanu is
    /// mostly used from and the only one a `.accessory` launch has at all.
    /// Two of its items come and go and one line of it is not in the menu but
    /// beside the icon, so the walk turns everything on and reads that too.
    @Test("Nothing in the menu bar is left in English when the menu is Russian")
    @MainActor
    func theMenuBarIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) { Self.readableMenuBar() }
        let russian = Self.inLanguage(.russian) { Self.readableMenuBar() }

        #expect(english.count == russian.count, "the two menus are not the same menu")
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian menu: \(Self.untranslated(english, russian))")
    }

    /// And the application's own menu, which is a different menu built
    /// somewhere else — ⌘, and ⌘Q live there, and so does the Setup item that
    /// comes and goes.
    @Test("Nothing in the application menu is left in English when it is Russian")
    @MainActor
    func theApplicationMenuIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) {
            Self.titles(in: Run.mainMenu(settingsTarget: AppDelegate()))
        }
        let russian = Self.inLanguage(.russian) {
            Self.titles(in: Run.mainMenu(settingsTarget: AppDelegate()))
        }

        #expect(english.count == russian.count)
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian menu: \(Self.untranslated(english, russian))")
    }

    /// And the recordings window, whose words depend on what is on the disk.
    /// It is given a disk of its own: two sessions made for the occasion, one
    /// finished and one that never got a transcript, so that both what a row
    /// says and what the panel under it says are read. Nothing here goes near
    /// the recordings a person actually made — those are their conversations.
    @Test("Nothing in the recordings window is left in English when it is Russian")
    @MainActor
    func theRecordingsWindowIsAllInOneLanguage() throws {
        let root = try Self.recordingsOnADiskOfTheirOwn()
        defer { try? FileManager.default.removeItem(at: root) }

        let english = Self.inLanguage(.english) { Self.readableRecordings(in: root) }
        let russian = Self.inLanguage(.russian) { Self.readableRecordings(in: root) }

        #expect(english.count == russian.count, "the two windows are not the same window")
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian window: \(Self.untranslated(english, russian))")
    }

    /// And the About window, which is four sentences and three links and is
    /// read in one go — nothing in it changes after it is built.
    @Test("Nothing in the About window is left in English when it is Russian")
    @MainActor
    func theAboutWindowIsAllInOneLanguage() {
        let english = Self.inLanguage(.english) { Self.readableAbout() }
        let russian = Self.inLanguage(.russian) { Self.readableAbout() }

        #expect(english.count == russian.count, "the two windows are not the same window")
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English in a Russian window: \(Self.untranslated(english, russian))")
    }

    /// The one link in amanu whose address depends on the language: the
    /// studio has a site in each, and an English window sending a person to
    /// the Russian one would be sending them to a page they cannot read. The
    /// other two are one page each and stay where they are.
    @Test("«Order custom development» goes to the site in the window's language")
    @MainActor
    func theStudioLinkFollowsTheLanguage() {
        #expect(Self.inLanguage(.english) { AboutWindow().offeredLinks.map(\.url) }
            == ["https://samat.me", "https://github.com/gsamat/amanu", "https://fans.dev"])
        #expect(Self.inLanguage(.russian) { AboutWindow().offeredLinks.map(\.url) }
            == ["https://samat.me", "https://github.com/gsamat/amanu", "https://fansdev.ru"])
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
        #expect(Self.untranslated(english, russian).isEmpty,
                "still English under Advanced: \(Self.untranslated(english, russian))")
    }

    /// The transcript's speaker keys, which the recordings window draws in
    /// its own language while the files keep theirs.
    ///
    /// The walk above sees the left-hand column of that window, but not the
    /// quotation above it — that view is skipped, because what was said in a
    /// meeting is not amanu's to translate, and the label in front of each
    /// quoted line goes through here too.
    @Test("A voice is named in the window's language and keyed in the file's")
    func speakerKeysAreTranslated() {
        #expect(Self.inLanguage(.english) { SpeakerNames.described(label: "me") } == "me")
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "me") } == "я")
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "them") } == "они")

        // The letter is what tells two far-end voices apart, and it is the
        // same letter in the file — which is how somebody reading
        // `transcript.md` finds the row this window is talking about.
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "them A") } == "они A")
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "me B") } == "я B")

        // A name is not a key and is left exactly as it is.
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "Фёдор") } == "Фёдор")
        #expect(Self.inLanguage(.russian) { SpeakerNames.described(label: "Sam") } == "Sam")

        // And the quotation above the samples names its speakers the same way.
        let transcript = Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-08-18T09:31:00Z",
            segments: [.init(speaker: "them A", start_ms: 0, end_ms: 1, text: "…")])
        #expect(Self.inLanguage(.russian) {
            SessionInventory.opening(of: transcript, names: nil)
        } == "они A: …")
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

    /// The pairs that came out the same in both languages and had no
    /// business doing so.
    ///
    /// Phrase by phrase rather than label by label. Almost everything in
    /// these windows is several independent phrases with a separator between
    /// them — a transcript is lines, a provenance line is "who said so · how
    /// many turns" — and comparing them whole lets a phrase left in English
    /// hide behind a translated phrase beside it. That is how `You` and
    /// `Them` survived a translation, and how `manual` did after them.
    private static func untranslated(_ english: [String], _ russian: [String]) -> [String] {
        zip(english, russian).flatMap { before, after -> [String] in
            let left = parts(of: before), right = parts(of: after)
            // A label that came apart into a different number of pieces was
            // translated; there is nothing to compare piece by piece.
            guard left.count == right.count else { return [] }
            return zip(left, right)
                .filter { $0 == $1 && !sameInBothLanguages($0) }
                .map(\.0)
        }
    }

    private static func parts(of text: String) -> [String] {
        text.components(separatedBy: "\n").flatMap { $0.components(separatedBy: " · ") }
    }

    /// Every state the menu bar item has, read after each. The two lines that
    /// are filled in from outside — what is being transcribed, and why
    /// auto-record last did what it did — are given amanu's own name, because
    /// a fake sentence would either differ between the runs for a reason that
    /// is not translation or be reported as English left behind.
    @MainActor
    private static func readableMenuBar() -> [String] {
        _ = NSApplication.shared
        let menuBar = MenuBarController()
        menuBar.updatesAvailable(true)
        menuBar.setupAvailable(true)
        menuBar.updateAutoRecord(enabled: true, decision: "amanu")

        var found: [String] = []
        for state in [MenuBarController.State.idle, .recording, .paused] {
            menuBar.update(state: state, elapsed: "1:23")
            for status: TranscriptionCoordinator.Status in [
                .idle, .transcribing(session: "amanu", queued: 0),
                .transcribing(session: "amanu", queued: 2), .failed(session: "amanu"),
            ] {
                menuBar.updateTranscription(AppController.transcriptionLine(for: status))
                found.append(contentsOf: menuBar.offeredItemTitles)
                found.append(menuBar.statusItemTitle)
            }
        }
        return found
    }

    /// Everything the About window says, its title included — that one is
    /// not inside the content view, and it is a sentence like the rest.
    @MainActor
    private static func readableAbout() -> [String] {
        _ = NSApplication.shared
        let about = AboutWindow()
        guard let view = about.view else { return [about.title] }
        view.layoutSubtreeIfNeeded()
        return [about.title] + strings(in: view)
    }

    /// What a menu shows. An item that carries a submenu shows the submenu's
    /// title rather than its own — the two items at the top of the main menu
    /// are called `NSMenuItem` and nobody has ever seen it.
    private static func titles(in menu: NSMenu) -> [String] {
        [menu.title] + menu.items.flatMap { item in
            item.submenu.map { titles(in: $0) } ?? [item.title]
        }
    }

    /// Two sessions in a directory of the suite's own making: one with a
    /// transcript, a name somebody typed and a summary, and one that was
    /// recorded and never transcribed. Between them they reach every state
    /// the list has words for.
    private static func recordingsOnADiskOfTheirOwn() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-language-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func session(_ name: String, transcript: Bool) throws -> URL {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "started": "2026-08-18T09:00:00Z",
                "duration_seconds": 1800,
                "title": "amanu",
                "trigger": "mic-activity",
            ]).write(to: dir.appendingPathComponent("meta.json"))
            guard transcript else { return dir }
            try JSONEncoder().encode(Transcript(
                engine: "parakeet", model: "v3", created_at: "2026-08-18T09:31:00Z",
                segments: [
                    .init(speaker: "me", start_ms: 0, end_ms: 2000, text: "amanu"),
                    .init(speaker: "them A", start_ms: 2000, end_ms: 4000, text: "amanu"),
                ]
            )).write(to: dir.appendingPathComponent("transcript.json"))
            try SpeakerNames(speakers: ["them A": .init(name: "amanu", source: .manual)])
                .write(to: dir)
            try Data("# amanu\n".utf8).write(to: dir.appendingPathComponent("summary.md"))
            return dir
        }
        _ = try session("2026-08-18-090000-done", transcript: true)
        _ = try session("2026-08-18-100000-bare", transcript: false)
        return root
    }

    /// The window with nothing chosen — where it says so — and then with each
    /// recording chosen, which is where the panel underneath fills in.
    @MainActor
    private static func readableRecordings(in root: URL) -> [String] {
        _ = NSApplication.shared
        let window = RecordingsWindow(root: root)
        var found: [String] = []
        func read() {
            found.append(contentsOf: window.listLines)
            guard let view = window.view else { return }
            view.layoutSubtreeIfNeeded()
            found.append(contentsOf: strings(in: view))
        }
        read()
        for view in window.view?.allDescendants ?? [] {
            guard let table = view as? NSTableView, table.numberOfRows > 0 else { continue }
            for row in 0..<table.numberOfRows {
                table.selectRowIndexes([row], byExtendingSelection: false)
                read()
            }
        }
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
            // A view that shows what somebody said in a meeting says it in
            // the language they said it in. See `openingLabel`.
            if view.identifier?.rawValue == "meeting-words" { continue }
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
                found.append(text.string)
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
        // A menu indents a line by putting spaces in front of it. That is
        // layout rather than language.
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // A string with no letters in it — a date, a clock, two counts with a
        // slash between them — says the same thing in every language.
        if !text.contains(where: \.isLetter) { return true }
        return false
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
