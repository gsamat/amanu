import Foundation

/// Every setting amanu has, described once: where it lives in the config file,
/// what it does, what it defaults to, and whether changing it takes effect now
/// or at the next launch.
///
/// One list, two readers — the settings window renders it, and the config file
/// documentation is generated from it. The point is that nothing is secret: a
/// setting that exists but appears in no window and no README is a setting
/// nobody will ever find.
enum SettingsSchema {
    enum Kind {
        case toggle
        /// A fixed set of values, rendered as a pop-up.
        case choice([String])
        case number(unit: String)
        case text(placeholder: String)
        /// A comma-separated list, stored as an array of strings.
        case list
    }

    struct Entry {
        /// Path into the config JSON, e.g. `["auto_record", "start_delay_seconds"]`.
        let path: [String]
        let label: String
        /// One line saying what it does — in the window, under the control.
        let help: String
        let kind: Kind
        /// Rendered as the placeholder, so the default is visible without
        /// having to set it.
        let defaultValue: Any
        /// True when the value is only read at startup. Saying so beats a
        /// user changing a switch and quietly getting nothing.
        let needsRestart: Bool

        init(
            _ path: [String],
            _ label: String,
            _ help: String,
            _ kind: Kind,
            default defaultValue: Any,
            needsRestart: Bool = false
        ) {
            self.path = path
            self.label = label
            self.help = help
            self.kind = kind
            self.defaultValue = defaultValue
            self.needsRestart = needsRestart
        }
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    // A computed property rather than a stored one: the entries carry `Any`
    // defaults for display, which a global constant can't be under strict
    // concurrency checking, and building the list is free.
    static var sections: [Section] { [
        Section(title: "Recording by itself", entries: [
            Entry(["auto_record", "enabled"], "Record meetings automatically",
                  "Start and stop on their own when a call begins and ends.",
                  .toggle, default: true),
            Entry(["auto_record", "mic_activity"], "Start when a call app takes the mic",
                  "Fires for Zoom, Teams, Meet in a browser tab, Telegram — no per-app setup.",
                  .toggle, default: true),
            Entry(["auto_record", "calendar"], "Start from calendar events",
                  "Events with other attendees or a conference link. Needs calendar access.",
                  .toggle, default: false, needsRestart: true),
            Entry(["auto_record", "start_delay_seconds"], "Wait before starting",
                  "How long a call app must hold the microphone before this counts as a meeting.",
                  .number(unit: "seconds"), default: 12),
            Entry(["auto_record", "stop_delay_seconds"], "Wait before stopping",
                  "How long nobody may hold the mic, and the far end stay quiet, before it ends.",
                  .number(unit: "seconds"), default: 90),
            Entry(["auto_record", "min_duration_seconds"], "Discard recordings shorter than",
                  "A mic that opened for a few seconds was never a meeting. Automatic recordings only.",
                  .number(unit: "seconds"), default: 45),
            Entry(["auto_record", "silence_stop_minutes"], "Stop after silence on both tracks",
                  "The backstop against an app that never releases the microphone.",
                  .number(unit: "minutes"), default: 10),
            Entry(["auto_record", "max_duration_minutes"], "Hard duration ceiling",
                  "Applies to manual recordings too — whatever this is, it stopped being a meeting.",
                  .number(unit: "minutes"), default: 300),
            Entry(["auto_record", "apps"], "Call apps",
                  "Bundle-id prefixes that count as a call. Empty means any app that opens the mic.",
                  .list, default: "the known conferencing apps and browsers"),
            Entry(["auto_record", "ignore_apps"], "Never count these",
                  "Bundle ids or app names that never start a recording, whatever they do with the mic.",
                  .list, default: "empty"),
        ]),

        Section(title: "Audio", entries: [
            Entry(["system_audio"], "Record system audio from",
                  "app: only the call app's output. all: everything the Mac plays, music and notifications included.",
                  .choice(["app", "all"]), default: "app"),
            Entry(["mic_voice_processing"], "Cancel echo on the mic",
                  "For meetings played through speakers, so the far end isn't recorded onto your track as well. Ducks other playback while active; pointless on headphones.",
                  .toggle, default: true),
            Entry(["compress_tracks"], "Compress tracks after transcribing",
                  "Recording is uncompressed so it survives a crash — about a gigabyte an hour until the transcript exists.",
                  .toggle, default: true),
            Entry(["keep_uncompressed"], "Keep the uncompressed audio",
                  "Keeps the original PCM alongside the compressed tracks.",
                  .toggle, default: false),
            Entry(["recordings_dir"], "Recordings folder",
                  "Where sessions land.",
                  .text(placeholder: "~/Recordings"), default: "~/Recordings", needsRestart: true),
        ]),

        Section(title: "Transcription", entries: [
            Entry(["transcription", "enabled"], "Transcribe recordings",
                  "Off means record only; the on_stop hook still fires.",
                  .toggle, default: true),
            Entry(["transcription", "engine"], "Engine",
                  "auto: assemblyai when there's a key and the network answers, parakeet otherwise.",
                  .choice(["auto", "assemblyai", "parakeet"]), default: "auto"),
            Entry(["transcription", "language"], "Language",
                  "Two-letter code. Both engines do better told than guessing.",
                  .text(placeholder: "ru"), default: "unset — parakeet guesses, assemblyai auto-detects"),
            Entry(["transcription", "model"], "Parakeet model",
                  "v3 covers 25 European languages; v2 is English-only.",
                  .choice(["v3", "v2"]), default: "v3"),
            Entry(["transcript_echo_filter"], "Drop echoed speech",
                  "Removes mic segments duplicating system audio — the far end coming back through the speakers.",
                  .toggle, default: true),
        ]),

        Section(title: "Summaries", entries: [
            Entry(["summary", "enabled"], "Write a summary",
                  "Topic, key points, decisions, action items, open questions.",
                  .toggle, default: true),
            Entry(["summary", "backend"], "Which model to ask",
                  "auto walks the chain: claude CLI, Anthropic API, codex CLI, OpenAI API, ollama — subscriptions before metered keys.",
                  .choice(["auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama"]),
                  default: "auto"),
            Entry(["summary", "model"], "Anthropic model",
                  "Used on the API path. The CLI uses whatever model Claude Code is set to.",
                  .text(placeholder: "claude-opus-5"), default: "claude-opus-5"),
            Entry(["summary", "openai_model"], "OpenAI model",
                  "Used by the codex CLI and the OpenAI API.",
                  .text(placeholder: "gpt-5"), default: "gpt-5"),
            Entry(["summary", "ollama_model"], "Local model",
                  "The fully-offline fallback.",
                  .text(placeholder: "qwen3:8b"), default: "qwen3:8b"),
            Entry(["summary", "language"], "Summary language",
                  "Leave empty to write in whichever language the meeting was held in.",
                  .text(placeholder: "ru"), default: "the language of the meeting"),
        ]),

        Section(title: "Calendar and naming", entries: [
            Entry(["calendar"], "Read the calendar",
                  "Names sessions after the meeting and records attendees. Separate from starting recordings from events.",
                  .toggle, default: true, needsRestart: true),
        ]),

        Section(title: "Interface", entries: [
            Entry(["dock_icon"], "Show in the Dock",
                  "Off makes amanu a menu-bar-only accessory — which the menu bar hides when it runs out of room.",
                  .toggle, default: true, needsRestart: true),
            Entry(["window"], "Open the window at launch",
                  "The Dock icon opens it either way.",
                  .toggle, default: true, needsRestart: true),
            Entry(["on_stop"], "Run after each session",
                  "A shell command, given the session folder as its argument, after the transcript and summary are written.",
                  .text(placeholder: "my-hook"), default: "nothing"),
        ]),
    ] }

    /// Every key the program understands, as `a.b` strings — used to spot
    /// settings in a config file that nothing reads (a typo, or a key from an
    /// older version).
    static var knownKeys: [String] {
        sections.flatMap { $0.entries }.map { $0.path.joined(separator: ".") }
    }
}
