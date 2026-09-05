Аудит завершён. Ниже — отчёт.

---

# Аудит Amanu перед публичным запуском

**Домен:** аналитика и точки инструментирования, приватность/согласие/умолчания, очередь и flush, Config и настройки, установка из DMG, первый запуск, разрешения, login item, CLI, гейтинг Sparkle, жизненный цикл приложения.
**HEAD:** `b5e8a77` (0.4.15). **Кандидатный диапазон:** `ad2dd69..HEAD` (27 коммитов, 1–4 сентября). Трейлеров авторства нет ни в одном коммите диапазона — атрибуция агента не выводится, поэтому ниже указано только «внесено в диапазоне / существовало ранее / не определено» по `git blame` и `git log -S`.
**Режим:** только чтение. Файлы, git-состояние, настройки и сервисы не менялись. Незакоммиченные правки в `CLAUDE.md`, `docs/releasing.md`, `.github/ISSUE_TEMPLATE/bug_report.yml` прочитаны и сохранены нетронутыми (это чисто редакторские правки текста, дефектов в них нет).

---

## Сводка

| # | Severity | Что | Где введено |
|---|---|---|---|
| F1 | **P0** | Запрещённый микрофон делает приложение незапускаемым после завершения setup | существовало ранее (`6e90c39`, 18.08) |
| F2 | **P1** | `amanu analytics off` не действует на работающее приложение; обратное включение тоже | диапазон (`e3d900b`) |
| F3 | **P1** | Холодный старт блокирует главный поток: 4 с + синхронные `zsh -lic` | существовало ранее |
| F4 | **P2** | Произвольный текст из config попадает на провод в `engine`/`backend` и в person-properties | диапазон (`e3d900b`) |
| F5 | **P2** | `session_interrupted.trigger` берётся из манифеста на диске без валидации | диапазон (`e3d900b`) |
| F6 | **P2** | Ежедневная проверка обновлений на `amanu.me` не раскрыта и не выключается тумблером | диапазон (смена хоста) |
| F7 | **P2** | Тест системного звука помечает setup завершённым | существовало ранее (`b1bcd6c`) |
| F8 | **P2** | `Runtime.meaningfulArguments` — мёртвый код, тест создаёт ложную уверенность | существовало ранее |
| F9–F17 | P3 | См. раздел «Мелкие подтверждённые дефекты и расхождения» | смешанно |

---

## F1 — P0. Запрет микрофона делает приложение незапускаемым

**Файлы:** `Sources/amanu/Amanu.swift:104`–`113`; `Sources/amanu/Doctor.swift:157`–`177`; `Sources/amanu/Doctor.swift:36`–`41`; `Sources/amanu/UI/SetupWindow.swift:119`–`124`.

**Триггер.** Последовательность целиком состоит из обычных пользовательских действий:

1. Первый запуск: `SetupState.isPending == true`, окно setup открывается.
2. В окне нажимается кнопка микрофона, в системном диалоге выбирается **Don't Allow**. `AVCaptureDevice.authorizationStatus(for: .audio)` становится `.denied`.
3. Окно setup закрывается любым способом — крестик, «Later», Enter. `SetupWindow.finish()` (`SetupWindow.swift:119`) безусловно вызывает `SetupState.markCompleted()`, комментарий рядом прямо это узаконивает: *«Setup is marked done on the way out however it was dismissed»*. Теперь `isPending == false`.
4. Следующий запуск.

**Код.**

```swift
// Amanu.swift:104
let checks = DoctorReport.run(recordingsRoot: root)
if !DoctorReport.allOK(checks) {
    FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
    DoctorReport.print(checks)
    if !SetupState.isPending || !DoctorReport.canContinueIntoSetup(checks) {
        throw ExitCode(1)                       // Amanu.swift:112
    }
}
```

`checkMicrophone()` при `.denied`/`.restricted` возвращает `.fail("denied")` (`Doctor.swift:168`–`173`), значит `allOK == false`. `canContinueIntoSetup` разрешает продолжить именно при провале микрофона (`Doctor.swift:38`) — но эта поблажка обнуляется первым условием: `!SetupState.isPending` уже истинно.

**Воздействие.** Приложение завершается с кодом 1 **до** создания `NSApplication`-цикла и до единого окна. При запуске двойным кликом из Finder виден только подпрыгнувший значок в Dock; `stderr` уходит в системный лог. Никакого алерта, никакого объяснения, никакого пути назад из GUI. То же происходит, если микрофон отзывается в System Settings уже после успешного setup — это ровно тот пункт, который в `docs/pitfalls.md` помечен как непроверенный вручную («a permission denied and re-granted»).

Восстановление возможно только через терминал (`amanu setup` делает `SetupState.reset()`, `SetupCommand.swift:22`) или через System Settings. Для рекордера, который позиционируется как приложение для не-терминальной аудитории, это блокер запуска.

**Комментарий в коде утверждает обратное** (`Amanu.swift:108`–`110`): *«A failed permission is exactly what the first-run window exists to repair… so a denied grant can never make the repair UI unreachable»*. Инвариант, который он описывает, нарушается ровно тем, что окно setup помечает себя завершённым при закрытии.

**Направление исправления.** Отказ микрофона не должен быть жёстким фейлом старта вообще — он чинится в UI, а `checkRecordingsRoot` (единственный настоящий фатальный провал) уже отделён. Минимально: убрать условие `!SetupState.isPending` и оставить только `!canContinueIntoSetup(checks)`. Лучше: при провале `canContinueIntoSetup` показать `NSAlert` вместо молчаливого `exit(1)`, потому что GUI-запуск не имеет доступа к `stderr`.

**Регрессионный тест.** Логика решения о запуске сейчас размазана по `runMain`. Выделить её в чистую функцию, например `StartupGate.decide(checks:setupPending:) -> .run | .runIntoSetup | .refuse`, и закрыть таблицей:

```
(mic .fail, setupPending: true)            -> .runIntoSetup
(mic .fail, setupPending: false)           -> .runIntoSetup   // сейчас .refuse — это и есть баг
(recordings .fail, setupPending: любое)    -> .refuse
(всё ok)                                   -> .run
```

---

## F2 — P1. `amanu analytics off` не выключает аналитику в работающем приложении

**Файлы:** `Sources/amanu/Analytics/AnalyticsSink.swift:96`–`126`, `128`–`143`; `Sources/amanu/Config.swift:536`, `554`; `Sources/amanu/UI/ConfigWatch.swift:22`–`24`; `Sources/amanu/Analytics/AnalyticsCommand.swift:18`–`53`.

Два независимых дефекта одного механизма.

**(a) Изменение из другого процесса не доходит.** Переключатель отслеживается через `NotificationCenter.default` (`AnalyticsSink.swift:120`), а `Config.didChange` постится только внутри процесса, который сам сделал запись (`Config.swift:554`). Наблюдателя за файлом нет: `DistributedNotificationCenter` в проекте используется исключительно для `SetupRequest`, `RecordRequest`, `SingleInstance` (проверено grep'ом по `Sources/`), файлового watcher'а (`DispatchSource.makeFileSystemObjectSource`, `NSFilePresenter`) нет вовсе.

Значит: `amanu analytics off`, набранное в терминале, переписывает `~/.config/amanu/config.json`, печатает `analytics: off` — и работающий `Amanu.app` продолжает буферизовать и отправлять события с тем же постоянным UUID до следующего перезапуска. Amanu — резидентный демон, зарегистрированный как login item; «до следующего запуска» здесь означает недели.

Это прямое расхождение с документацией:
- `docs/analytics.md:11`–`12`: *«Turn it off in the setup window, in Settings → Setup, or with `amanu analytics off`»* — три способа поданы как равноценные;
- `PRIVACY.md:28`–`30`: то же перечисление.

Ровно на это возражает комментарий над самим механизмом (`AnalyticsSink.swift:117`–`118`): *«A switch that only takes effect at the next launch is a switch people reasonably believe did nothing»*.

**(b) Включение обратно не работает никогда.** `watchTheSwitch()` вызывается в самом конце `start()` — **после** `guard enabled else { return }` (`AnalyticsSink.swift:102`, `112`):

```swift
enabled = switchIsOn()
guard enabled else { return }        // выход до регистрации наблюдателя
...
startTimer()
watchTheSwitch()
```

Если приложение стартовало с выключенной аналитикой, наблюдатель не регистрируется вообще. Включение тумблера в Settings → Setup в этой сессии не даёт ничего: `record()` отсекается по `guard enabled, started` (`AnalyticsSink.swift:149`). Ветка `if enabled { identifier = identity().id; startTimer() }` в `reread()` (`:132`–`134`) в этом сценарии недостижима.

Направление (b) безопасно для приватности (недосбор), направление (a) — нет.

**Направление исправления.** Вынести `watchTheSwitch()` из-под `guard enabled` (регистрировать всегда, наравне с `started = true`). Для (a) — либо лёгкий `DispatchSource` на `config.json` внутри `AnalyticsSink`, либо распределённое уведомление из `Config.update` рядом с локальным `didChange` (второе заодно чинит рассинхрон окон, если конфиг правят руками).

**Регрессионный тест.** Сейчас `reread()` **не покрыт ни одним тестом** — это самый чувствительный по приватности путь во всей подсистеме. Нужны как минимум три:

```swift
// 1. выключение на ходу
let sink = sink(store: store, on: switchState)   // switchState — мутируемый флаг
sink.start(surface: .app); sink.record(.recordingStarted, [:])
switchState = false
NotificationCenter.default.post(name: Config.didChange, object: nil)
#expect(sink.bufferedCount == 0)
#expect(!FileManager.default.fileExists(atPath: store.path))
sink.record(.recordingFinished, [:]); #expect(sink.bufferedCount == 0)

// 2. включение на ходу после старта с выключенным тумблером — сейчас падает
// 3. запись после включения действительно доходит до транспорта
```

---

## F3 — P1. Холодный старт блокирует главный поток на секунды

**Файлы:** `Sources/amanu/SingleInstance.swift:24`–`43`; `Sources/amanu/Amanu.swift:37`, `104`; `Sources/amanu/Doctor.swift:128`–`138`; `Sources/amanu/Setup/Tooling.swift:146`–`153`, `163`–`189`, `206`–`234`.

Две составляющие, обе на главном потоке, обе до создания первого окна.

**(a) Четыре секунды на опрос несуществующей копии.** `runMain` начинается с `SingleInstance.handOverToRunningCopy()` (`Amanu.swift:37`), значение таймаута по умолчанию — 4 с (`SingleInstance.swift:24`). Цикл выходит только по `reply.arrived` или по дедлайну:

```swift
let deadline = Date().addingTimeInterval(timeout)
while !reply.arrived, Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
}
```

Когда другой копии нет — то есть при каждом обычном запуске — платятся все 4 секунды. Причём в GUI-сценарии вторая копия почти никогда и не возникает: LaunchServices по умолчанию не поднимает второй экземпляр того же бандла, и `handOffToBundle` явно ставит `createsNewApplicationInstance = false` (`Runtime.swift:112`). Полная цена платится всегда за случай, который наступает редко. Косвенное подтверждение, что таймаут когда-то поднимали, — комментарий в том же файле (`SingleInstance.swift:51`): *«a second copy is sitting in a one-second wait»*.

**(b) Синхронный запуск интерактивных login-шеллов.** `DoctorReport.run` (`Amanu.swift:104`) включает `checkSummary()`, который зовёт:

```swift
// Doctor.swift:133
if hasSummaryBackend(
    anthropicKey: Config.anthropicKey(),
    openAIKey: Config.openAIKey(),
    claudeRuns: Tooling.probe("claude")?.runs == true,
    codexRuns: Tooling.probe("codex")?.runs == true
) {
```

Swift вычисляет все аргументы до вызова — короткого замыкания нет, обе пробы выполняются даже при наличии ключа. На машине без `claude` и без `codex` (типовой случай для публичного релиза) `Tooling.search` не находит их в трёх стандартных путях и уходит в `fromLoginShell` (`Tooling.swift:152`), который спавнит `$SHELL -lic "command -v …"` с таймаутом **8 секунд** (`Tooling.swift:177`–`179`), для каждого из двух инструментов. Если инструмент найден — дополнительно `--version` с таймаутом **20 секунд** (`Tooling.swift:194`).

Дополнительно `Tooling.run` читает stdout до конца и только потом stderr (`Tooling.swift:228`–`229`): шелл, выливший больше буфера трубы в stderr, заблокируется до срабатывания киллера, то есть до полного таймаута.

Что это на самом деле медленно, в проекте уже знают: та же проба в окне setup обёрнута в `Task.detached` (`SetupForm.swift:1191`–`1193`). На стартовом пути обёртки нет.

**Воздействие.** Обычный холодный старт: 4 с + время двух интерактивных `zsh -lic` (на машине с p10k/nvm/mise это 1–3 с каждый). В худшем случае — десятки секунд полностью замороженного главного потока до появления окна, включая первый запуск, когда пользователь ждёт окно setup. `docs/pitfalls.md` измеряет миллисекунды TCC-запросов, но об этом пути не упоминает — то есть это не осознанное ограничение.

**Направление исправления.** (a) Снизить таймаут одиночного экземпляра до ~0.5 с и/или выходить сразу, если `NSRunningApplication` не показывает другой копии `me.samat.amanu`. (b) Убрать `checkSummary()` из стартового набора либо считать его асинхронно и не блокировать запуск: его результат — это `.warn`, который никогда не влияет на решение `allOK`.

**Регрессионный тест.** Тайминг в unit-тестах хрупок, но структура — нет. Разделить `DoctorReport.run` на «дешёвые проверки, влияющие на запуск» и «дорогие информационные», и закрепить тестом, что стартовый набор не содержит ни одной проверки, которая спавнит процесс (например, через инъекцию `probe:` и счётчик вызовов, который на стартовом пути должен остаться нулём).

---

## F4 — P2. Произвольный текст из config попадает на провод

**Файлы:** `Sources/amanu/Analytics/AnalyticsCatalogue.swift:78`, `81`, `83`; `Sources/amanu/Transcription/TranscriptionCoordinator.swift:185`, `206`, `261`; `Sources/amanu/Summary/Summarizer.swift:40`, `105`; `Sources/amanu/Sessions/SpeakerNamer.swift:88`, `146`.

Проект строит вокруг закрытого словаря явный инвариант. `Analytics.reportableChange` валидирует значение выбора против схемы (`Analytics.swift:218`–`220`) с комментарием в тесте: *«keeps a hand-edited config file from putting free text on the wire through a key that happens to be a choice»* (`AnalyticsTests.swift:451`–`456`). `docs/analytics.md:126`–`128`: *«Registry namespaces and arbitrary config text never travel»*.

Три пути обходят эту защиту.

**1. Person-properties — уходят с каждым событием** (`AnalyticsCatalogue.swift:68`–`88`):

```swift
.transcriptionEngine: Config.transcriptionEngine(),   // Config.swift:61 — сырая строка, дефолт "auto"
.summaryBackend: Config.summary().backend,            // Config.swift:454 — сырая строка
.speakerNamesBackend: Config.speakerNames().backend,  // Config.swift:274 — сырая строка
```

Ни одна из трёх не валидируется. Все три объявлены в схеме как `.choice` (`SettingsSchema.swift:111`/`115`, `281`/`288`, `351`/`356`), то есть при изменении через `setting_changed` они проверяются — а здесь нет. Для сравнения, `transcriptionCloudProvider()` **валидируется** и откатывается к `assemblyai` (`Config.swift:74`–`83`), что показывает: правило известно и просто не применено к соседям.

**2. Событийные свойства при неудачах.** `Summarizer.swift:40` и `:105` отправляют `.backend: .text(settings.backend)` — то есть сырую строку из config, а не `backend.name` из закрытого набора `LLMBackend`. `SpeakerNamer.swift:88` инициализирует `var lastBackend = settings.backend` и отправляет её на `:146`, если ни один бэкенд не отработал.

**3. Имя движка транскрипции.** `TranscriptionCoordinator.swift:206` и `:261`: `engine?.name ?? Config.transcriptionEngine()` — при неудаче до создания движка на провод уходит сырая строка. То же для `.fromEngine` на `:185`.

**Воздействие.** Требует правки config руками — но именно от этого сценария защита и строилась, и защита объявлена публично. Строка вида `"engine": "/Users/…/что-то"` уедет на `stats.amanu.me` и осядет там на год. Это не эксплуатируемая уязвимость, а нарушение заявленного инварианта, на котором держится обещание «полного списка».

**Направление исправления.** Ввести `AnalyticsCatalogue.choice(_ value: String, allowedFor path: [String]) -> String`, возвращающую `"custom"` для всего, чего нет в схеме, и пропустить через неё все пять мест. Это ровно та же нормализация, что уже сделана для моделей (`transcriptionModel`, `summaryModel`).

**Регрессионный тест.** Есть готовый образец — `freeTextNeverTravels` (`AnalyticsTests.swift:415`). Нужен его зеркальный вариант для person-properties:

```swift
@Test("Install state carries no config text the schema does not offer")
func personPropertiesAreClosed() {
    // с подставленным config, где engine/summary.backend/speaker_names.backend = "/etc/passwd"
    let data = AnalyticsCatalogue.personProperties()
    for key in ["transcription_engine", "summary_backend", "speaker_names_backend"] {
        let value = data[key] as? String
        #expect(allowedChoices(for: key).contains(value ?? "") || value == "custom")
    }
}
```

Сейчас это требует внедрения config в `AnalyticsCatalogue` — сегодня функция читает глобальный `Config` напрямую, из-за чего, кстати, `theBodyIsWellFormed` (`AnalyticsTests.swift:263`–`273`) читает настоящий `~/.config/amanu/config.json` разработчика.

---

## F5 — P2. `session_interrupted.trigger` берётся с диска без валидации

**Файл:** `Sources/amanu/RecordingSession.swift:446`–`450` (см. также `:434`).

```swift
Analytics.track(.sessionInterrupted, [
    .trigger: .text(manifest["trigger"] as? String ?? Trigger.manual.rawValue),
    .durationBucket: ...
])
```

`manifest` — это распарсенный `.recording.json` из папки записи. Обычно там лежит `trigger.rawValue`, записанный `writeManifest` (`:479`), но при чтении значение никак не приводится к `Trigger`. Любая правка или порча файла (папка записей может лежать в синхронизируемом каталоге) кладёт произвольную строку в закрытое свойство `trigger`. Соседний код в том же методе делает ту же ошибку мягче — записывает строку в `meta.json` (`:434`), где закрытого словаря никто не обещал.

**Направление исправления.** `Trigger(rawValue: manifest["trigger"] as? String ?? "") ?? .manual` — одна строка, и она заодно чинит `meta["trigger"]`.

**Регрессионный тест.** В `RecordingRecoveryTests` уже есть манифест с `"trigger": "mic-activity"` (`:39`). Добавить случай с `"trigger": "/Users/someone/secret"` и проверить, что восстановленный `meta.json` содержит `manual`.

---

## F6 — P2. Ежедневный запрос обновлений на `amanu.me` не раскрыт и не подчиняется тумблеру

**Файлы:** `Packaging/Amanu-Info.plist:39`–`50`; `PRIVACY.md:26`–`46`; `docs/analytics.md:21`, `155`–`161`; `landing/deploy/nginx/amanu.conf`; `scripts/analytics/stats.caddy:10`–`17`.

```xml
<key>SUFeedURL</key>   <string>https://amanu.me/appcast.xml</string>
<key>SUEnableAutomaticChecks</key> <true/>
<key>SUScheduledCheckInterval</key> <integer>86400</integer>
```

Приложение по умолчанию раз в сутки обращается к `amanu.me`. Этот запрос:

- **не упомянут ни в `PRIVACY.md`, ни в `docs/analytics.md`.** `PRIVACY.md:36`–`46` описывает трафик на `amanu.me` исключительно как «Website analytics» — то, что делает браузер. `docs/analytics.md:21` говорит «Sent to `stats.amanu.me`». Читатель обеих страниц обоснованно заключит, что установленное приложение обращается только к `stats.amanu.me`, и только пока включён тумблер;
- **не выключается тумблером аналитики.** `amanu analytics off` на Sparkle не влияет никак;
- **логируется с IP.** `stats.amanu.me` обслуживается Caddy, который явно вырезает `remote_ip`, `client_ip` и `X-Forwarded-For` (`stats.caddy:12`–`16`) — это и есть основание для фразы «Caddy removes it from this site's access log too». `amanu.me` обслуживается nginx (`landing/deploy/nginx/amanu.conf`), где стандартный `access_log` с `$remote_addr` не отключён. То есть выключение аналитики оставляет ежедневный, IP-логируемый пинг на тот же домен.

Хост фида сменился с `samat.me` на `amanu.me` **внутри кандидатного диапазона** (`git diff ad2dd69..HEAD -- Packaging/Amanu-Info.plist`), что и делает умолчание заметным: `PRIVACY.md` теперь описывает трафик на `amanu.me`, и не описывает именно тот, который создаёт само приложение.

**Что уже сделано правильно** и стоит зафиксировать: `SUEnableSystemProfiling` в plist отсутствует, значение по умолчанию — выключено, поэтому Sparkle не приклеивает к URL профиль машины (модель, ЦП, RAM, язык). Это существенно, и это стоит написать в `PRIVACY.md` как гарантию, а не оставлять на догадку.

**Направление исправления.** Документное, кода не требует: абзац в `PRIVACY.md` — что приложение раз в сутки запрашивает `amanu.me/appcast.xml`, что запрос содержит только обычные метаданные HTTP, что профиль системы не отправляется, и что этот запрос не зависит от тумблера аналитики (с указанием, как его отключить — снять «Автоматически проверять обновления», если такой переключатель будет, либо честно сказать, что его нет). Дополнительно — распространить фильтрацию IP из `stats.caddy` на nginx-лог `amanu.me`.

**Регрессионный тест.** По образцу `AnalyticsCatalogueTests` (`AnalyticsTests.swift:476`): тест, который читает `Packaging/Amanu-Info.plist` и требует, чтобы хост из `SUFeedURL` упоминался в `PRIVACY.md`, а `SUEnableSystemProfiling` был либо отсутствующим, либо `false`.

---

## F7 — P2. Тест системного звука помечает setup завершённым

**Файлы:** `Sources/amanu/Setup/SetupState.swift:56`–`58` и `72`–`77`; `Sources/amanu/UI/SetupForm.swift:946`; тест `Tests/amanuTests/SetupTests.swift:55`–`75`.

```swift
static func rememberSystemAudioHeard(now: Date = Date(), at stateURL: URL = path) {
    write(["system_audio_heard_at": ...], at: stateURL)     // :57
}

private static func write(_ values: [String: Any], at stateURL: URL) {
    var json = ...
    json["version"] = current                               // :76 — безусловно
    for (key, value) in values { json[key] = value }
```

`write` — общий путь для «setup пройден» и «тон услышан», и он всегда проставляет `version`. Успешный тон в окне setup (`SetupForm.swift:946`) поэтому делает `SetupState.isPending == false`.

**Триггер.** Открыт setup на первом запуске → нажат «Test system audio», тон услышан → приложение закрыто через ⌘Q, а не через закрытие окна setup (`applicationWillTerminate` вызывает `finishForTermination`, но не `SetupWindow.finish()`). При следующем запуске окно setup не откроется (`Amanu.swift:545`), а `setup_completed` не будет отправлено никогда.

**Воздействие.** Умеренное — потому что `finish()` и так помечает завершение при любом закрытии окна. Но: (а) воронка «сколько людей проходят setup» — заявленная причина существования аналитики (`docs/analytics.md:29`–`33`) — систематически недосчитывает именно этих людей; (б) в сочетании с F1 это ещё один способ выставить `isPending == false`, не пройдя шаг микрофона.

Комментарий к `write` (`SetupState.swift:69`–`71`) описывает намерение — «слить, чтобы одно не стирало другое», — а не наблюдаемое поведение.

**Существующий тест маскирует дефект.** `systemAudioMemoryRoundTrip` (`SetupTests.swift:64`–`68`) вызывает `rememberSystemAudioHeard` и **сразу** `markCompleted`, после чего проверяет `isPending == false`. Порядок вызовов делает утверждение истинным независимо от бага.

**Направление исправления.** Вынести `json["version"] = current` из `write` в `markCompleted`.

**Регрессионный тест.**

```swift
@Test("Measuring the tone is not the same as finishing setup")
func toneDoesNotCompleteSetup() {
    SetupState.rememberSystemAudioHeard(now: heard, at: state)
    #expect(SetupState.isPending(at: state), "the wizard has not been through")
    #expect(SetupState.systemAudioHeardAt(at: state) == heard)
}
```

---

## F8 — P2. `Runtime.meaningfulArguments` не подключён, а тест утверждает обратное

**Файлы:** `Sources/amanu/Runtime.swift:136`–`153`; `Tests/amanuTests/NativeAppTests.swift:81`–`93`; `Sources/amanu/Amanu.swift:5`–`16`.

`meaningfulArguments` фильтрует `-psn_*` и парные `-NS…`/`-Apple…`, которые LaunchServices может подсунуть приложению. Проверено grep'ом по `Sources/`, `Tests/`, `Packaging/`: единственный вызов — в тесте. Точка входа — `@main struct Amanu: ParsableCommand` без собственного `static func main()`, то есть используется реализация ArgumentParser, разбирающая `CommandLine.arguments` напрямую.

**Воздействие.** Если такой аргумент когда-либо придёт, ArgumentParser не распознает опцию, начинающуюся с `-`, и процесс завершится с кодом 64 — приложение просто не стартует. Вероятность на современной macOS низкая (`-psn_` давно не передаётся при обычном открытии), но защита была написана именно от неё, а тест `launchServicesArguments` создаёт впечатление, что она работает. Это ровно тот класс «зелёного теста над отключённым кодом», который стоит закрыть до релиза.

**Направление исправления.** Либо подключить:

```swift
@main struct Amanu: ParsableCommand {
    static func main() {
        Self.main(Runtime.meaningfulArguments(Array(CommandLine.arguments.dropFirst())))
    }
```
либо удалить функцию вместе с тестом. Промежуточного состояния быть не должно.

**Регрессионный тест.** После подключения — `#expect(throws: Never.self) { try Amanu.parseAsRoot(Runtime.meaningfulArguments(["-psn_0_1", "-NSDocumentRevisionsDebugMode", "YES"])) }` и проверка, что результат — `Run`.

---

## Мелкие подтверждённые дефекты и расхождения (P3)

**F9. Отказ от аналитики не удаляет идентификатор, а инструкция по удалению прячется именно тогда, когда нужна.**
`AnalyticsSink.reread()` при выключении удаляет `analytics-pending.json` (`:141`), но `analytics.json` с постоянным UUID остаётся. При этом `AnalyticsCommand.swift:49`–`53` печатает `rm ~/.config/amanu/analytics*.json` только внутри `if on` — то есть человек, только что выполнивший `amanu analytics off`, инструкции не увидит. Исправление: печатать подсказку об удалении всегда.

**F10. Выключение воссоздаёт пустой файл очереди, если запрос был в полёте.**
`reread()` удаляет файл (`:141`), затем завершение уже стартовавшего `send()` вызывает `savePending()` (`:244`) и записывает `{"pending":[]}` обратно. Противоречит `docs/analytics.md:160`–`161` («Turning analytics off deletes that file»). Исправление: проверять `enabled` в блоке завершения перед `savePending()`.

**F11. `removeFirst(count)` предполагает неизменную голову очереди.**
`AnalyticsSink.swift:243`. Голову меняют два пути: `trim()` при переполнении 500 (`:178`–`182`) и цикл выключение→включение, обнуляющий `pending` (`:140`). В обоих случаях успешный ответ удалит неотправленные события. Узко, но детерминированно. Исправление: помечать батч монотонным номером и удалять по нему, а не по количеству.

**F12. `session_interrupted` из CLI теряется.**
`ProcessSession.run` вызывает `Self.prepare(dir)` (`SessionCommands.swift:73`), который делает `recoverInterrupted` (`:135`), и только затем `Analytics.start(surface: .cli)` (`:74`). `record()` до `start()` отбрасывается по `guard enabled, started` (`AnalyticsSink.swift:149`). Команда `Sessions` вызывает `recoverInterrupted` (`:20`) и не стартует аналитику вовсе. Исправление: поднять `Analytics.start` на строку выше и добавить его в `Sessions`.

**F13. Отброшенные автозаписи считаются как завершённые.**
`RecordingSession.stop()` отправляет `recording_finished` (`:232`), после чего `AppController.stopSession` может вызвать `discard()`, который отправляет `recording_discarded` (`:307`). Оба события уходят для одной и той же папки, которая затем удаляется. Воронка `recording_started → recording_finished → transcript_finished` (`scripts/analytics/reports.sql:21`) поэтому завышает число реальных встреч. Исправление: либо отправлять `recording_finished` в `AppController` после решения об отбрасывании, либо вычитать `recording_discarded` в отчётах и написать это в `docs/analytics.md`.

**F14. Воронка автозаписи фильтрует несуществующее значение.**
`scripts/analytics/reports.sql:27` содержит `{"property":"trigger","operator":"neq","value":"cli"}`. `cli` — значение свойства `surface`, а не `trigger`; у `trigger` только `manual`, `mic-activity`, `calendar` (`RecordingSession.swift:43`–`47`). Фильтр мёртв, и `Tests/scripts/test_analytics_reporting.py:38` закрепляет ошибку утверждением. Исправление: убрать фильтр (все `recording_started` и так приходят с `surface: app` — `Record` сам ничего не записывает, `RecordCommand.swift:20`–`27`), поправить тест.

**F15. Документация расходится с поведением очереди.**
`docs/analytics.md:157`–`159`: *«Events buffer in memory… What fails to send is held in `~/.config/amanu/analytics-pending.json`»*. На деле `append()` вызывает `savePending()` при **каждом** событии (`AnalyticsSink.swift:175`), то есть в файле оказывается всё, а не только неотправленное. Человек, проверяющий собственную машину, найдёт там больше, чем обещано. Исправление — одна фраза в документе.

Там же: комментарий `Analytics.swift:63` и `docs/specs/2026-08-22-analytics-design.md:96` называют значение `mic_activity`, реальное — `mic-activity` (`RecordingSession.swift:45`); фикстура `Tests/scripts/test_analytics_reporting.py:76`, `89` повторяет ошибку.

**F16. Непереваримый батч заклинивает очередь.**
`send()` при `encode(batch) == nil` вызывает `finishFlushes()` и выходит, **не очищая** `pending` (`AnalyticsSink.swift:229`–`232`). Любой следующий `send()` упрётся в то же самое, пока события не протухнут через 7 дней. Сегодня недостижимо (все значения JSON-безопасны), но стоит одной строки: при неудаче кодирования — сбрасывать батч.

Рядом — стоимость: `personProperties()` делает около десяти отдельных чтений и парсингов `config.json` (`Config.load()` не кэширует, `Config.swift:497`) на **каждое** событие, и каждое событие переписывает весь файл очереди целиком.

**F17. Окно setup объясняет недоступность login item неверно на DMG.**
Кандидатный диапазон расширил четыре гейта с `Runtime.isBundled` на `Runtime.supportsPersistentFeatures` (`LoginItem.swift:23`, `30`, `42`, `49`; `AgentCLI.swift:23`; `AppUpdates.swift:28`; `Install.swift:29`), но текст в форме не обновили: `SetupForm.swift:1292`–`1297` по-прежнему говорит *«Only Amanu.app can register itself; this is a bare build»*. На копии, запущенной с DMG (после отказа от переноса), это неверное объяснение — правильное есть в `Install.swift:31`–`32`. Одновременно `needsStartAtLogin(.unavailable) == false` (`Permissions.swift:86`), так что окно не сообщает, что автозапуск, автообновления и символическая ссылка CLI молча отключены. Исправление: отдельная формулировка для `.unavailable` на читаемом томе.

*Проверено и оказалось не дефектом:* опасение, что `volumeIsReadOnly` может ответить `true` для `/Applications` из-за запечатанного системного тома, не подтвердилось — `statfs("/Applications")` на этой машине возвращает `/System/Volumes/Data`, `MNT_RDONLY = false`. Гейт ведёт себя корректно.

---

## Наблюдения, не являющиеся дефектами

Отмечаю, чтобы не спутать с находками и чтобы намеренные решения не переоткрывались.

- **Установка из DMG не измеряется.** `Analytics.start` стоит после `ApplicationRelocation.offerMoveIfNeeded` (`Amanu.swift:48`, `100`) — намеренно и правильно, чтобы копия на образе не заводила идентификатор. Побочный эффект: доля людей, запускающих с образа, доля согласившихся на перенос и доля неудачных переносов невидимы. Для запуска, где «что делает первый запуск» — заявленная причина существования аналитики, это заметная слепая зона; но это продуктовый пробел, а не дефект.
- **`installed` отправляется до того, как человек увидел тумблер.** `flushSoon()` ставит отправку через 1 с (`AnalyticsSink.swift:196`), окно setup появляется позже. Это прямое следствие задокументированного решения «включено по умолчанию» (`docs/analytics.md:10`) и аргументировано в спецификации — не баг.
- **`~/.local/bin/amanu` переписывается при каждом запуске**, а посторонний бинарник отодвигается в `amanu.legacy-…` без вопроса (`AgentCLI.swift:30`–`52`). Это зафиксированное решение в `CLAUDE.md` («Two standing decisions») и покрыто тестом `cliRelink`.
- **`Analytics.flushOnExit()` блокирует поток на 1.5 с** (`Analytics.swift:230`). Ограничение осознанное и описано. Но комментарий в `AnalyticsTests.swift:9`–`12` признаёт, что при загруженном кооперативном пуле задача транспорта может не успеть стартовать — в проде это означает, что при активной транскрипции выход будет стабильно съедать все 1.5 с. Не дефект, но цена известна.
- **`UpdateGate`** проверен целиком: правило «встреча важнее обновления» реализовано корректно, отложенная установка запускается ровно один раз (`UpdateGate.swift:57`–`61`), покрытие тестами полное и осмысленное. `recordingDidFinish()` вызывается из `stopSession` (`Amanu.swift:773`). Замечаний нет.
- **Порядок событий при завершении** корректен: `applicationWillTerminate` → `onTerminate` → `stopSession` → `Analytics.track(.recordingFinished)` → `queue.async{append}`, затем `Analytics.flushOnExit()` → `queue.async{send}`. Последовательная очередь гарантирует, что событие попадёт в батч. Проверено.
- **Серверная часть** соответствует заявленному: `retention.sql` удаляет события, свойства, связи идентификаторов и осиротевшие сессии старше года; `stats.caddy` вырезает адрес из лога. Обещания `docs/analytics.md:163`–`164` и `:16`–`18` подтверждаются кодом в репозитории.
- Комментарий у `AppController.updates` (`Amanu.swift:421`–`425`) обещает ленивость, но `menuBar.updatesAvailable(updates.isAvailable)` в `init` (`:487`) немедленно её материализует. Это расхождение комментария с кодом, а не дефект поведения — Sparkle и должен стартовать при запуске.

---

## Покрытие и ограничения

**Прочитано целиком:** все четыре файла `Sources/amanu/Analytics/`, `AnalyticsTests.swift` (560 строк), `Config.swift`, `Runtime.swift`, `ApplicationRelocation.swift`, `Install.swift`, `SingleInstance.swift`, `Notifications.swift`, `Platform.swift`, `InterfaceLanguage.swift`, `ConfigWatch.swift`, `Doctor.swift`, весь `Sources/amanu/Setup/` (`SetupState`, `SetupCommand`, `Permissions`, `LoginItem`, `AgentCLI`, `Tooling`, `ThisTurn`), `Sources/amanu/Updates/` целиком, `Amanu.swift` целиком, `NativeAppTests.swift`, `UpdateGateTests.swift`, `SetupTests.swift` (первые 230 строк), `Packaging/Amanu-Info.plist`, `PRIVACY.md`, `docs/analytics.md`, `docs/pitfalls.md`, `CLAUDE.md`, все frontmatter'ы `.issues/` (все со статусом `done`), `scripts/analytics/{retention.sql,reports.sql,docker-compose.yml,stats.caddy}`, `Tests/scripts/test_analytics_reporting.py`, `landing/script.js`, `landing/deploy/nginx/amanu.conf`.

**Прочитано выборочно, по точкам вызова:** `SetupForm.swift` (аналитика, тумблер, тон, модели, `refresh`), `SettingsWindow.swift`, `RecordingsWindow.swift`, `SettingsSchema.swift` (схема выборов, `resolve`, `strayKeys`), `RecordingSession.swift` (старт/стоп/discard/восстановление), `TranscriptionCoordinator.swift`, `Summarizer.swift`, `SpeakerNamer.swift`, `SessionCommands.swift`, `RecordCommand.swift`, `LLMBackend.swift`, `Makefile`.

**Не входило в мой домен и не проверялось:** внутренности записи и транскрипции, аудиотракт, live-транскрипт, `AutoRecordController`, `PostProcessor`, `SessionClaim`, лендинг за пределами аналитического снипета, релизная и CI-инфраструктура. Их закрывают другие ревьюеры.

**Ограничения.**
- Тесты не запускались (по условию задачи). Все утверждения о поведении выведены из чтения кода; там, где нужен рантайм, это помечено ниже.
- **Требует воспроизведения в рантайме:** точная величина задержки старта из F3 (зависит от dotfiles конкретной машины); поведение `AnalyticsSink` под реальным `URLSession` при недоступной сети; фактическая последовательность окон при F1 (я прочитал путь до `throw`, но не наблюдал запуск).
- **Не поддаётся проверке из репозитория:** какие поля Umami 3.3 действительно сохраняет на стороне сервера (`session.country/region/city`, `browser`, `os`, `device`, `screen`) и что именно делает `PRIVATE_MODE: "1"` в `scripts/analytics/docker-compose.yml:15`. `docs/analytics.md:16`–`18` обещает «coarse location» и отсутствие хранения адреса — но полного перечня того, что Umami кладёт в таблицу `session`, на странице нет, а страница заявлена как исчерпывающая. Это стоит проверить на живом инстансе одним `SELECT` до запуска: если там окажется город, обещание «полного списка» надо расширить.
- Атрибуция авторства не устанавливалась: в кандидатном диапазоне нет ни одного трейлера, и я маркировал находки только по датам `git blame`.

---

## Рекомендация: go / no-go

**No-go до исправления F1.** Всё остальное — приемлемый риск для запуска.

Обоснование. F1 — не крайний случай: «Don't Allow» в системном диалоге и закрытие окна setup крестиком суть два самых обычных действия, и их сочетание оставляет человека с приложением, которое молча не запускается, без единого сообщения где-либо в интерфейсе. Для приложения, которое просит микрофон в первую минуту жизни, доля таких людей не будет нулевой, а первая же жалоба будет звучать как «не работает вообще» — самый дорогой вид отзыва в день запуска. Исправление при этом маленькое и локальное: убрать `!SetupState.isPending` из условия на `Amanu.swift:111` и показать алерт вместо `exit(1)` в оставшейся фатальной ветке.

**Сразу после, но до широкой раздачи** я бы закрыл ещё три:

- **F2** — потому что `amanu analytics off` описан в `PRIVACY.md` как работающий способ отказа, а он не работает на резидентном демоне. Это единственная находка, где расхождение между обещанием и поведением лежит в приватности, а не в удобстве. Правка (b) — перенос одной строки; правка (a) — распределённое уведомление в `Config.update`.
- **F3** — потому что четыре секунды чёрного экрана плюс два интерактивных шелла на старте формируют первое впечатление, и это то, что заметят все, а не немногие.
- **F6** — потому что это документ, а не код: один абзац в `PRIVACY.md`, и заявление о приватности снова становится полным. Дешевле всего исправить и дороже всего оставить.

F4, F5, F7, F8 и группа P3 — обычная работа следующей итерации; ни одна из них не теряет данные пользователя и не ломает запись.

Отдельно стоит отметить, что подсистема аналитики в остальном сделана аккуратно: закрытые перечисления вместо строк, тесты соответствия `docs/analytics.md` в обе стороны (`AnalyticsCatalogueTests`), нормализация имён моделей, схема-производный список отчётных настроек. Найденные дыры — это места, где уже существующее правило просто не применили к трём соседним значениям, а не отсутствие правила.