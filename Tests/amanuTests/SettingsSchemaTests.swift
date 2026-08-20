import AppKit
import Foundation
import Testing

@testable import amanu

/// The settings window's one non-obvious rule, tested without a window: a
/// value equal to the default is cleared rather than written, so the config
/// file keeps reading as a list of decisions and a default that improves later
/// still reaches the user.
struct SettingsSchemaTests {
    private static func entry(
        _ kind: SettingsSchema.Kind, default value: Any
    ) -> SettingsSchema.Entry {
        SettingsSchema.Entry(["x"], "X", "help", kind, default: value)
    }

    private static func stored(
        _ input: SettingsSchema.Input, _ entry: SettingsSchema.Entry
    ) -> Any? {
        switch SettingsSchema.resolve(input, for: entry) {
        case .set(let value): return value
        case .clear: return nil
        case .invalid: return "INVALID"
        }
    }

    @Test("Setting a toggle to its default clears the key instead of writing it")
    func toggleAtDefaultClears() {
        let onByDefault = Self.entry(.toggle, default: true)
        #expect(Self.stored(.flag(true), onByDefault) == nil)
        #expect(Self.stored(.flag(false), onByDefault) as? Bool == false)

        let offByDefault = Self.entry(.toggle, default: false)
        #expect(Self.stored(.flag(false), offByDefault) == nil)
        #expect(Self.stored(.flag(true), offByDefault) as? Bool == true)
    }

    /// Leaving a field is not deciding anything. Every one of these used to
    /// write the file back byte for byte, moving its timestamp and waking
    /// every open window, because editing ended — not because anybody typed.
    @Test("A row still showing what is stored commits nothing")
    func unchangedRowsCommitNothing() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("ru"), for: language), from: "ru"))

        let onByDefault = Self.entry(.toggle, default: true)
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.flag(false), for: onByDefault), from: false))

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("30"), for: delay), from: 30))

        let apps = Self.entry(.list, default: "empty")
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("zoom, teams"), for: apps), from: ["zoom", "teams"]))
    }

    /// The other half, and the one that would go unnoticed: a guard against
    /// pointless writes must not swallow a real edit.
    @Test("An edited row, and a row falling back to its default, both commit")
    func changedRowsCommit() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text("de"), for: language), from: "ru"))
        // Emptied: the key goes away, which is a change when it was there.
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text(""), for: language), from: "ru"))
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text(""), for: language), from: nil))

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text("45"), for: delay), from: 30))
        // Unusable input changes nothing by definition; the window puts the
        // stored value back instead.
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("soon"), for: delay), from: 30))
    }

    @Test("Choosing the default option clears the key")
    func choiceAtDefaultClears() {
        let engine = Self.entry(.choice(["auto", "assemblyai", "parakeet"]), default: "auto")
        #expect(Self.stored(.choice("auto"), engine) == nil)
        #expect(Self.stored(.choice("parakeet"), engine) as? String == "parakeet")
    }

    /// A pop-up can't produce a title it doesn't have, but the rule is what a
    /// future caller would rely on, and silently writing an unknown engine
    /// name is how a config ends up meaning nothing.
    @Test("An option that isn't in the list is refused")
    func unknownChoiceRefused() {
        let engine = Self.entry(.choice(["auto", "parakeet"]), default: "auto")
        #expect(Self.stored(.choice("whisper"), engine) as? String == "INVALID")
    }

    @Test("An emptied field means unset, not empty")
    func emptyFieldClears() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(Self.stored(.text(""), language) == nil)
        #expect(Self.stored(.text("   "), language) == nil)
        #expect(Self.stored(.text(" ru "), language) as? String == "ru")

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text(""), delay) == nil)
    }

    @Test("Typing the default value back clears the key")
    func typedDefaultClears() {
        let model = Self.entry(.text, default: "claude-opus-5")
        #expect(Self.stored(.text("claude-opus-5"), model) == nil)
        #expect(Self.stored(.text("claude-sonnet-5"), model) as? String == "claude-sonnet-5")

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text("12"), delay) == nil)
        #expect(Self.stored(.text(" 30 "), delay) as? Int == 30)
    }

    /// The field would otherwise write 0, or an empty key, and the recorder
    /// would wait zero seconds before deciding a mic blip was a meeting.
    @Test("Letters in a number field change nothing")
    func garbageNumberRefused() {
        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text("soon"), delay) as? String == "INVALID")
        #expect(Self.stored(.text("12s"), delay) as? String == "INVALID")
    }

    @Test("A list comes apart on commas and drops the gaps")
    func listSplitsOnCommas() {
        let apps = Self.entry(.list, default: "the known conferencing apps")
        #expect(Self.stored(.text("us.zoom.xos, com.tinyspeck.slackmacgap"), apps) as? [String]
            == ["us.zoom.xos", "com.tinyspeck.slackmacgap"])
        #expect(Self.stored(.text("us.zoom.xos,,  ,"), apps) as? [String] == ["us.zoom.xos"])
        #expect(Self.stored(.text("  "), apps) == nil)
    }

    /// The schema is the only list of settings there is — the window renders
    /// it and the README is written against it — so a duplicated path means
    /// two controls quietly fighting over one key.
    @Test("Every setting has a distinct path")
    func pathsAreUnique() {
        let keys = SettingsSchema.knownKeys
        #expect(Set(keys).count == keys.count, "duplicate paths in the schema")
        #expect(!keys.isEmpty)
    }

    /// The eight settings the setup form asks in full, and therefore the eight
    /// the Advanced tab leaves out. Written down rather than derived, because
    /// there is nothing to derive it from: setup asks these through cards,
    /// switches and an open panel, in its own vocabulary, and no signature in
    /// `SetupForm` says which config key a card stands for.
    ///
    /// So this is a canary, and it is worth having as one. Dropping a control
    /// from setup without clearing its flag here does not break a build or
    /// fail a test elsewhere — it removes the setting from the window
    /// altogether, which is the one failure this schema exists to prevent, and
    /// the one nobody notices until somebody goes looking for a setting that
    /// is no longer anywhere.
    @Test("The settings held back from Advanced are the ones setup asks")
    func setupCoversWhatAdvancedOmits() {
        let held = Set(SettingsSchema.sections
            .flatMap(\.entries)
            .filter(\.askedInSetup)
            .map { $0.path.joined(separator: ".") })
        #expect(held == [
            // The switch at the foot of the form.
            "auto_record.enabled",
            // Both transcription switches off.
            "transcription.enabled",
            // The two switches, "In the cloud" and "On this Mac".
            "transcription.engine",
            // The AssemblyAI and OpenAI cards under the cloud switch.
            "transcription.cloud",
            // The live-transcript switch — Apple Silicon only, on both sides.
            "live_transcription.enabled",
            // Files: the switch, and the folder chosen with an open panel.
            "keep_audio",
            "recordings_dir",
            // The switch beside the Summaries heading.
            "summary.enabled",
        ])
    }

    /// The two that stay on both tabs, and why: setup asks them, but cannot
    /// say everything the schema allows. The language menu offers parakeet's
    /// 25 European languages while the cloud engines understand more, and the
    /// summary cards have no card for `none`. Flagging either would leave a
    /// legal value reachable only by editing the config file by hand.
    @Test("A setting setup asks only partly is still asked in Advanced")
    func partialCoverageStaysInAdvanced() {
        let advanced = Set(SettingsSchema.advancedSections
            .flatMap(\.entries)
            .map { $0.path.joined(separator: ".") })
        #expect(advanced.contains("transcription.language"))
        #expect(advanced.contains("summary.backend"))

        // The claim about the menu, checked rather than asserted: a menu that
        // grew to every language the cloud takes would make the field above
        // redundant after all.
        let offered = Set(MeetingLanguages.menu.map(\.code))
        #expect(!offered.contains("ja"), "the meeting-language menu now covers more than parakeet")
        // And the claim about the cards: every card setup offers, resolved
        // through the translation the form uses, and none of them is `none`.
        let cards = ["claude-cli", "codex-cli", "api-key", "ollama"]
        let reachable = cards.flatMap { card in
            ["anthropic-api", "openai-api"].compactMap {
                SetupSelection.summaryBackend(choice: card, keyBackend: $0)
            }
        }
        #expect(!reachable.contains("none"), "a summary card now writes none after all")
    }

    /// The list that tells someone a setting is being ignored has to be right
    /// in one direction above all: a key amanu *does* read must never appear
    /// in it. It did — `transcription.assemblyai.*` and the two summary key
    /// paths had no entry, so a config written straight from the README was
    /// reported as unread.
    ///
    /// The sample below is every key `Config` reads, which is what the README
    /// documents. Adding a setting to `Config` without adding it here is the
    /// mistake this catches.
    @Test("No setting amanu reads is reported as one it ignores")
    func everySettingConfigReadsIsKnown() {
        let config: [String: Any] = [
            "recordings_dir": "~/Recordings",
            "on_stop": "my-hook",
            "mic_voice_processing": true,
            "transcript_echo_filter": true,
            "system_audio": "app",
            "calendar": true,
            "dock_icon": true,
            "window": true,
            "user_name": "Samat Galimov",
            "transcription": [
                "enabled": true,
                "engine": "auto",
                "model": "v3",
                "language": "ru",
                "assemblyai": [
                    "api_key": "secret",
                    "api_key_path": "~/.config/assemblyai/token",
                    "speech_model": "best",
                ],
            ],
            "live_transcription": ["enabled": true],
            "auto_record": [
                "enabled": true,
                "mic_activity": true,
                "calendar": false,
                "start_delay_seconds": 12,
                "stop_delay_seconds": 15,
                "min_duration_seconds": 45,
                "max_duration_minutes": 300,
                "silence_stop_minutes": 10,
                "apps": ["us.zoom"],
                "ignore_apps": [],
            ],
            "speaker_names": ["enabled": true, "backend": "auto", "model": "claude-sonnet-5"],
            "summary": [
                "enabled": true,
                "backend": "auto",
                "language": "ru",
                "model": "claude-opus-5",
                "openai_model": "gpt-5",
                "ollama_model": "qwen3:8b",
                "api_key_path": "~/.config/anthropic/token",
                "openai_api_key_path": "~/.config/openai/token",
            ],
        ]
        #expect(SettingsSchema.strayKeys(in: config).isEmpty,
                "reported as unread: \(SettingsSchema.strayKeys(in: config))")
    }

    /// The settings window on an Intel Mac renders neither of these — there is
    /// no local model behind them — but the config file may well carry them,
    /// and telling somebody their working setting is ignored is the one
    /// direction this list must never fail in.
    @Test("Settings only shown on Apple Silicon are still known keys")
    func localModelKeysAreNeverStray() {
        let config: [String: Any] = [
            "live_transcription": ["enabled": true],
            "transcription": ["model": "v3"],
        ]
        #expect(SettingsSchema.strayKeys(in: config).isEmpty,
                "reported as unread: \(SettingsSchema.strayKeys(in: config))")
    }

    /// The other direction, which is the point of the list existing.
    @Test("A key nothing reads is named, nested or not")
    func strayKeysAreReported() {
        let config: [String: Any] = [
            "recordings_dir": "~/Recordings",
            "recordings_directory": "~/Meetings",
            "transcription": ["enabled": true, "engien": "auto"],
            "summarize": ["enabled": true],
        ]
        #expect(SettingsSchema.strayKeys(in: config)
            == ["recordings_directory", "summarize", "transcription.engien"])
    }

    @Test("Removed audio-format keys stay accepted for old config files")
    func removedAudioKeysAreNotReportedAsTypos() {
        let oldConfig: [String: Any] = [
            "compress_tracks": false,
            "keep_uncompressed": true,
        ]
        #expect(SettingsSchema.strayKeys(in: oldConfig).isEmpty)
    }

    /// An inline API key is the one setting with no control, and the reason is
    /// that a text field would put a secret on screen. It still has to count
    /// as read.
    @Test("The unrendered inline key is known but has no control")
    func unrenderedKeysStayKnown() {
        let rendered = Set(SettingsSchema.sections
            .flatMap(\.entries)
            .map { $0.path.joined(separator: ".") })
        for key in SettingsSchema.unrenderedKeys {
            #expect(!rendered.contains(key), "\(key) has a control after all")
            #expect(SettingsSchema.knownKeys.contains(key))
        }
    }

    /// A default of the wrong type would render as a placeholder saying one
    /// thing and compare as another — the control would never clear, and the
    /// file would collect a key holding the default forever.
    @Test("Toggle and number defaults have the type their control expects")
    func defaultsMatchTheirKind() {
        for section in SettingsSchema.sections {
            for entry in section.entries {
                switch entry.kind {
                case .toggle:
                    #expect(entry.defaultValue is Bool, "\(entry.path) toggle default isn't a Bool")
                case .number:
                    #expect(entry.defaultValue is Int, "\(entry.path) number default isn't an Int")
                case .choice(let options):
                    // A default outside its own option list can't be selected,
                    // so the pop-up would open on something else and the first
                    // change would write a value that was already in effect.
                    let value = entry.defaultValue as? String
                    #expect(value != nil && options.contains(value!),
                            "\(entry.path) default isn't one of its options")
                case .text, .list:
                    #expect(entry.defaultValue is String,
                            "\(entry.path) default should be shown as text")
                }
            }
        }
    }
}

/// The window itself, built headlessly. It can't be clicked here, but "does it
/// open at all" and "does every setting reach it" are the two ways this window
/// fails invisibly — a setting present in the code and absent from the window
/// is one nobody will ever find.
@MainActor
struct SettingsWindowTests {
    @Test("Every setting the Advanced tab is for gets a control")
    func rendersEverySetting() {
        _ = NSApplication.shared
        let window = SettingsWindow()
        let controls = window.renderedControls
        let entries = SettingsSchema.advancedSections.flatMap(\.entries)

        #expect(controls.count == entries.count)
        for (entry, control) in zip(entries, controls) {
            switch entry.kind {
            case .toggle:
                #expect(control is NSSwitch, "\(entry.path) should be a switch")
            case .choice(let options):
                let popup = control as? NSPopUpButton
                #expect(popup != nil, "\(entry.path) should be a pop-up")
                #expect(popup?.itemTitles == options, "\(entry.path) is missing options")
            case .number, .text, .list:
                #expect(control is NSTextField, "\(entry.path) should be a text field")
            }
        }
    }

    /// Placeholders are how a default is visible without being set, which is
    /// the thing that lets the config file stay empty. Not merely present —
    /// the *default*: a placeholder showing a plausible example instead is how
    /// the Language field spent a version implying its default was `ru` when
    /// leaving it alone lets the engine detect what it hears.
    @Test("Every field shows its own default as a placeholder")
    func fieldsShowDefaults() {
        _ = NSApplication.shared
        let window = SettingsWindow()
        for (entry, control) in zip(SettingsSchema.advancedSections.flatMap(\.entries),
                                    window.renderedControls) {
            guard let field = control as? NSTextField else { continue }
            #expect(field.placeholderString == SettingsSchema.describeDefault(entry),
                    "\(entry.path) doesn't show its default as its placeholder")
            #expect(!(field.placeholderString ?? "").isEmpty,
                    "\(entry.path) has no placeholder")
        }
    }
}

/// The README is the third place a setting has to appear, and the only one no
/// compiler checks.
///
/// `SettingsSchema` says of itself that nothing is secret: a setting that
/// exists but appears in no window and no README is a setting nobody will
/// find. The window half is enforced — `SettingsWindowTests` renders the
/// schema and counts the controls. The README half was enforced by a comment
/// claiming the documentation was generated from the schema, which it never
/// was: `README.md` is written by hand, and a setting added to the schema
/// today reaches the window automatically and the README only if somebody
/// remembers. This is that somebody.
@Suite("Every setting is documented")
struct SettingsDocumentationTests {
    /// The repository root, found from this file rather than from the working
    /// directory, which `swift test` does not promise anything about.
    static var readme: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // amanuTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
            return try String(
                contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        }
    }

    /// A key counts as documented when the README names it — either in full
    /// (`auto_record.start_delay_seconds`) or as a leaf under a group the
    /// README documents wholesale (`summary.*` covering `openai_model`). The
    /// second form is how the README actually reads, and demanding the first
    /// would fail on prose that is already correct.
    @Test("Every setting in the schema is named in the README")
    func everySettingIsInTheReadme() throws {
        let readme = try Self.readme
        var undocumented: [String] = []

        for entry in SettingsSchema.sections.flatMap({ $0.entries }) {
            let path = entry.path.joined(separator: ".")
            if readme.contains(path) { continue }

            let group = entry.path.dropLast().joined(separator: ".")
            let leaf = entry.path[entry.path.count - 1]
            if !group.isEmpty, readme.contains("`\(group).*`"), readme.contains(leaf) {
                continue
            }
            undocumented.append(path)
        }

        #expect(undocumented.isEmpty, "not in README.md: \(undocumented.joined(separator: ", "))")
    }

    /// And the other direction, for the keys that carry a secret. A key file
    /// path documented in the README that `Config` does not read sends someone
    /// to put their AssemblyAI token somewhere nothing looks — and the symptom
    /// is a meeting that failed to transcribe hours later.
    @Test("The key-file settings the README advertises are settings amanu reads")
    func keyPathsAreReal() throws {
        let readme = try Self.readme
        let advertised = [
            "transcription.assemblyai.api_key_path",
            "summary.api_key_path",
            "summary.openai_api_key_path",
        ]
        for key in advertised {
            #expect(readme.contains(key.components(separatedBy: ".").last!))
            #expect(SettingsSchema.knownKeys.contains(key), "\(key) is not a known setting")
        }
    }
}
