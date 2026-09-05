# Аудит домена «Запись/захват аудио и транскрипция» — Amanu 0.4.15 (HEAD b5e8a77)

Независимая проверка Fable, только чтение. Файлы проекта, git-состояние и настройки не изменялись. Отчёты предыдущих аудитов под `docs/audits/` и `.build/audit*/` не открывались.

## Итог (TL;DR)

Код домена — очень высокого качества: продуманная конкурентность (единый `OSAllocatedUnfairLock` на разделяемое состояние рекордеров, actor-изоляция координаторов, epoch-проверки в live-ASR), аккуратные жизненные циклы и обширные регрессионные тесты, привязанные к конкретным измеренным инцидентам. Все закрытые `.issues` действительно закрыты в коде, а решения из `docs/pitfalls.md` подтверждаются реализацией (сохранение echo cancellation при рестарте, паддинг тишины после attach, слежение за микрофоном, manifest до старта захвата).

Одна **подтверждённая по коду** регрессия свежего изменения способна молча потерять расшифровку целой встречи (P2). Остальное — одно интеграционное наблюдение по аналитике (P3), одна давняя гипотеза о subprocess-дедлоке вне кандидатского диапазона (P2, требует воспроизведения) и один пробел в поведенческих тестах.

**Рекомендация по моему домену: УСЛОВНЫЙ GO.** Блокеров запуска нет; находку P2 (потеря расшифровки на дефектной дорожке) стоит закрыть до или сразу после релиза — фикс маленький и локальный.

---

## Находки (по убыванию приоритета)

### P2 — Multichannel-расшифровка (AssemblyAI) падает целиком из-за одной пустой/нечитаемой дорожки; per-track и прежний mixed были устойчивы

**Статус: подтверждённый дефект кода. Введён в кандидатском диапазоне (коммит `8835234 Preserve playback quality during recording`, v0.4.11), которым AssemblyAI переведён с `.mixed` на `.multichannel`.**

**Где:**
- `Sources/amanu/Audio/TrackCompressor.swift:196-203` — замыкание `source(_:)` внутри `encodeStereo`: если файл **существует**, но не открывается как аудио либо имеет `file.length == 0` (0 аудио-фреймов), бросается `CompressionError.unreadable`.
- `Sources/amanu/Transcription/TranscriptionCoordinator.swift:416-426` — `transcribeMultichannel` вызывает `encodeStereo` и пробрасывает ошибку (`throw error`) наверх, роняя всю расшифровку сессии.
- Контраст (устойчивое поведение): `Sources/amanu/Audio/AudioMixer.swift:178-186` — `AudioMixer.Source.init?` на пустом треке возвращает `nil` (трек пропускается, микс собирается из оставшегося). Именно так работал прежний `.mixed`-путь AssemblyAI.
- Контраст: `Sources/amanu/Transcription/TranscriptionCoordinator.swift:470-477` — `transcribePerTrack` ловит ошибку трека и делает `continue`, сохраняя расшифровку второй дорожки.

**Триггер и импакт.** Наиболее правдоподобный путь — ранний краш с последующим восстановлением. `SystemAudioRecorder.start()` создаёт `system.caf` и пишет CAF-заголовок сразу (`makeFile`), а первые буферы системного тапа приходят с задержкой (прогрев aggregate device). Если процесс убит через 1–2 секунды после старта, `mic.caf` уже содержит фреймы, а `system.caf` — только заголовок (0 аудио-фреймов, но ненулевой размер файла в байтах). `RecordingSession.recoverInterrupted` оценивает пригодность по **размеру файла в байтах** (`RecordingSession.swift:405-416`, `guard largest > 0`), поэтому такую сессию усыновляет и ставит в очередь. Затем при движке по умолчанию (AssemblyAI, `auto`→cloud при наличии ключа) `transcribeMultichannel` зовёт `encodeStereo`, который смотрит уже на **аудио-длину** (`file.length == 0`) и бросает. Итог: расшифровка падает, не является network-ошибкой и не `isPermanent`, поэтому счётчик попыток растёт до `maxAttempts=3`, после чего сессия ретайрится (`TranscriptionCoordinator.swift:256-302`). Расшифровка целой встречи (в т.ч. полноценной `mic`-дорожки) не создаётся автоматически; аудио сохраняется (failure-path его не удаляет), но пользователь должен вручную заметить и запустить `amanu process --again`.

Это регрессия: до `8835234` тот же вход дал бы `mixed.m4a` из одной валидной дорожки и расшифровку (пусть без дальней стороны). Несогласованность двух метрик усугубляет проблему: recovery меряет байты, `encodeStereo` — фреймы.

Примечание к области действия: дефект проявляется на **первичной** расшифровке из raw-CAF (`!sharedArchive`). При `keep_audio=on` и повторной расшифровке из общего `audio.m4a` ветка `encodeStereo` не выполняется (`TranscriptionCoordinator.swift:399-405`).

**Предлагаемый регрессионный тест.** По образцу `Tests/amanuTests/Sessions/RetranscriptionTests.swift`: `rawSession`, где `system.caf` записан с 0 аудио-фреймов (только заголовок) или содержит не-аудио байты, а `mic.caf` валиден; прогнать `TranscriptionCoordinator(engine: MultichannelEngine()).transcribeNow(dir)` и ожидать, что расшифровка `me`-стороны создана, а не выброшено исключение. Симметричный кейс — отсутствующая `them`-дорожка (уже работает) против пустой (сейчас падает).

**Направление фикса.** Привести `encodeStereo` в соответствие с `AudioMixer.Source`: трактовать существующий-но-пустой/нечитаемый трек как пропускаемый (`nil`), а не как фатальную ошибку — при условии, что хотя бы один источник пригоден (`guard !sources.isEmpty` уже есть на `TrackCompressor.swift:208`). Тогда одна дефектная дорожка не будет стоить расшифровки другой, как в per-track- и mixed-путях. Осторожно: `encodeStereo` также вызывается из `TrackCompressor.compress` (`keep_audio`) — там текущий бросок безопасен (оригиналы сохраняются), так что менять поведение нужно так, чтобы «есть хотя бы одна валидная дорожка» по-прежнему давало корректный архив.

---

### P3 — Отброшенная авто-запись учитывается в аналитике дважды: `recordingFinished` и следом `recordingDiscarded`

**Статус: подтверждено по коду. Интеграционное наблюдение; сама аналитика — домен второго ревьюера, здесь фиксирую только стык с записью.**

**Где:**
- `Sources/amanu/RecordingSession.swift:232-242` — `stop()` всегда трекает `.recordingFinished`.
- `Sources/amanu/RecordingSession.swift:306-313` — `discard()` трекает `.recordingDiscarded`.
- `Sources/amanu/Amanu.swift:765,783-792` — `AppController.stopSession` сначала вызывает `session.stop(reason:)`, затем (при `shouldDiscard`) `session.discard()`.

**Импакт.** Короткая авто-запись, которую выбраковывают как ложное срабатывание, порождает оба события: `recordingFinished` (с `durationBucket`, `systemAudio`) и `recordingDiscarded`. Это не влияет на сохранность данных и не является багом записи, но завышает долю «завершённых» записей в метриках на величину выброшенных. Если это нежелательно, порядок можно перестроить так, чтобы `stop()` не эмитил `recordingFinished`, когда вызывающий намерен немедленно выбраковать сессию. Передаю на подтверждение ревьюеру аналитики.

---

### P2 (гипотеза, требует воспроизведения; вне кандидатского диапазона) — Возможный дедлок каналов в `LLMBackend.run()` при крупном stdin и говорливом stdout

**Статус: гипотеза. Логика `run()` в кандидатском диапазоне не менялась (диффы `LLMBackend`/`Summarizer`/`SpeakerNamer` — только добавление поля `model` и аналитики). Влияет на постобработку: именование спикеров и саммари.**

**Где:** `Sources/amanu/Summary/LLMBackend.swift:256-268` — весь stdin пишется синхронно (`stdin.write(...)`, стр. 259) и лишь затем читается stdout (`readDataToEndOfFile`, стр. 266).

**Импакт.** Для `codex-cli` (пишет прогресс-трассировку в stdout, читает промпт из stdin через `-`) при большом транскрипте в stdin и объёмной трассировке в stdout возможна классическая взаимоблокировка каналов: дочерний процесс блокируется на записи в переполненный буфер stdout, родитель — на записи stdin, пока `killer` не сработает по таймауту (`timeout: 1800`, стр. 262-263). Не вечное зависание, но до 30 минут задержки постобработки в худшем случае с последующим падением на этот бэкенд и переходом к следующему. Для `claude-cli` риск ниже (stdout — только финальный текст). Транскрипт передаётся как stdin-промпт (`SpeakerNamer.maxChars=60_000`, `Summarizer` бьёт на чанки по 60 КБ), что близко к типичному размеру pipe-буфера macOS (~64 КБ), поэтому граничные встречи реальны. Проверять в рантайме: длинная встреча + `summary.backend`/`speaker_names.backend` = `codex-cli`. Фикс-направление — читать stdout/stderr конкурентно с записью stdin (отдельная очередь/поток или неблокирующая запись).

---

### Пробел в тестах — нет поведенческого покрытия multichannel-пути с дефектной/пустой дорожкой

`Tests/amanuTests/Sessions/RetranscriptionTests.swift` покрывает multichannel с двумя валидными дорожками (`rawSessionTranscribesAsMultichannel`) и общий архив, но не проверяет устойчивость к существующему-но-пустому или нечитаемому треку. `TrackCompressorTests.unreadableTrackSurvives` покрывает только `compress` (не фатальный путь), но не `transcribeMultichannel` (фатальный). Этот пробел напрямую связан с находкой P2 выше.

---

## Что проверено и признано корректным (защита от ложных тревог)

- **Подавление после ручной остановки** (`AutoRecordController.swift:106-158`, коммит `0e71efa`): переход с 15-минутного `cooldownUntil` на `suppressingAfterManualStop` до реального конца звонка. Логика снятия подавления по первому периоду простоя `> stopDelay` корректна и покрыта `ManualStopAutoRecordTests`.
- **`writeManifest()` до старта захвата** (`RecordingSession.swift:148-166`): маркер пишется первым, при ошибке любого рекордера удаляется, система/файлы очищаются — потери аудио при частичном старте нет. Крайне узкое окно (краш между `createDirectory` и `writeManifest`) оставляет лишь пустую папку — не актуально.
- **Рестарт микрофона** (`MicRecorder.restartCapture`/`fallBackToRaw`): сохранение voice processing, паддинг тишины после attach, storm-лимит, различение «наш attach» от «мёртвый движок» через `audioIsFlowing` — соответствуют `pitfalls.md` и rca-001/003. Liveness-переменные без блокировки безопасны за счёт порядка `engine.start()`.
- **Привязка каналов multichannel**: `encodeStereo` кладёт mic в канал 0 (лево), system в канал 1 (право); `AssemblyAIEngine.requestBody` шлёт `multichannel:true`; `MultichannelSpeakerLabels.sideLabel` мапит `1→me`, `2→them`. Согласовано; покрыто `AssemblyAIEngineTests` и `RetranscriptionTests`.
- **`SpeakerAttribution.resolve`** корректно обрабатывает общий архив (`sharedArchive`, стр. 71-74), читая каналы 0/1 — мой начальный сценарий двойного чтения одного файла опровергнут.
- **Claiming/recovery/повторная обработка**: `SessionClaim` (O_EXCL, reclaim мёртвого pid, release только своего), `PostProcessor` (claim перед моделью, sweep не конкурирует за одну сессию), кэш AssemblyAI переименован в `transcript.assemblyai.multichannel.json` и намеренно сохраняется при `markForRetranscription`. Устойчиво.
- **Утечка live-ASR исправлена**: `finishRecording` обнуляет `update`/`attach` (`LiveTranscriptionCoordinator.swift:120-124`), освобождая захваченную сессию и её mic-движок.
- **Данные при quit/SIGTERM**: `stop()` синхронно пишет `meta.json` и финализирует CAF до асинхронного `enqueue`; при завершении процесса расшифровка подхватывается `resumePending` на следующем запуске.

---

## Покрытие и ограничения

- Прочитаны и прослежены по вызовам: `RecordingSession`, `MicRecorder`, `SystemAudioRecorder`, `AudioLevel/AudioFormats`, `LiveAudioBufferRelay`, `MicRoute`, `MicActivityMonitor`, `AutoRecordController`, `AppController`/`Amanu.swift`, `Config`, `TranscriptionCoordinator`, `TranscriptionEngine`/`MultichannelSpeakerLabels`, `AssemblyAIEngine`, `OpenAIEngine`, `ParakeetEngine`, `MeetingLanguages`, `EchoFilter`, `SpeakerAttribution`, `AudioChannelExtractor`, `TrackCompressor`, `AudioMixer`, `AudioSlicer`, `PostProcessor`, `SessionClaim`, `SessionState`, `SpeakerNamer`, `Summarizer`, `LLMBackend`, `LiveTranscriptionCoordinator`, `RecordCommand`, `SessionCommands`, `MeetingContext`. Диффы кандидатского диапазона `ad2dd69..HEAD` по этим файлам разобраны; каждая находка атрибутирована через `git log -S`/blame (multichannel и `sharedArchive` — коммит `8835234` в диапазоне; логика `LLMBackend.run` и per-track `continue` — до диапазона).
- Прочитаны тесты домена и `docs/pitfalls.md`, `.issues/*` (все `status: done`).
- **Ограничения**: тесты не запускались (по заданию — родитель прогоняет отдельно). Аудио-пути, требующие реального устройства (реальный краш с 0-фреймовым системным треком для P2; codex-cli с крупным транскриптом для гипотезы дедлока), не воспроизводились в рантайме — severity для них оценена по чтению кода. Смежные домены (аналитика, установка/релокация, релиз/CI, UI-окна, лицензии/THIRD-PARTY-NOTICES) не аудировались, кроме точек интеграции.