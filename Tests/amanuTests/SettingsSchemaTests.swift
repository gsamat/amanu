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
        let language = Self.entry(.text(placeholder: "ru"), default: "the meeting's language")
        #expect(Self.stored(.text(""), language) == nil)
        #expect(Self.stored(.text("   "), language) == nil)
        #expect(Self.stored(.text(" ru "), language) as? String == "ru")

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text(""), delay) == nil)
    }

    @Test("Typing the default value back clears the key")
    func typedDefaultClears() {
        let model = Self.entry(.text(placeholder: "claude-opus-5"), default: "claude-opus-5")
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
    /// it and the documentation is generated from it — so a duplicated path
    /// means two controls quietly fighting over one key.
    @Test("Every setting has a distinct path")
    func pathsAreUnique() {
        let keys = SettingsSchema.knownKeys
        #expect(Set(keys).count == keys.count, "duplicate paths in the schema")
        #expect(!keys.isEmpty)
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
            "compress_tracks": true,
            "keep_uncompressed": false,
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
                "stop_delay_seconds": 90,
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
    @Test("Every setting in the schema gets a control")
    func rendersEverySetting() {
        _ = NSApplication.shared
        let window = SettingsWindow()
        let controls = window.renderedControls
        let entries = SettingsSchema.sections.flatMap(\.entries)

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
    /// the thing that lets the config file stay empty.
    @Test("Every field shows its default as a placeholder")
    func fieldsShowDefaults() {
        _ = NSApplication.shared
        let window = SettingsWindow()
        for (entry, control) in zip(SettingsSchema.sections.flatMap(\.entries),
                                    window.renderedControls) {
            guard let field = control as? NSTextField else { continue }
            #expect(!(field.placeholderString ?? "").isEmpty,
                    "\(entry.path) has no placeholder")
        }
    }
}
