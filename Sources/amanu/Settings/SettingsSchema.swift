import Foundation

/// Every setting amanu has, described once: where it lives in the config file,
/// what it does, what it defaults to, and whether changing it takes effect now
/// or at the next launch.
///
/// One list, two readers — the settings window renders it, and the README's
/// config reference is written against it. The point is that nothing is
/// secret: a setting that exists but appears in no window and no README is a
/// setting nobody will ever find. The window follows automatically; the README
/// is prose, so `SettingsDocumentationTests` is what keeps it honest.
enum SettingsSchema {
    enum Kind {
        case toggle
        /// A fixed set of values, rendered as a pop-up.
        case choice([String])
        case number(unit: String)
        case text
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
        /// Rendered as the field's placeholder, so the default is visible
        /// without having to set it — which is what lets an untouched config
        /// file stay empty and still be readable.
        let defaultValue: Any
        /// True when the value is only read at startup. Saying so beats a
        /// user changing a switch and quietly getting nothing.
        let needsRestart: Bool
        /// True when the setup form already asks this, and asks it fully —
        /// every value the schema allows is reachable from a control there.
        /// Those settings are left out of the Advanced tab, which is the
        /// tab's whole premise: it is what setup doesn't ask. Asked twice in
        /// one window, in two vocabularies, they were two controls a person
        /// had to work out were the same control.
        ///
        /// It is `askedInSetup`, not `hidden`: the entry stays in the list,
        /// so `knownKeys` still knows it, the README still has to document
        /// it, and the config file still reads as a record of decisions.
        /// Partial coverage does not count — the meeting language menu
        /// offers parakeet's 25 languages and the cloud engines understand
        /// more, so that one is still asked here.
        let askedInSetup: Bool

        init(
            _ path: [String],
            _ label: String,
            _ help: String,
            _ kind: Kind,
            default defaultValue: Any,
            needsRestart: Bool = false,
            askedInSetup: Bool = false
        ) {
            self.path = path
            self.label = label
            self.help = help
            self.kind = kind
            self.defaultValue = defaultValue
            self.needsRestart = needsRestart
            self.askedInSetup = askedInSetup
        }
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    /// The settings that only exist where a local model can run. On Intel the
    /// window would otherwise show a live-transcript switch that does nothing
    /// and a choice of engines with only one real option in it — settings that
    /// lie are worse than settings that are missing.
    private static var localModelEntries: [Entry] {
        guard Platform.supportsLocalModels else {
            return [
                Entry(["transcription", "engine"], localised("Engine", "Движок"),
                      localised(
                          "A cloud engine is the only one on an Intel Mac; parakeet needs Apple Silicon.",
                          "На маке с Intel есть только облачный движок: parakeet нужен Apple Silicon."),
                      .choice(["auto", "assemblyai", "openai"]), default: "auto", askedInSetup: true),
                Entry(["transcription", "cloud"], localised("Cloud engine", "Облачный движок"),
                      localised(
                          "Which service auto uploads to. assemblyai has no length limit; openai charges more.",
                          "Куда auto отправляет запись. У assemblyai нет предела длины, openai дороже."),
                      .choice(["assemblyai", "openai"]), default: "assemblyai", askedInSetup: true),
                Entry(["transcription", "language"], localised("Meeting language", "Язык встреч"),
                      localised(
                          "Two-letter code for what meetings are mostly in. English is expected "
                              + "alongside it; the engine still decides which it heard.",
                          "Двухбуквенный код языка, на котором в основном идут встречи. Вместе с ним "
                              + "ожидается английский, а какой язык прозвучал, решает сам движок."),
                      .text,
                      default: localised(
                          "detected from any language", "определяется, язык любой")),
            ]
        }
        return [
            Entry(["live_transcription", "enabled"],
                  localised("Show a live transcript", "Показывать расшифровку по ходу встречи"),
                  localised(
                      "Uses an additional local NVIDIA model while a meeting is being recorded.",
                      "Пока идёт запись, работает ещё одна местная модель NVIDIA."),
                  .toggle, default: false, askedInSetup: true),
            Entry(["transcription", "engine"], localised("Engine", "Движок"),
                  localised(
                      "auto: the cloud engine when there's a key and the network answers, parakeet otherwise.",
                      "auto — облачный движок, когда есть ключ и отвечает сеть, иначе parakeet."),
                  .choice(["auto", "assemblyai", "openai", "parakeet"]), default: "auto", askedInSetup: true),
            Entry(["transcription", "cloud"], localised("Cloud engine", "Облачный движок"),
                  localised(
                      "Which service auto uploads to. assemblyai has no length limit; openai charges more.",
                      "Куда auto отправляет запись. У assemblyai нет предела длины, openai дороже."),
                  .choice(["assemblyai", "openai"]), default: "assemblyai", askedInSetup: true),
            Entry(["transcription", "language"], localised("Meeting language", "Язык встреч"),
                  localised(
                      "Two-letter code for what meetings are mostly in. English is expected "
                          + "alongside it; both engines still decide which they heard.",
                      "Двухбуквенный код языка, на котором в основном идут встречи. Вместе с ним "
                          + "ожидается английский, а какой язык прозвучал, решают сами движки."),
                  .text,
                  default: localised(
                      "detected from any language", "определяется, язык любой")),
            Entry(["transcription", "model"], localised("Parakeet model", "Модель parakeet"),
                  localised(
                      "v3 covers 25 European languages; v2 is English-only.",
                      "v3 знает 25 европейских языков, v2 — только английский."),
                  .choice(["v3", "v2"]), default: "v3"),
        ]
    }

    // A computed property rather than a stored one: the entries carry `Any`
    // defaults for display, which a global constant can't be under strict
    // concurrency checking, and building the list is free.
    static var sections: [Section] { [
        Section(title: localised("Recording by itself", "Запись сама по себе"), entries: [
            Entry(["auto_record", "enabled"],
                  localised("Record meetings automatically", "Записывать встречи сама"),
                  localised(
                      "Start and stop on their own when a call begins and ends.",
                      "Запись начинается и заканчивается сама, вместе со звонком."),
                  .toggle, default: true, askedInSetup: true),
            Entry(["auto_record", "mic_activity"],
                  localised("Start when a call app takes the mic", "Начинать по микрофону"),
                  localised(
                      "Fires for Zoom, Teams, Meet in a browser tab, Telegram — no per-app setup.",
                      "Срабатывает на Zoom, Teams, Meet во вкладке браузера, Telegram — настраивать "
                          + "каждое приложение не нужно."),
                  .toggle, default: true),
            Entry(["auto_record", "calendar"],
                  localised("Start from calendar events", "Начинать по событиям календаря"),
                  localised(
                      "Events with other attendees or a conference link. Needs calendar access.",
                      "События с другими участниками или ссылкой на созвон. Нужен доступ к календарю."),
                  .toggle, default: false, needsRestart: true),
            Entry(["auto_record", "start_delay_seconds"],
                  localised("Wait before starting", "Ждать перед началом"),
                  localised(
                      "How long a call app must hold the microphone before this counts as a meeting.",
                      "Сколько приложение звонка должно держать микрофон, чтобы это считалось встречей."),
                  .number(unit: localised("seconds", "с")), default: 12),
            Entry(["auto_record", "stop_delay_seconds"],
                  localised("Wait before stopping", "Ждать перед остановкой"),
                  localised(
                      "How long nobody may hold the mic, and the far end stay quiet, before it ends.",
                      "Сколько никто не держит микрофон и молчит дальняя сторона, прежде чем встреча "
                          + "кончится."),
                  .number(unit: localised("seconds", "с")), default: 15),
            Entry(["auto_record", "min_duration_seconds"],
                  localised("Discard meetings shorter than", "Выбрасывать встречи короче"),
                  localised(
                      "A mic that opened for a few seconds was never a meeting. The wait before "
                          + "stopping doesn't count. Automatic recordings only.",
                      "Микрофон, открытый на несколько секунд, встречей не был. Ожидание перед "
                          + "остановкой не считается. Только для автоматических записей."),
                  .number(unit: localised("seconds", "с")), default: 45),
            Entry(["auto_record", "silence_stop_minutes"],
                  localised("Stop after silence on both tracks", "Останавливать после тишины на обеих дорожках"),
                  localised(
                      "The backstop against an app that never releases the microphone.",
                      "Страховка от приложения, которое так и не отпускает микрофон."),
                  .number(unit: localised("minutes", "мин")), default: 10),
            Entry(["auto_record", "max_duration_minutes"],
                  localised("Hard duration ceiling", "Жёсткий предел длительности"),
                  localised(
                      "Applies to manual recordings too — whatever this is, it stopped being a meeting.",
                      "Касается и ручных записей: что бы это ни было, встречей оно быть перестало."),
                  .number(unit: localised("minutes", "мин")), default: 300),
            Entry(["auto_record", "apps"], localised("Call apps", "Приложения для звонков"),
                  localised(
                      "Bundle-id prefixes that count as a call. Empty means any app that opens the mic.",
                      "Префиксы bundle id, которые считаются звонком. Пусто — любое приложение, "
                          + "открывшее микрофон."),
                  .list,
                  default: localised(
                      "known call apps and browsers", "известные звонилки и браузеры")),
            Entry(["auto_record", "ignore_apps"],
                  localised("Never count these", "Никогда не считать звонком"),
                  localised(
                      "Bundle ids or app names that never start a recording, whatever they do with the mic.",
                      "Bundle id или имена приложений, которые не начинают запись, что бы они ни "
                          + "делали с микрофоном."),
                  .list, default: localised("empty", "пусто")),
        ]),

        Section(title: localised("Audio", "Звук"), entries: [
            Entry(["system_audio"],
                  localised("Record system audio from", "Записывать звук системы"),
                  localised(
                      "app: only the call app's output. all: everything the Mac plays, music and notifications included.",
                      "app — только вывод приложения звонка. all — всё, что играет мак, вместе с "
                          + "музыкой и уведомлениями."),
                  .choice(["app", "all"]), default: "app"),
            Entry(["mic_voice_processing"],
                  localised("Cancel echo on the mic", "Гасить эхо на микрофоне"),
                  localised(
                      "For meetings played through speakers, so the far end isn't recorded onto your track as well. Ducks other playback while active; pointless on headphones.",
                      "Для встреч через колонки, чтобы дальняя сторона не попадала ещё и на вашу "
                          + "дорожку. Пока работает, приглушает остальной звук; в наушниках бесполезно."),
                  .toggle, default: false),
            Entry(["keep_audio"],
                  localised("Keep the audio after transcribing", "Оставлять звук после расшифровки"),
                  localised(
                      "Saves one stereo M4A: your mic on the left, the other side on the right. A recording that never got a transcript is kept either way.",
                      "Сохраняет один стереофайл M4A: ваш микрофон слева, дальняя сторона справа. "
                          + "Запись, которая так и не получила расшифровку, остаётся в любом случае."),
                  .toggle, default: false, askedInSetup: true),
            Entry(["recordings_dir"], localised("Recordings folder", "Папка записей"),
                  localised("Where sessions land.", "Куда складываются встречи."),
                  .text, default: "~/Recordings", needsRestart: true, askedInSetup: true),
        ]),

        Section(title: localised("Transcription", "Расшифровка"), entries: [
            Entry(["transcription", "enabled"],
                  localised("Transcribe recordings", "Расшифровывать записи"),
                  localised(
                      "Off means record only; the on_stop hook still fires.",
                      "Выключено — только запись; хук on_stop всё равно срабатывает."),
                  .toggle, default: true, askedInSetup: true),
        ] + localModelEntries + [
            Entry(["transcript_echo_filter"],
                  localised("Drop echoed speech", "Убирать отражённую речь"),
                  localised(
                      "Removes mic segments duplicating system audio — the far end coming back through the speakers.",
                      "Убирает куски с микрофона, повторяющие звук системы, — дальнюю сторону, "
                          + "вернувшуюся через колонки."),
                  .toggle, default: true),
            Entry(["transcription", "assemblyai", "api_key_path"],
                  localised("AssemblyAI key file", "Файл ключа AssemblyAI"),
                  localised(
                      "Where the cloud engine's key is read from. ASSEMBLYAI_API_KEY wins over it.",
                      "Откуда читается ключ облачного движка. ASSEMBLYAI_API_KEY важнее."),
                  .text, default: "~/.config/amanu/keys/assemblyai"),
            Entry(["transcription", "assemblyai", "speech_model"],
                  localised("AssemblyAI speech model", "Модель речи AssemblyAI"),
                  localised(
                      "Empty sends nothing and lets the API pick its own default.",
                      "Пусто — ничего не отправляется, и API выбирает сам."),
                  .text, default: localised("the API's own default", "выбор самого API")),
            Entry(["transcription", "openai", "model"], localised("OpenAI model", "Модель OpenAI"),
                  localised(
                      "The default is the only OpenAI model that returns both timings and speakers.",
                      "По умолчанию стоит единственная модель OpenAI, которая возвращает и время, "
                          + "и говорящих."),
                  .text, default: "gpt-4o-transcribe-diarize"),
        ]),

        Section(title: localised("Summaries", "Саммари"), entries: [
            Entry(["summary", "enabled"],
                  localised("Write a summary", "Писать саммари"),
                  localised(
                      "Topic, key points, decisions, action items, open questions.",
                      "Тема, главное, решения, задачи, открытые вопросы."),
                  .toggle, default: true, askedInSetup: true),
            Entry(["summary", "backend"],
                  localised("Which model to ask", "У какой модели спрашивать"),
                  localised(
                      "auto walks the chain: claude CLI, Anthropic API, codex CLI, OpenAI API, ollama — subscriptions before metered keys. none skips summarizing without turning off the rest.",
                      "auto идёт по цепочке: claude CLI, Anthropic API, codex CLI, OpenAI API, "
                          + "ollama — сначала подписки, потом платные ключи. none пропускает саммари, "
                          + "не выключая всего остального."),
                  .choice(["auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama", "none"]),
                  default: "auto"),
            Entry(["summary", "model"],
                  localised("Anthropic model", "Модель Anthropic"),
                  localised(
                      "Used on the API path. The CLI uses whatever model Claude Code is set to.",
                      "Для пути через API. CLI берёт ту модель, на которую настроен Claude Code."),
                  .text, default: "claude-opus-5"),
            Entry(["summary", "openai_model"],
                  localised("OpenAI model", "Модель OpenAI"),
                  localised(
                      "Used by the codex CLI and the OpenAI API.",
                      "Для codex CLI и для OpenAI API."),
                  .text, default: "gpt-5"),
            Entry(["summary", "ollama_model"],
                  localised("Local model", "Местная модель"),
                  localised("The fully-offline fallback.", "Запасной вариант, целиком без сети."),
                  .text, default: "qwen3:8b"),
            Entry(["summary", "language"],
                  localised("Summary language", "Язык саммари"),
                  localised(
                      "Leave empty to write in whichever language the meeting was held in.",
                      "Пусто — саммари пишется на языке самой встречи."),
                  .text, default: localised("the language of the meeting", "язык встречи")),
            Entry(["summary", "api_key_path"],
                  localised("Anthropic key file", "Файл ключа Anthropic"),
                  localised(
                      "Where the Anthropic key is read from. ANTHROPIC_API_KEY wins over it.",
                      "Откуда читается ключ Anthropic. ANTHROPIC_API_KEY важнее."),
                  .text, default: "~/.config/amanu/keys/anthropic"),
            Entry(["summary", "openai_api_key_path"],
                  localised("OpenAI key file", "Файл ключа OpenAI"),
                  localised(
                      "Where the OpenAI key is read from. OPENAI_API_KEY wins over it.",
                      "Откуда читается ключ OpenAI. OPENAI_API_KEY важнее."),
                  .text, default: "~/.config/amanu/keys/openai"),
        ]),

        Section(title: localised("Calendar and naming", "Календарь и имена"), entries: [
            Entry(["calendar"],
                  localised("Read the calendar", "Читать календарь"),
                  localised(
                      "Names sessions after the meeting and records attendees. Separate from starting recordings from events.",
                      "Называет встречу по событию и запоминает участников. Это не то же самое, что "
                          + "начинать запись по событию."),
                  .toggle, default: true, needsRestart: true),
            Entry(["speaker_names", "enabled"],
                  localised("Put names to speakers", "Подставлять имена говорящих"),
                  localised(
                      "Works out who \"them A\" was from the invitees and from people addressing each other, and applies it only when the transcript proves it.",
                      "Догадывается, кто такой «them A», по участникам события и по тому, как люди "
                          + "обращаются друг к другу, и подставляет имя, только когда расшифровка это "
                          + "подтверждает."),
                  .toggle, default: true),
            Entry(["user_name"],
                  localised("Your name", "Ваше имя"),
                  localised(
                      "Used instead of \"me\". Empty falls back to the account's full name, and to \"me\" if that isn't a person's name.",
                      "Ставится вместо «me». Пусто — берётся полное имя учётной записи, а если оно не "
                          + "похоже на имя человека, остаётся «me»."),
                  .text,
                  default: localised(
                      "the account's full name", "полное имя учётной записи")),
            Entry(["speaker_names", "backend"],
                  localised("Which model to ask", "У какой модели спрашивать"),
                  localised(
                      "Same chain as summaries. auto walks it until one answers.",
                      "Та же цепочка, что у саммари. auto идёт по ней, пока кто-нибудь не ответит."),
                  .choice(["auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama"]),
                  default: "auto"),
            Entry(["speaker_names", "model"],
                  localised("Anthropic model for naming", "Модель Anthropic для имён"),
                  localised(
                      "Naming is an easier job than summarizing; empty uses the summary's model.",
                      "Имена — работа проще саммари; пусто — та же модель, что у саммари."),
                  .text, default: localised("the summary's model", "модель саммари")),
        ]),

        Section(title: localised("Interface", "Интерфейс"), entries: [
            // The one setting on this list that changes the words the rest of
            // it is written in. It is named at length because two other
            // settings are called language and mean other people's words —
            // see `InterfaceLanguage`.
            Entry(["interface_language"],
                  localised("Language of amanu's own windows", "Язык окон amanu"),
                  localised(
                      "auto follows the Mac. Not the language of your meetings, and not the one "
                          + "summaries are written in — those are settings of their own.",
                      "auto — как на маке. Это не язык встреч и не язык саммари: у тех есть "
                          + "собственные настройки."),
                  .choice(InterfaceLanguage.configuredValues),
                  default: InterfaceLanguage.automatic, needsRestart: true),
            Entry(["dock_icon"],
                  localised("Show in the Dock", "Показывать в доке"),
                  localised(
                      "Off makes amanu a menu-bar-only accessory — which the menu bar hides when it runs out of room.",
                      "Выключено — amanu живёт только в строке меню, а строка меню прячет значок, "
                          + "когда ей не хватает места."),
                  .toggle, default: true, askedInSetup: true),
            Entry(["menu_bar_icon"],
                  localised("Show in the menu bar", "Показывать в строке меню"),
                  localised(
                      "Off with the Dock icon too leaves amanu with no icon anywhere: open Amanu "
                          + "again to bring its window back.",
                      "Выключено вместе со значком в доке — amanu нигде не видно: чтобы вернуть "
                          + "окно, откройте Amanu ещё раз."),
                  .toggle, default: true, askedInSetup: true),
            Entry(["window"],
                  localised("Open the window at launch", "Открывать окно при запуске"),
                  localised(
                      "The Dock icon opens it either way.",
                      "Значок в доке открывает его в любом случае."),
                  .toggle, default: true, needsRestart: true),
            Entry(["on_stop"],
                  localised("Run after each session", "Запускать после каждой встречи"),
                  localised(
                      "A shell command, given the session folder as its argument, after the transcript and summary are written.",
                      "Команда оболочки; получает папку встречи аргументом после того, как записаны "
                          + "расшифровка и саммари."),
                  .text, default: localised("nothing", "ничего")),
        ]),
        Section(title: localised("Statistics", "Статистика"), entries: [
            Entry(["analytics"],
                  localised(
                      "Send anonymous usage statistics",
                      "Отправлять анонимную статистику об использовании"),
                  localised(
                      "How often you use amanu and which features you use, so we can make it better.",
                      "Как часто вы пользуетесь программой и какими функциями — чтобы сделать её лучше."),
                  .toggle, default: true, askedInSetup: true),
        ]),
    ] }

    /// `sections` minus what setup already asks, which is what the Advanced
    /// tab draws. A section emptied by the filter is dropped with it rather
    /// than left as a heading over nothing.
    ///
    /// The filter lives here, beside the flag it reads, so that the window
    /// keeps holding no list of its own — the thing that stops the two from
    /// drifting. `sections` stays the whole list, and everything else that
    /// asks the schema a question about *settings* rather than about controls
    /// — `knownKeys`, the README test — goes on asking that one.
    static var advancedSections: [Section] {
        sections.compactMap { section in
            let entries = section.entries.filter { !$0.askedInSetup }
            return entries.isEmpty ? nil : Section(title: section.title, entries: entries)
        }
    }

    /// The default in words, for the grey of an empty field.
    ///
    /// Every setting has one and it is worth showing: a control says what it
    /// is set to and never what it would do if nobody had set it. Booleans
    /// read as the switch reads — on, off — and a number carries its unit,
    /// because "12" on its own is a question.
    static func describeDefault(_ entry: Entry) -> String {
        switch entry.kind {
        case .toggle:
            return entry.defaultValue as? Bool == true
                ? localised("on", "включено")
                : localised("off", "выключено")
        case .number(let unit):
            return "\(entry.defaultValue) \(unit)"
        default:
            return "\(entry.defaultValue)"
        }
    }

    // MARK: - what a control's contents mean

    /// What the user just did to a control, in terms the schema understands.
    /// Deliberately not AppKit types: the rule below is the fiddly part of the
    /// settings window and it should be testable without a window.
    enum Input {
        case flag(Bool)
        case choice(String)
        /// Whatever is in a text field, untrimmed.
        case text(String)
    }

    enum Resolution {
        case set(Any)
        /// Remove the key: the value is the default, or was emptied.
        case clear
        /// Unusable — letters in a number field. Change nothing and put the
        /// stored value back on screen.
        case invalid
    }

    /// Whether committing this resolution would change the file at all.
    ///
    /// A text field commits when it loses focus, and focus is lost for
    /// reasons that have nothing to do with typing: the tab changed, another
    /// window took over, the window closed. Each of those used to write the
    /// value back exactly as it already was — same bytes, new timestamp, and
    /// a redraw announced to every open window. The timestamp on that file is
    /// the only evidence anyone has that a setting was changed, so writing is
    /// for changes.
    static func changes(_ resolution: Resolution, from stored: Any?) -> Bool {
        switch resolution {
        case .invalid: return false
        case .clear: return stored != nil
        case .set(let value): return !same(value, stored)
        }
    }

    /// Two JSON values compared as the file would hold them. Anything this
    /// can't recognise counts as different, so an unknown shape is written
    /// rather than silently kept.
    private static func same(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        switch (lhs, rhs) {
        case let (a as Bool, b as Bool): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [String], b as [String]): return a == b
        case let (a as NSNumber, b as NSNumber): return a == b
        default: return false
        }
    }

    /// Turn a control's contents into what should be in the config file.
    ///
    /// The one rule worth stating: a value equal to the default is *cleared*,
    /// not written. A config that only holds what you changed keeps reading as
    /// a list of your decisions, and a default that improves in a later
    /// version reaches you instead of being frozen into your file the first
    /// time you opened this window. An emptied field means "unset" for the
    /// same reason — the alternative is storing an empty string that no
    /// caller expects.
    static func resolve(_ input: Input, for entry: Entry) -> Resolution {
        switch (input, entry.kind) {
        case (.flag(let on), .toggle):
            return entry.defaultValue as? Bool == on ? .clear : .set(on)

        case (.choice(let title), .choice(let options)):
            guard options.contains(title) else { return .invalid }
            return entry.defaultValue as? String == title ? .clear : .set(title)

        case (.text(let raw), .number):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .clear }
            guard let number = Int(text) else { return .invalid }
            return entry.defaultValue as? Int == number ? .clear : .set(number)

        case (.text(let raw), .text):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || entry.defaultValue as? String == text { return .clear }
            return .set(text)

        case (.text(let raw), .list):
            let items = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return items.isEmpty ? .clear : .set(items)

        default:
            return .invalid
        }
    }

    /// Settings the program reads but the window deliberately doesn't show.
    ///
    /// One entry, and it earns the exception: an API key pasted into the
    /// config file is a secret, and a text field would put it on screen and
    /// into a screenshot. The path to a key file is offered instead. Keys
    /// listed here still count as known — a setting amanu obeys must never be
    /// reported as one it ignores.
    static let unrenderedKeys = ["transcription.assemblyai.api_key"]

    /// Older releases exposed these choices. Retained audio now always becomes
    /// one compact stereo M4A, but accepting the keys keeps an old config from
    /// being reported as misspelled until its owner next edits the file.
    static let deprecatedKeys = ["compress_tracks", "keep_uncompressed"]

    /// The settings above that this slice does not render, because there is no
    /// local model behind them. They stay *known*: a config carrying them on
    /// an Intel Mac is not misspelled, and reporting a working setting as
    /// unread is the one direction `strayKeys` must never fail in.
    static var unrenderedLocalModelKeys: [String] {
        Platform.supportsLocalModels
            ? []
            : ["live_transcription.enabled", "transcription.model"]
    }

    /// Every key the program understands, as `a.b` strings — used to spot
    /// settings in a config file that nothing reads (a typo, or a key from an
    /// older version).
    static var knownKeys: [String] {
        sections.flatMap { $0.entries }.map { $0.path.joined(separator: ".") }
            + unrenderedLocalModelKeys
            + unrenderedKeys
            + deprecatedKeys
    }

    /// Keys present in a config file that nothing reads.
    ///
    /// Here rather than in the window because it is the schema's own question
    /// — and because getting it wrong is invisible in the direction that
    /// matters: a *false* stray tells someone their working setting is
    /// ignored, which is worse than the silence this list was built to break.
    static func strayKeys(in config: [String: Any]) -> [String] {
        let known = Set(knownKeys)
        var stray: [String] = []

        func walk(_ object: [String: Any], prefix: [String]) {
            for (key, value) in object {
                let path = prefix + [key]
                let joined = path.joined(separator: ".")
                if known.contains(joined) { continue }
                if let nested = value as? [String: Any] {
                    // A branch on the way to known leaves is not itself stray.
                    if known.contains(where: { $0.hasPrefix(joined + ".") }) {
                        walk(nested, prefix: path)
                        continue
                    }
                }
                stray.append(joined)
            }
        }
        walk(config, prefix: [])
        return stray.sorted()
    }
}
