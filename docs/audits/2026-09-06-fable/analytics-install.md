I've completed my independent examination of the codebase. Note: during the session, new uncommitted test files appeared in the tree (`AnalyticsConsentTests.swift`, `AuditCaptureSafetyTests.swift`, etc.) — created by parallel audit work; I deliberately did not read them to preserve independence, and I changed nothing in the working tree. Here is the final report.

---

# Аудит Amanu 0.4.15 (HEAD `b5e8a77`) — аналитика, приватность, конфигурация, установка и жизненный цикл приложения

**Ревьюер:** Claude Code (Fable), независимый проход. **Метод:** только чтение кода, тестов, документации и git-истории; ничего не запускалось и не изменялось. `docs/audits/` и появившиеся в ходе сессии чужие несохранённые тест-файлы (`Tests/amanuTests/AnalyticsConsentTests.swift`, `AuditCaptureSafetyTests.swift`, `Tests/scripts/test_release_preflight.py`, правка `RetranscriptionTests.swift`) **не читались** — они созданы параллельной работой; рабочее дерево сохранено как есть.

**Атрибуция.** Ядро аналитики возникло на ветке `claude/privacy-first-app-analytics-44c533` (коммит `7c6cb92`, трейлер Claude Opus 5, не предок HEAD) и попало в master внутри кандидатного диапазона коммитом `e3d900b`, затем расширено `29e852d` и `34df362` (без трейлеров). Поэтому для находок в этом коде я пишу «внесено в диапазоне (импорт с ранней Claude-ветки)» — без утверждений о том, какой именно агент написал строку.

---

## Находки (по убыванию приоритета)

### P1-1. Отказ микрофона (или недоступная папка записей) после завершённого setup = приложение молча не запускается

**Статус:** подтверждено чтением кода; «невидимость» для Dock-запуска — практическое следствие (вывод только в stderr), желательна 5-минутная ручная проверка. **Происхождение:** до диапазона (`1f297ed` — гейт, `6e90c39` — условие с setup; эпоха Claude/ручная).

**Триггер.** Пользователь один раз нажал «Don't Allow» на системном запросе микрофона (или `recordings_dir` указывает на недоступный том), а setup уже помечен завершённым — что происходит при *любом* закрытии окна setup, включая «Later» (`Sources/amanu/UI/SetupWindow.swift:115-124`).

**Механика.** `Sources/amanu/Amanu.swift:104-113`: `checkMicrophone` возвращает `.fail("denied")` (`Sources/amanu/Doctor.swift:168-173`) → `allOK == false` → при `!SetupState.isPending` выполняется `throw ExitCode(1)`. Ни одного `NSAlert` на этом пути нет — только stderr, который при запуске из Dock/логин-айтема никто не видит. Итог: иконка подпрыгивает и исчезает; логин-айтем «тихо» умирает при каждом входе в систему. Комментарий в коде («`amanu setup` сбрасывает маркер, поэтому UI починки недостижимым не станет») верен только для тех, кто знает CLI.

**Регрессионный тест.** Вынести решение в чистую функцию вида `StartupGate.decide(checks:isPending:) -> {run, runIntoSetup, refuse(reason)}` и покрыть кейс «mic .fail + setup завершён» ожиданием `runIntoSetup`/`refuseWithDialog`, а не «exit».

**Направление фикса.** Для GUI-запуска (`Runtime.startedThroughLaunchServices()`) вместо `ExitCode(1)` показывать алерт с кнопкой «Открыть настройки системы» / открывать окно setup (микрофонный fail и так не блокирует вход в setup — `Doctor.swift:36-41`); жёсткий exit оставить только терминальным запускам.

---

### P2-1. Тумблер аналитики: включение «на лету» не работает, если приложение стартовало с выключенной аналитикой

**Статус:** подтверждён код-дефект. **Происхождение:** внесено в диапазоне `e3d900b` (идентично в исходном `7c6cb92` — импортировано как есть).

**Механика.** `Sources/amanu/Analytics/AnalyticsSink.swift:96-115`: в `start()` при выключенном переключателе выполняется ранний `guard enabled else { return }` (строка 102) — **до** `watchTheSwitch()` (строка 112). Наблюдатель `Config.didChange` не регистрируется, поэтому обратное включение в Settings/Setup (`Sources/amanu/UI/SetupForm.swift:866-868` → `Config.update` → `Config.swift:554`) никем не услышано: `reread()` (`AnalyticsSink.swift:128-143`), умеющий обе стороны переключения, недостижим. Все `record()` дропаются по `guard enabled` (`AnalyticsSink.swift:147-152`) до перезапуска.

**Противоречие собственным обещаниям.** Схема объявляет переключатель без `needsRestart` (`Sources/amanu/Settings/SettingsSchema.swift:409-418`), т.е. окно не показывает «подействует при следующем запуске»; комментарий в самом коде гласит «переключатель, действующий со следующего запуска, — это переключатель, который, по мнению людей, ничего не сделал» (`AnalyticsSink.swift:117-118`). Обратное направление (on→off в живом приложении) работает.

**Регрессионный тест.** В `AnalyticsTests`: создать sink с `switchIsOn`, возвращающим управляемое значение `false`; `start()`; перевести в `true`; послать `Config.didChange`; `record(...)`; ожидание `bufferedCount == 1`. Сейчас путь `reread()`/`watchTheSwitch()` не покрыт ни одним тестом.

**Фикс.** Вызывать `watchTheSwitch()` до раннего `return` (и в `reread()` при включении учесть `isFirstRun`/`loadPending`, если это желаемо).

---

### P2-2. `amanu analytics off` не действует на работающее приложение и не удаляет очередь — вопреки прямому обещанию документации

**Статус:** подтверждён код-дефект (несоответствие документации). **Происхождение:** внесено в диапазоне (импортированный дизайн).

**Механика.** Все три поверхности опубликованы как равноправные способы отключения (docs/analytics.md:10-11, PRIVACY.md:28-29). Но связка построена на **процесс-локальном** `NotificationCenter.default` (`Config.swift:536,554`; `Sources/amanu/UI/ConfigWatch.swift:21-35` — комментарий «whoever changed it» обещает межпроцессность, которой нет). Следствия:

1. Приложение запущено, пользователь выполняет `amanu analytics off` в терминале (`Sources/amanu/Analytics/AnalyticsCommand.swift:25-31`): CLI печатает «analytics: off», а работающее приложение продолжает буферизовать **и отправлять** события (таймер 30 с) до собственного перезапуска — `enabled` в sink кэширован и перечитывается только по нотификации.
2. Ни CLI-путь, ни следующий запуск не удаляют `~/.config/amanu/analytics-pending.json`: удаление есть только в `reread()` работающего включённого sink (`AnalyticsSink.swift:139-142`); при старте с выключенной аналитикой файл даже не читается и лежит бессрочно. Это прямо противоречит docs/analytics.md:160-161: «Turning analytics off deletes that file along with everything in it».

Работает как обещано только путь «тумблер в Settings/Setup работающего приложения, стартовавшего с включённой аналитикой».

**Регрессионные тесты.** (а) unit: sink с `switchIsOn`, читающим реальную функцию, — убедиться, что `send()` перечитывает состояние переключателя перед отправкой; (б) на файл: `start()` при `switchIsOn=false` и существующем store-файле → ожидание, что файл удалён.

**Фикс (минимальный).** Перечитывать `switchIsOn()` в начале `send()` (а не только кэш `enabled`), и в `start()` при выключенном переключателе удалять store-файл. Это закрывает оба пункта без межпроцессного IPC; полноценный вариант — file-watcher на config.json в `ConfigWatch`.

---

### P2-3. «Завершить amanu» из меню-бара обходит диалог «идёт запись» (QuitGate)

**Статус:** подтверждён код-дефект. **Происхождение:** до диапазона (связка `onQuit → shutdown()` существовала уже в момент введения QuitGate `b4b931e`, Claude Opus 5; сам разрыв — эпоха Claude).

**Механика.** `Sources/amanu/Amanu.swift:485`: `menuBar.onQuit = { self?.shutdown() }`; `shutdown()` (`Amanu.swift:618-621`) сначала останавливает сессию (`finishForTermination`), затем `NSApp.terminate` — к моменту `applicationShouldTerminate` (`Amanu.swift:336-358`) сессии уже нет, `quitGate.decide()` возвращает `.quitNow`, алерт (создан ради `.issues/005`: «выход во время звонка стоил трёх минут») не показывается. Пункт из главного меню (⌘Q, `Amanu.swift:244-245`) через гейт проходит. Меню-бар — как раз та поверхность, где во время встречи виден таймер записи, т.е. самый вероятный случайный клик. Записанное сохраняется, теряется только «всё сказанное после» — ровно то, от чего защищает алерт.

**Регрессионный тест.** Проверка проводки: `menuBar.onQuit` должен вести к `NSApp.terminate(nil)` (или тест уровня AppController, что при живой сессии quit из меню-бара вызывает `quitGate.decide()`).

**Фикс.** `menuBar.onQuit = { NSApp.terminate(nil) }` — остальное уже делает делегат (SIGINT/SIGTERM намеренно остаются на `shutdown()`).

---

### P2-4. Холодный старт: 4-секундная пауза single-instance на каждом запуске; цепочки до ~8-12 с

**Статус:** подтверждено кодом; воспринимаемая длительность — гипотеза, требует замера. **Происхождение:** до диапазона (`7c16733`, «Become an application», Claude Opus 5).

**Механика.** `Sources/amanu/SingleInstance.swift:24,35-41`: при отсутствии второго экземпляра `handOverToRunningCopy(timeout: 4)` крутит run loop полные 4 секунды на **каждом** свежем запуске (первый вызов — `Amanu.swift:37`, до любого окна). Комментарий в `observe` (строки 51-52) всё ещё говорит про «one-second wait» — таймаут когда-то был короче замысла. Композиция хуже: первый запуск с DMG = 4 с → диалог переноса → новый экземпляр = ещё 4 с → setup; `amanu setup` из терминала на чистой машине = 4 с (`SetupRequest.askRunningApp`, `Sources/amanu/Setup/SetupCommand.swift:56`) + 4 с (`handOverToRunningCopy` в новом `Run`) + 4 c в поднятом бандле. Плюс до-оконный `DoctorReport.run` синхронно зовёт `Tooling.probe("claude"/"codex")` (`Doctor.swift:133-138`) — login-shell `-lic` с таймаутом 8 с и `--version` с таймаутом 20 с (`Sources/amanu/Setup/Tooling.swift:178,194`): обычно сотни миллисекунд, но тяжёлые dotfiles легально добавляют секунды. Для публичного лонча «polished installation» первое впечатление — это десяток секунд «ничего не происходит».

**Регрессионный тест.** На `handOverToRunningCopy`: инъецируемый таймаут + быстрый предикат «есть ли кандидат» (см. фикс), тест «нет живых копий → возврат немедленно».

**Фикс.** Перед пингом проверять `NSRunningApplication.runningApplications(withBundleIdentifier: "me.samat.amanu")` (минус собственный pid) и пинговать только при непустом списке; либо снизить таймаут до ~1 с. Probes доктора можно увести с критического пути запуска (async до показа результатов).

---

### P3-1. Сырые строки конфига могут попасть на провод в `backend`/`engine`/`from_engine`

**Статус:** подтверждено кодом (окно узкое: нужен вручную отредактированный config.json). **Происхождение:** внесено в диапазоне (паттерн из `7c6cb92`, расширен `29e852d`).

**Механика.** Инвариант проекта — «свободный текст не путешествует» — выдержан для `setting_changed` и `model`, но не для этих полей: `Summarizer.swift:40,105` (`.backend: .text(settings.backend)`), `SpeakerNamer.swift:88,146` (`lastBackend = settings.backend`), `TranscriptionCoordinator.swift:185,206,261` (`engine?.name ?? Config.transcriptionEngine()`). Значения приходят из JSON без валидации; docs/analytics.md:106 при этом обещает закрытое множество («assemblyai, openai, parakeet, or auto»). Реалистичный сценарий утечки: пользователь по ошибке вписал в `summary.backend`/`transcription.engine` путь или произвольную строку — она уедет в `summary_failed`/`transcript_failed` на stats.amanu.me.

**Регрессионный тест.** По образцу `freeTextNeverTravels`: функция-нормализатор `Analytics.engineName(_:)`/`backendName(_:)` с закрытым словарём + `unknown`, тест на произвольную строку → `unknown`.

**Фикс.** Прогонять эти значения через allow-list так же, как `AnalyticsCatalogue.summaryModel`/`transcriptionModel` уже делают для `model`.

---

### P3-2. Тест системного звука сам по себе помечает setup завершённым

**Статус:** подтверждено кодом. **Происхождение:** до диапазона (`b1bcd6c`).

**Механика.** `SetupState.write` безусловно ставит `json["version"] = current` (`Sources/amanu/Setup/SetupState.swift:76`), и `rememberSystemAudioHeard` (:56-58, вызывается из `SetupForm.swift:946` при услышанном тоне) проходит через него. Если пользователь в первом запуске нажал тест звука и приложение умерло/было убито до закрытия окна — `isPending == false`, мастер больше не откроется (и `setup_completed` не отправится — дырка в воронке). Латентно хуже: когда `current` поднимут до 2, любой тест звука из вкладки Settings молча «завершит» новую версию setup, которую человек не видел. Тест `SetupTests.systemAudioMemoryRoundTrip` (:55-75) проверяет только совместное выживание полей и пропускает этот случай.

**Регрессионный тест.** `rememberSystemAudioHeard(at:)` на чистом файле → `isPending(at:)` остаётся `true`.

**Фикс.** Ставить `version` только в `markCompleted`; в `write` сохранять существующий `version`, не навязывая `current`.

---

### P3-3. Один `analytics-pending.json` на несколько процессов — дубли и потери телеметрии

**Статус:** подтверждено кодом (окно: приложение + `amanu process`/`amanu analytics` одновременно или вперемешку). **Происхождение:** внесено в диапазоне.

**Механика.** Оба процесса используют `AnalyticsSink.defaultStore` (`AnalyticsSink.swift:29-31`) с независимыми in-memory копиями: `loadPending` при старте (:296-303), `savePending` перезаписывает файл целиком (:305-312). CLI (`SessionCommands.swift:74`) может отправить события, которые приложение всё ещё держит в памяти и отправит повторно; либо перезапись затирает чужие несохранённые события. `markVersionSeen` (`AnalyticsIdentity.swift:64-84`) — тоже read-modify-write без блокировки: возможен двойной `version_seen`. Затронута только точность метрик владельца, не данные пользователя.

**Фикс (если браться).** Файловая блокировка (`flock`) вокруг load/save либо отдельный store на процесс (`analytics-pending-cli.json`). Тест: два sink на одном store, поочерёдные send/append, инварианты «нет дублей после успешной отправки».

---

### P3-4. `session_interrupted` теряется во всех CLI-путях восстановления

**Статус:** подтверждено кодом. **Происхождение:** внесено в диапазоне.

`Sessions.run` вызывает `recoverInterrupted` (`SessionCommands.swift:19-21`), но никогда не вызывает `Analytics.start` — событие `session_interrupted` (`RecordingSession.swift:446-450`) дропается по `guard enabled, started` (`AnalyticsSink.swift:149`). В `ProcessSession` `prepare` (с восстановлением) идёт **до** `Analytics.start` (`SessionCommands.swift:73-74`); FIFO серийной очереди гарантирует, что record-блок исполнится раньше start-блока — событие тоже потеряно. Метрика «сколько сессий переживает крэш» занижена. Фикс: переставить `Analytics.start` перед `prepare`; в `Sessions` — добавить start/flush по образцу `ProcessSession`.

---

### P3-5. Формулировки приватности: «анонимная статистика» при постоянном идентификаторе; неупомянутые сетевые вызовы

**Статус:** подтверждено (несоответствие формулировок). **Происхождение:** внесено в диапазоне (документы `29e852d`).

- PRIVACY.md:28 и подпись тумблера («Send anonymous usage statistics», `SettingsSchema.swift:412`, `SetupForm.swift:638`) называют репортинг «анонимным», тогда как docs/analytics.md:45-49 честно описывает постоянный UUID как «историю использования одной машины». Это псевдонимные данные; для privacy-first позиционирования слово «anonymous» — уязвимая точка критики в день лонча. Предложение: «обезличенная» → «не содержит содержимого встреч; случайный идентификатор установки» (как уже сделано в docs/analytics.md).
- PRIVACY.md не упоминает два других сетевых контакта приложения: ежедневную проверку обновлений Sparkle на `amanu.me/appcast.xml` (`Packaging/Amanu-Info.plist:39-50`, автопроверка включена без вопроса — осознанно, комментарий там же) и скачивание моделей с HuggingFace. Оба безобидны, но «what leaves the Mac» заявлен как полный список.

---

### P3-6. Мелкие подтверждённые несоответствия (без отдельных карточек)

1. **Пересоздание пустого store после опт-аута.** Если в момент выключения шёл send, его завершение вызывает `savePending()` (`AnalyticsSink.swift:239-244`) и воссоздаёт только что удалённый `analytics-pending.json` (пустым). Косметика против обещания «rm analytics*.json». Фикс: в completion-блоке проверять `enabled`.
2. **Спека расходится с кодом.** `docs/specs/2026-08-22-analytics-design.md:96` называет триггеры `mic_activity` и несуществующий `cli`; реальные — `manual`/`mic-activity`/`calendar` (`RecordingSession.swift:43-47`; docs/analytics.md:98 корректен). Комментарий `Analytics.swift:63` тоже устарел (`mic_activity`).
3. **Мёртвая проверка плейсхолдера.** `Endpoint.isConfigured` (`AnalyticsSink.swift:19-23`) всегда true — реальный websiteID захардкожен, поэтому dev-сборка (`swift run`) на машине владельца шлёт события в прод (UA «Amanu/development», версия отсутствует → `version_seen` не шлётся). Затрагивает только чистоту данных владельца.
4. **README:208** показывает в примере `"analytics": true` — против собственного принципа «в файле только то, что изменили» (дефолт и так true). Тривиально.

**Несохранённые правки документации** (`bug_report.yml`, `CLAUDE.md`, `docs/releasing.md`) просмотрены: это безопасные замены плейсхолдеров/формулировок; сохранены нетронутыми.

---

## Отсутствующие поведенческие тесты (домен аналитики/жизненного цикла)

1. `AnalyticsSink.reread()`/`watchTheSwitch()` — ни одного теста на живое переключение в обе стороны (ровно там дефекты P2-1/P2-2).
2. Проводка Quit меню-бара через QuitGate (P2-3) — QuitGateTests проверяют политику, но не подключение.
3. «Тест звука не завершает setup» (P3-2).
4. Мультипроцессный доступ к pending-store (P3-3).
5. Relocation: `install()` покрыт хорошо (NativeAppTests), но связка «запуск новой копии → single-instance handshake со старой» проверяема только вручную; стоит внести в ручной чек-лист.

## Покрытие и ограничения

Прочитаны целиком: весь `Sources/amanu/Analytics/`, `Config.swift`, `SettingsSchema.swift`, `Amanu.swift`, `Runtime.swift`, `SingleInstance.swift`, `ApplicationRelocation.swift`, `Install.swift`, `Doctor.swift`, `Setup/*` (SetupState, Permissions, LoginItem, AgentCLI, SetupCommand, Tooling, ThisTurn, SetupSelection), `Updates/*`, `Notifications.swift`, `ConfigWatch.swift`, `InterfaceLanguage.swift`, `SettingsWindow.swift`, `SetupWindow.swift`, релевантные части `SetupForm.swift`, `RecordingsWindow.swift`, `MenuBarController.swift`, инструментированные участки `RecordingSession/Summarizer/SpeakerNamer/TranscriptionCoordinator/PostProcessor/NetworkMonitor`, тесты `AnalyticsTests`, `NativeAppTests`, `SetupTests`, `QuitGateTests`, `UpdateGateTests`, документы `PRIVACY.md`, `docs/analytics.md`, спека аналитики, `docs/pitfalls.md`, `.issues/` (все закрыты; противоречий с находками нет), `THIRD-PARTY-NOTICES.md` (соответствует зависимостям Package.swift; сами копии лицензий в бандле — зона инфраструктурного ревьюера). Ключи: запись с 0700/0600 подтверждена (`SetupForm.swift:1157-1165`); чужие key-файлы только читаются — соответствует pitfalls.

**Не проверялось:** серверная часть (Umami, retention.sql, Caddy), Makefile/подпись/релизные скрипты, аудио/транскрипционные внутренности (другие ревьюеры); всё поведение во времени (задержки, потоки коллбэков Sparkle/NSWorkspace) — статические выводы, помечены как гипотезы, где уместно.

## Рекомендация (только мой домен): **go с обязательными точечными фиксами до публичного лонча**

Очередь аналитики сама по себе добротная: персистентность, потолок, срок жизни, in-flight-ожидание (`34df362`) корректны и покрыты тестами; consent-поверхность в setup есть; свободный текст в основном отрезан by construction. Но для продукта, лончащегося на тезисе прозрачности, P2-1 и P2-2 (выключатель, который в двух из трёх опубликованных сценариев не делает того, что обещает документация) — репутационный риск непропорциональный их размеру: оба чинятся десятками строк. P1-1 (тихая смерть запуска при denied-микрофоне) и P2-3 (обход QuitGate — повторение уже оплаченного `.issues/005`) — тоже маленькие правки. P3 могут ехать следующим патчем.