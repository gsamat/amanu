# Аудит готовности к публичному запуску — Amanu 0.4.15

**Домен:** релиз/сборка/упаковка/CI, зависимости и платформенные требования, `scripts/release.sh`, `Makefile`, appcast и ссылки на скачивание, лендинг (HTML/JS/nginx), серверная аналитика (SQL/retention/digest/деплой), консистентность приватности, качество тестов и отсутствующее интеграционное покрытие.
**Режим:** только чтение. Рабочее дерево не изменено — три незакоммиченных правки документации (`CLAUDE.md`, `docs/releasing.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`) сохранены как были.

## Вердикт

**Go — с коротким списком обязательных правок перед анонсом.** Релизный конвейер доказуемо работает: артефакты последнего запуска (`dist/published-appcast.xml`, `dist/published-legacy-appcast.xml`) побайтно совпадают с `landing/appcast.xml`, обе опубликованные страницы указывают на `v0.4.15`, размер DMG (9 366 600) и SHA-256 сходятся с `landing/appcast.xml:33` и `dist/amanu-v0.4.15-macos-universal.dmg.sha256`. Блокирующих дефектов, ведущих к потере данных или к разрыву цепочки обновления, я не нашёл. Найденное — это два публично видимых обещания, которые сейчас не соответствуют действительности (P1), и группа отказов «слишком поздно» в релизном скрипте (P2).

Об атрибуции: все коммиты подписаны одним автором, поэтому агентское авторство строк недоказуемо. Ниже для каждой находки указано «внесено в диапазоне `ad2dd69..HEAD`» / «существовало ранее» на основании `git blame`/`git log`, без утверждений о том, какой агент это написал.

---

## P1

### 1. В бандле распространяется код bsdiff/sais без их лицензий, при этом `THIRD-PARTY-NOTICES.md` утверждает полноту

**Статус:** подтверждённый дефект (проверено на собранном артефакте).
**Внесено:** в диапазоне — `29e852d` «Prepare Amanu for its public launch» (`Makefile:87-104`, `THIRD-PARTY-NOTICES.md` целиком).

**Триггер.** `make app` копирует в бандл ровно шесть файлов лицензий (`Makefile:90-101`) и проверяет их арифметически: `Makefile:104` и `scripts/release.sh:91` требуют `= 6`. Sparkle же поставляется как бинарный фреймворк, в который вкомпилирован вендоренный bsdiff.

**Доказательство.** В подписанном и отгружаемом бинаре:

```
$ strings -a .build/Amanu.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
    | grep -iE 'bsdiff|bspatch'
BSDIFF40H9
/usr/bin/bspatch
/usr/bin/bsdiff
```

Исходники лежат в `.build/checkouts/Sparkle/Vendor/bsdiff/` — `bspatch.c` несёт копирайт Colin Percival под BSD-2-Clause с пунктом 2 («Redistributions **in binary form** must reproduce the above copyright notice … in the documentation and/or other materials provided with the distribution»), `sais.c` — MIT Yuta Mori. `Makefile:100` копирует только `Vendor/ed25519-sparkle/license.txt`. Каталог `Vendor/` содержит два подкаталога: `bsdiff` и `ed25519-sparkle`.

**Влияние.** `THIRD-PARTY-NOTICES.md:3-5` говорит: «Exact copies of their license texts are included in every application bundle under `Contents/Resources/Licenses`». Это утверждение сейчас ложно, и оно отгружается внутри самого приложения. Плюс формальное неисполнение обязательства BSD-2-Clause в публично распространяемом бинаре. Строка `THIRD-PARTY-NOTICES.md:13` («MIT and bundled external notices») перечисляет для Sparkle только ed25519.

**Отдельно — механизм проверки ломается в опасную сторону.** Проверка `= 6` ловит только *удалённый* файл лицензии; появление новой лицензии у зависимости она не заметит никогда. Это ровно та критика, которую проект сам формулирует в `Sources/amanu/Analytics/AnalyticsCatalogue.swift:5-9` про рукописные списки: «список устаревает в опасную сторону: никто не замечает ключ, который пропустили».

**Направление фиксa.** Добавить в `Makefile` копирование `Vendor/bsdiff` (заголовок `bspatch.c` + `sais.c`, либо один файл `Sparkle-bsdiff-LICENSE.txt`), поднять счётчик и дописать две строки в `THIRD-PARTY-NOTICES.md`. Стабильнее — заменить `= 6` на перечисление ожидаемых имён файлов **и** обход `Vendor/*` и `ThirdPartyLicenses/*` у зависимостей с падением при появлении неизвестного файла.

**Регрессионный тест.** В `Tests/scripts/` (запускается и в CI, и в стадии 1 релиза): пройти по `.build/checkouts/*/`, собрать множество путей вида `LICENSE*`, `Vendor/*/license*`, `ThirdPartyLicenses/*` и сверить его с явным манифестом ожидаемых лицензий; отдельно проверить, что каждый компонент из таблицы `THIRD-PARTY-NOTICES.md` имеет файл в `Contents/Resources/Licenses`.

---

### 2. Пользовательский раздел «Gotchas» удалён из README; `SUPPORT.md` и `docs/pitfalls.md` теперь ссылаются в пустоту

**Статус:** подтверждённый дефект документации.
**Внесено:** в диапазоне — `69d256c` «Tell Amanu's product story…» (README, −865 строк) и `29e852d` (добавил `SUPPORT.md`). Ссылающаяся строка `docs/pitfalls.md:8` существовала ранее (`c2ed33a`) и была сломана изменением в диапазоне.

**Доказательство.**
- `docs/pitfalls.md:8` — «This is not the user-facing list; that is **Gotchas** in the README, and it is about running amanu rather than changing it». Раздела `## Gotchas` в `README.md` нет: заголовки README — только `What Amanu does`, `Local when you want it…`, `What a meeting leaves behind`, `Why Amanu is built this way`, `Install`, `Build from source`, `CLI`, `Configuration`, `Project`.
- `SUPPORT.md:3-4` — «Before reporting a problem, run `amanu doctor` and check [Things that will bite](docs/pitfalls.md)». `docs/pitfalls.md:1-6` явно определяет себя как документ для тех, кто *меняет* код («Constraints that are not visible from the code that depends on them… Breaking any of them compiles»).
- Содержимое удалённого раздела (из `git show 69d256c^:README.md`) сейчас не опубликовано нигде: поведение `system_audio: "all"`, различие **System Audio Recording Only** и Screen Recording в настройках приватности, охват языков Parakeet v3, поведение `spctl` на локальной сборке.

**Влияние.** На публичном запуске это прямой драйвер поддержки. Пункт про «System Audio Recording Only, а не Screen Recording» — самая предсказуемая точка непонимания для приложения, записывающего звонки: пользователь выдаёт Screen Recording, дальний конец пишется тишиной, и в продукте нет ни одного публичного текста, объясняющего почему. `README.md:137-156` («Install») об этом не говорит.

**Направление фиксa.** Вернуть в README короткий раздел «Gotchas»/«Troubleshooting» (4–6 пунктов из удалённого текста) и перенаправить `SUPPORT.md:3-4` на него вместо `docs/pitfalls.md`.

**Регрессионный тест.** В `Tests/scripts/` проверять перекрёстные ссылки документации: каждый якорь вида «**X** in the README» из `docs/*.md` должен соответствовать существующему заголовку в `README.md`; и что `SUPPORT.md` не ссылается на `docs/pitfalls.md`.

---

## P2

### 3. `SPARKLE_BIN` вычисляется до сборки — релиз падает на стадии 7, уже после нотаризации и создания тега

**Статус:** подтверждённый дефект (чтение кода).
**Внесено:** существовало ранее — `8afdfc8` (19 августа), вне диапазона.

**Триггер.** `scripts/release.sh:41`:

```sh
SPARKLE_BIN=$(find .build/artifacts/sparkle -type d -name bin 2>/dev/null | head -1)
```

Строка вычисляется в шапке скрипта, до стадии 2 (`make app` → `swift build`, `release.sh:86`), которая и материализует артефакт Sparkle. На чистом клоне (или после `swift package reset`) `.build/artifacts` не существует, `SPARKLE_BIN` пуст, и первое обращение к нему — только на `release.sh:155`:

```sh
SIGNATURE=$("$SPARKLE_BIN/sign_update" -p --ed-key-file "$SPARKLE_KEY" "$DMG")
```

**Влияние.** Скрипт падает на `/sign_update: No such file` уже после стадии 5 (нотаризация, 2–5 минут ожидания у Apple) и стадии 6 (форс-пуш тега `v$VERSION` и создание черновика релиза на GitHub). Это прямо противоречит собственному правилу скрипта — `release.sh:5-10` и `docs/releasing.md:29-33`: «Everything the release needs lives outside this repository. Check all of it first». Все остальные внешние предусловия (ключ Sparkle, `.env.asc`, ключ нотаризации, заметки, чистое дерево, ветка, состояние legacy-чекаута) проверяются на `release.sh:53-78`; это — единственное, которое не проверяется.

Восстановление возможно (релиз ещё черновик, повторный запуск удалит его и пересоздаст), но стоит один цикл нотаризации и оставляет запушенный тег.

**Направление фиксa.** Либо вычислять `SPARKLE_BIN` лениво после `make app`, либо добавить в блок проверок рядом с `release.sh:53` явную проверку наличия `sign_update` с подсказкой «run `swift build` first» — по образцу `Makefile:105`, где ровно эта проблема уже решена для `SPARKLE_FW` (там переменная намеренно ленивая, см. комментарий `Makefile:40-43`).

**Регрессионный тест.** Тест уровня shell в `Tests/scripts/`: запустить `bash -n scripts/release.sh` и статически проверить, что каждое `$(...)`-присваивание, читающее `.build/`, находится ниже строки `make app`, либо сопровождается ранней проверкой существования.

---

### 4. Стадия 3 не проверяет, что подпись сделана Developer ID — вопреки собственной документации

**Статус:** подтверждённый дефект.
**Внесено:** существовало ранее — `8aaf631` (19 августа).

**Триггер.** `scripts/release.sh:101`:

```sh
grep -E 'Identifier|Authority=Developer ID|TeamIdentifier' <<<"$DETAILS"
```

`codesign -dvvv` всегда печатает строку `Identifier=…`, поэтому альтернация всегда находит совпадение и `grep` всегда возвращает 0. Под `set -e` это никогда не остановит релиз. Реальными воротами остаются только две следующие проверки: designated requirement (`release.sh:102-103`) и hardened runtime (`release.sh:106`) — обе проходят и для подписи `Apple Development`, на которую `Makefile:56-59` умеет откатываться.

**Влияние.** `docs/releasing.md:89-91` описывает стадию 3 как «**Verify the signature.** Identity, designated requirement, hardened runtime» — первая из трёх проверок отсутствует. Практически релиз, подписанный `Apple Development`, дойдёт до стадии 4 (`release.sh:116-118`, где `security find-identity | grep 'Developer ID'` вернёт пусто и `codesign --sign ""` упадёт) или до стадии 5, где нотариус откажет **после** загрузки. Это ровно тот класс проблемы, который автор явно закрывал соседней строкой: комментарий `release.sh:104-105` («the notary service rejects the submission, and it does so after the upload rather than before it»).

**Направление фиксa.**

```sh
grep -q 'Authority=Developer ID Application' <<<"$DETAILS" \
    || die "the bundle is not signed with a Developer ID identity"
```
(отображающий `grep -E` оставить отдельной строкой).

**Регрессионный тест.** Юнит-тест на shell-функцию проверки: скормить ей зафиксированные образцы вывода `codesign -dvvv` для Developer ID / Apple Development / ad-hoc и потребовать отказа на двух последних.

---

### 5. `Tests/scripts/test_landing_analytics.py` жёстко требует `node`; на машине без него `make release` падает на стадии 1 трейсбеком

**Статус:** подтверждённый дефект.
**Внесено:** в диапазоне — `29e852d`.

**Триггер.** `Tests/scripts/test_landing_analytics.py:43-48` вызывает `subprocess.run(["node", "-e", harness, str(SCRIPT)], check=False, …)`. `check=False` подавляет только ненулевой код возврата; при отсутствии бинаря `subprocess.run` бросает `FileNotFoundError` до запуска. Тест превращается в error, `python3 -m unittest discover` возвращает ненулевой код, и `scripts/release.sh:81` под `set -e` обрывает релиз.

**Влияние.** Релиз с чистой машины без Node невозможен, и сообщение об ошибке — питоновский трейсбек, а не «install node». В CI это невидимо: раннеры GitHub macOS поставляются с Node (на этой машине — v24.18.1), поэтому дефект проявится только у того, кто «ships the next one — most likely an agent, working alone, at night, with nobody to ask» (`docs/releasing.md:3-4`).

Смежная хрупкость там же: гарнесса (строки 24-32) не стабит `matchMedia`, а третий IIFE в `landing/script.js:28-38` до него не доходит только потому, что `getElementById` возвращает `null`. Перестановка блоков в `script.js` сломает тест по причине, не связанной с аналитикой.

**Направление фиксa.** `@unittest.skipUnless(shutil.which("node"), "node is required for the landing analytics harness")` — и добавить `node` в таблицу предусловий `docs/releasing.md:35-43`. Либо дописать `global.matchMedia = () => ({ matches: false })` в гарнессу, чтобы она не зависела от порядка IIFE.

---

### 6. Блок `expires` в nginx перехватывает статику дашборда GoatCounter

**Статус:** подтверждённый дефект конфигурации; пользовательский эффект требует проверки на развёрнутом сервере.
**Внесено:** в диапазоне — `29e852d` добавил строки 80-81 (проверено `git blame -L 76,116`).

**Триггер.** `landing/deploy/nginx/amanu.conf:80-82`:

```nginx
location ~* \.(png|ico|css|js)$ {
    expires 30d;
}
```

В nginx regex-локации имеют приоритет над префиксными (кроме `^~`). Поэтому любой запрос к `/goatcounter/…` с расширением `.png|.ico|.css|.js` попадёт сюда, а не в `location /goatcounter` (`amanu.conf:101-115`), и будет отдан статикой из `root /var/www/amanu` — то есть 404, минуя `proxy_pass` и `auth_basic`. До `29e852d` эти запросы уходили в префиксную локацию и проксировались корректно.

**Влияние.** Дашборд аналитики сайта (`landing/README.md:23`: «дашборд доступен на `/goatcounter`») отдаётся без своих стилей и скриптов. Публичный сайт не затронут: `/style.css`, `/script.js`, `/assets/**.png` лежат в корне и обслуживаются этой же локацией правильно. Endpoint `/m` не затронут — точное совпадение `location = /m` (`amanu.conf:85`) выигрывает у regex.

**Направление фиксa.** `location ^~ /goatcounter { … }` (префикс с `^~` отключает regex-проверку), либо ограничить кэширующую локацию: `location ~* ^/(assets/|style\.css|script\.js)`.

**Регрессионный тест.** `landing/tests/check.py` уже парсит nginx-конфиг (строки 408-460). Добавить проверку: если есть regex-локация с расширениями, то каждая проксирующая префиксная локация должна быть объявлена как `^~`.

---

### 7. Заметки к релизу утверждают поддержку Intel, которую `docs/old-macs.md` прямо запрещает утверждать

**Статус:** подтверждённое расхождение утверждений.
**Внесено:** шаблонная строка существует с `v0.3.0` (вне диапазона); в диапазоне пропала сопровождавшая её оговорка.

**Доказательство.**
- `docs/old-macs.md:135-136`: «**Do not claim Intel support in release notes until that has happened.** "It compiles and the platform split is tested" is true and is not the same claim.»
- `docs/old-macs.md:119`: «Not measured: amanu has never run on an Intel Mac.»
- `docs/release-notes-v0.4.15.md:19` и `docs/release-notes-v0.4.14.md:14`: «macOS 15 or later, on Apple Silicon or Intel.» — без оговорки.
- Этот текст доходит до каждого пользователя: `landing/appcast.xml:20` содержит его в `<description>`, которое Sparkle показывает в окне обновления.
- Для сравнения, ранние выпуски оговорку несли: `docs/release-notes-v0.3.0.md:30-35` и `docs/release-notes-v0.4.13.md:54` («Intel hardware was not tested»).
- `README.md:149-152` формулирует честно: «the app has not yet been validated on physical Intel hardware».

**Влияние.** Репутационно-поддержечное: пользователь Intel-мака читает в окне апдейта безусловное обещание. Плюс это нарушение правила, которое проект установил себе сам, — в проекте, чья заявленная ценность в том, что его утверждения проверяемы.

**Направление фиксa.** В шаблоне «Requirements» заменить на формулировку README: «macOS 15 или новее. Сборка универсальная (arm64 и x86_64); на физическом Intel-железе не проверялась».

**Регрессионный тест.** Проверка в `Tests/scripts/`: если `docs/release-notes-v*.md` содержит слово `Intel`, файл обязан содержать и оговорку (например, подстроку `not tested` / `not been validated`) — до тех пор пока в `docs/old-macs.md` действует запрет.

---

## P3

### 8. Хранение: строки `session` могут пережить обещанный год; smoke-тест не покрывает именно тот случай, ради которого написаны `NOT EXISTS`

**Внесено:** в диапазоне (`e3d900b` / `3eee0d7`). Подтверждено чтением SQL.

`scripts/analytics/retention.sql:36-44` удаляет строку `session` старше года только если у неё не осталось ни одного дочернего ряда. Идентификатор сессии в Umami выводится из адреса и User-Agent, то есть у стабильного клиента он может не меняться месяцами: сессия, созданная 13 месяцев назад, но имеющая событие двухмесячной давности, останется навсегда — вместе с производными от адреса `country`/`region`/`city` и разобранным User-Agent. `docs/analytics.md:19` («Kept for a year, then deleted») и `docs/analytics.md:163-164` этого не оговаривают.

`scripts/analytics/retention-smoke-test.sql:16-29` создаёт только две конфигурации — «старая сессия, все дети старые» и «новая сессия, все дети новые». Ветка «старая сессия, свежий ребёнок» — единственная, ради которой предикаты `NOT EXISTS` вообще существуют, — не проверяется.

**Фикс/тест.** Добавить в smoke-тест третью сессию: `created_at = now() - 2 years` со свежей строкой в `website_event`, и утверждать, что она пережила прогон. Отдельно решить, что документировать: либо уточнить формулировку в `docs/analytics.md`, либо удалять старые `session` безусловно после удаления их старых детей.

### 9. Retention-таймер никто не наблюдает, и он захардкожен мимо `.env`

`scripts/analytics/amanu-stats-retention.service:9` использует `-U umami -d umami`, тогда как `scripts/analytics/env.example:1-2` и `scripts/analytics/README.md:48-49` предполагают настраиваемые `UMAMI_DB_USER`/`UMAMI_DB_NAME` (`weekly_digest.py:118-124` читает их из `.env` правильно). При переименовании БД сервис молча падает. У юнита нет `OnFailure=`, а `weekly-digest.sql` не сообщает возраст самой старой строки — то есть обещание «Kept for a year» опирается на таймер, отказ которого никак не заметен. Практичное усиление: одна строка в дайджесте с `MIN(created_at)` по `website_event`/`session`.

### 10. `PRIVATE_MODE=1` в compose против «derive coarse location» в публичном документе

`scripts/analytics/docker-compose.yml:15` включает `PRIVATE_MODE: "1"`, `docs/analytics.md:18-19` пишет: «Umami uses the address transiently to form a session and derive coarse location, but does not store it». Одно из двух неверно, и ничто это не проверяет. Это гипотеза, требующая проверки на сервере (я к развёрнутым сервисам не обращался). Формулировку публичного документа стоит привести в соответствие с фактической конфигурацией — это единственное место, где страница приватности говорит о геоданных.

### 11. `expires 30d` на `/style.css` и `/script.js` без версионирования

`landing/deploy/nginx/amanu.conf:80-82`. Ни один из файлов не имеет хеша или query-версии. `landing/script.js` — это код аналитики; изменение его поведения (например, отказ от отправки referrer) дойдёт до вернувшегося посетителя только через 30 дней, притом что `PRIVACY.md:37-45` описывает поведение как текущее. Фикс: `?v=<hash>` в ссылках либо `expires 1h` для `.css`/`.js` и 30 дней только для изображений.

### 12. Нет режима «только деплой», хотя рунбук обещает, что повтор безопасен

`docs/releasing.md:111-113`: «If stage 8 fails *after* the GitHub release went public, nothing is broken… re-running deployment is safe». Но `scripts/release.sh:143-147` при уже опубликованном теге завершится с «already published — bump VERSION», а отдельного флага для повторной выкладки сайта/фида нет. Оператор вынужден выполнять `rsync` руками, чего рунбук не описывает. Фикс: `scripts/release.sh --deploy-only`, выполняющий стадию 8 и финальную верификацию.

### 13. Отсутствующие «шпильки» между файлами, которые обязаны совпадать

Ни один тест не связывает:
- `Makefile:33` (`VERSION`) ↔ `<title>` в `landing/appcast.xml:9` ↔ существование `docs/release-notes-v$VERSION.md`;
- `Package.swift:6` (`.macOS(.v15)`) ↔ `Packaging/Amanu-Info.plist:23-24` (`LSMinimumSystemVersion`) ↔ `landing/appcast.xml:11` (`sparkle:minimumSystemVersion`) — при том что `docs/old-macs.md:26-28` называет первые две «единственными двумя местами, где этот порог объявлен», забывая про третье;
- версии в `THIRD-PARTY-NOTICES.md:9-14` ↔ `Package.resolved` (сейчас совпадают: FluidAudio 0.15.5, argument-parser 1.8.2, Sparkle 2.9.6, но только вручную);
- **тест-процесс никогда не стартует аналитику.** Сейчас это верно и проверено: `AnalyticsSink.record` защищён `guard enabled, started` (`Sources/amanu/Analytics/AnalyticsSink.swift:149`), а `Analytics.start` вызывается только из `Amanu.swift:100`, `AnalyticsCommand.swift:37` и `SessionCommands.swift:74` — ни один тест туда не заходит. Но это не закреплено: тест или ленивый вызов, который стартует общий sink, начнёт писать в реальный `~/.config/amanu/analytics-pending.json` разработчика и POST-ить на прод из CI. Проект уже создал прецедент такой шпильки для нотификаций — `Tests/amanuTests/NativeAppTests.swift:163-173` («redundant is not the same as pinned»); для аналитики аналога нет.

Каждый из четырёх — 5–15 строк теста в `Tests/scripts/` или `Tests/amanuTests/`.

### 14. `notes-to-html.py`: буллеты, разделённые пустой строкой, дают по `<ul>` на пункт

`scripts/notes-to-html.py:41-43`: пустая строка вызывает `close_list()`. `docs/release-notes-v0.4.13.md` написан именно так (пункты через пустую строку), поэтому в окне Sparkle он вышел шестью отдельными списками вместо одного. Косметика, уже отгруженная; `docs/pitfalls.md:362-371` фиксирует другое ограничение того же скрипта (`**bold**` через перенос), но это — нет. Разумно либо не закрывать список на одиночной пустой строке, либо дописать пункт в pitfalls.

### 15. Мелкие расхождения в словаре аналитики

- `Sources/amanu/Analytics/Analytics.swift:63` в комментарии называет значение `mic_activity`, тогда как на проводе `mic-activity` (`Sources/amanu/RecordingSession.swift:45`). `docs/analytics.md:98` при этом корректен. Комментарий вводит в заблуждение автора будущего SQL-запроса.
- `scripts/analytics/reports.sql:27` фильтрует `trigger neq "cli"` — такого значения `trigger` не существует ни в коде, ни в `docs/analytics.md:98`. Фильтр работает (лишний `neq` безвреден), но документирует несуществующее измерение.
- `Tests/scripts/test_analytics_reporting.py:76` использует в фикстуре `mic_activity` — сам по себе не баг, но показывает, что реальные значения `trigger` не проверяются ни одним тестом.

### 16. `from: "0.7.0"` для 0.x-зависимости

`Package.swift:9` объявляет FluidAudio как `from: "0.7.0"`, что для 0.x означает диапазон `0.7.0..<1.0.0`; фактически протестирована и закреплена 0.15.5 (`Package.resolved:10`). Сборки воспроизводимы благодаря `Package.resolved`, но манифест больше не описывает реальное требование, а Dependabot (`.github/dependabot.yml:3-6`) обновляет этот экосистемный канал еженедельно. Ужесточить до `from: "0.15.5"`.

### 17. `$connection_upgrade` используется, но не объявлен в чекнутом конфиге

`landing/deploy/nginx/amanu.conf:114` ссылается на `$connection_upgrade`, а соответствующего `map $http_upgrade …` в файле нет — в отличие от `$amanu_home_is_ru`, который объявлен тут же (строки 6-9). Если переменная не определена в `http`-блоке хоста, nginx не стартует. Файл позиционируется как «копия боевого конфига» (`landing/README.md:19-20`), поэтому асимметрия — ловушка при переносе на новый хост.

### 18. Остаточная хрупкость `AnalyticsSink.flush` в тестах (гипотеза, требует прогонов)

`Sources/amanu/Analytics/AnalyticsSink.swift:204-215` блокирует поток вызывающего семафором, ожидая `Task { await transport(body) }`, который исполняется на кооперативном пуле. Swift Testing запускает тесты как `Task`, поэтому в тестах блокируется поток того же пула. Проблема уже дважды диагностировалась в диапазоне — `34df362` «Wait for analytics sends already in flight» и `8ad69a2` «Serialize stateful analytics queue tests» (последний добавил `.serialized` в `Tests/amanuTests/AnalyticsTests.swift:12`). `.serialized` сериализует только тесты внутри этого сьюта; остальные сьюты по-прежнему идут параллельно. При малом числе ядер это остаётся источником флейков `flush(waitingUpTo: 0.5)`. Направление: async-вариант flush для тестов либо выполнение ожидания на отдельном `Thread`.

### 19. `ApplicationRelocation.launch` блокирует главный поток до 20 секунд (гипотеза; пересекается с доменом install-ревьюера)

`Sources/amanu/ApplicationRelocation.swift:97-115` — `@MainActor`-функция ждёт `DispatchSemaphore` до 20 с, пока `NSWorkspace.openApplication` вызовет completion. Это путь самого первого запуска из DMG — то есть наиболее нагруженный сценарий на публичном запуске. Если completion когда-либо доставляется на главную очередь, это дедлок на 20 секунд; если на фоновую (что вероятнее) — просто замороженный UI. Требует воспроизведения; передаю смежному ревьюеру.

---

## Покрытие и ограничения

**Прочитано полностью:** `Makefile`, `scripts/release.sh`, `scripts/update-site-download-links.py`, `scripts/notes-to-html.py`, все файлы `scripts/analytics/` (SQL, compose, systemd, caddy, env, README), `Package.swift`, `Package.resolved`, `Packaging/Amanu-Info.plist`, `Packaging/Amanu.entitlements`, `.github/workflows/ci.yml`, `.github/dependabot.yml`, `.github/ISSUE_TEMPLATE/*`, `landing/` целиком (обе главные, обе privacy, `script.js`, `appcast.xml`, `robots.txt`, `sitemap.xml`, оба nginx-конфига, `tests/check.py`), `README.md`, `PRIVACY.md`, `SECURITY.md`, `SUPPORT.md`, `CONTRIBUTING.md`, `LICENSE`, `THIRD-PARTY-NOTICES.md`, `CLAUDE.md`, `docs/releasing.md`, `docs/pitfalls.md`, `docs/old-macs.md`, `docs/analytics.md`, заметки 0.4.13–0.4.15, все `.issues/*` (все со статусом `done` — открытых нет), все `Tests/scripts/*`, `Tests/amanuTests/AnalyticsTests.swift`, `WindowShots.swift`, `NativeAppTests.swift`, диффы тестов в диапазоне. Точечно: `Analytics.swift`, `AnalyticsSink.swift`, `AnalyticsCatalogue.swift`, `AppUpdates.swift`, `UpdateGate.swift`, `ApplicationRelocation.swift` — как места стыковки с моим доменом.

**Проверено эмпирически (только чтение):** извлечение версии `sed`-ом из `Makefile` → `0.4.15`; `git rev-list --count HEAD` = 274 > `sparkle:version=273`; SHA-256 и размер DMG против appcast; SHA-256 английских скриншотов против захардкоженных в `check.py:366-369` (совпадают, то есть CI и релиз сейчас зелёные по этой проверке); строки bsdiff в отгружаемом `Autoupdate`; наличие `node`/`xmllint`/`python3` на релизной машине; компиляция всех Python-скриптов системным Python 3.9.6.

**Не проверялось (вне мандата или без сети):**
- Развёрнутые сервисы: `stats.amanu.me`, `misch`, `reina`, GoatCounter, Umami, реальная схема БД Umami 3.3 (наличие `session.distinct_id`, `session_link`, `session_data.created_at`, семантика `PRIVATE_MODE`). Всё, что касается их, помечено как предположение о деплое.
- Не читал `.env.asc`, приватные ключи, реальные записи, содержимое `~/.config/amanu`.
- Не запускал `swift test`, `landing/tests/check.py`, `Tests/scripts/*` и никакие проектные скрипты — прогон за родительским агентом. Все утверждения о тестах сделаны по чтению кода.
- Валидность лейбла раннера `macos-26` и тега `actions/checkout@v6` (`.github/workflows/ci.yml:18,21`, второй изменён в диапазоне коммитом `1e31496`) без сети не подтверждается — стоит просто убедиться, что последний прогон CI зелёный.
- Логика записи звука, аудиотракты, live-транскрипт — домен другого ревьюера.

**Что покрыто тестами хорошо (не нужно трогать):** каталог аналитики закреплён в обе стороны против `docs/analytics.md` (`Tests/amanuTests/AnalyticsTests.swift:477-560`), включая «страница не называет несуществующих событий»; правило «только тумблеры и фиксированные варианты» проверяется через сам `SettingsSchema`, а не списком (`AnalyticsTests.swift:394-457`); лендинг проверяется структурно, включая nginx-детекцию языка на пяти конкретных заголовках `Accept-Language` (`check.py:428-440`) и хеши скриншотов; связка appcast ↔ `SUFeedURL` закреплена (`test_update_feed_location.py`); скриншотные сьюты выключены без `AMANU_SHOTS`, поэтому CI не хрупкий; ни один тест не ходит в сеть.

**Чего в тестах нет, а стоило бы (по убыванию ценности):** сборка бандла целиком не проверяется нигде, кроме самого релиза — ни в CI, ни в `swift test` (`make app`, универсальность через `lipo`, комплект лицензий, порядок подписи вложенного кода, наличие Sparkle-фреймворка); проверка `retention.sql` на случае «старая сессия со свежим ребёнком»; `weekly-digest.sql` и `reports.sql` не исполняются ни в одном тесте вообще (только `assertIn` по тексту файла в `test_analytics_reporting.py:41-51`), в отличие от `retention.sql`, у которой smoke-тест есть; шпильки версий из п.13; рендер актуальных заметок через `notes-to-html.py` (сейчас `docs/pitfalls.md:369-371` предлагает делать это вручную `grep '\*'`).

---

## Практический список перед анонсом

1. Добавить лицензии bsdiff/sais в бандл и в `THIRD-PARTY-NOTICES.md`, заменить проверку `= 6` на проверку по именам (P1 №1).
2. Вернуть пользовательский раздел «Gotchas» в README и перенаправить на него `SUPPORT.md`; починить ссылку `docs/pitfalls.md:8` (P1 №2).
3. Три однострочные правки в `scripts/release.sh`: ленивый `SPARKLE_BIN`, реальная проверка `Authority=Developer ID`, и `skipUnless(node)` в тесте лендинга (P2 №3–5).
4. `location ^~ /goatcounter` в nginx (P2 №6).
5. Убрать безусловное утверждение про Intel из шаблона заметок к релизу либо вернуть оговорку (P2 №7).

Пункты 1–2 стоит сделать до публичного анонса; 3–5 можно в первую неделю. Остальное — бэклог. Ничего из найденного не требует откладывать запуск.