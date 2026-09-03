#!/usr/bin/env python3
"""Automated checks for the bilingual Amanu landing page.

Observable structure and behaviour only: English is the default, Russian lives
at /ru/, language metadata and switching are reciprocal, releases are real,
resources stay local, and accessibility plus colour/motion preferences hold.
"""

import hashlib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

LANDING = Path(__file__).resolve().parent.parent
ROOT = LANDING.parent
EN_INDEX = LANDING / "index.html"
RU_INDEX = LANDING / "ru" / "index.html"
EN_PRIVACY = LANDING / "privacy" / "index.html"
RU_PRIVACY = LANDING / "ru" / "privacy" / "index.html"
NGINX = LANDING / "deploy" / "nginx" / "amanu.conf"
APPCAST = (LANDING / "appcast.xml").read_text(encoding="utf-8")
DMG = re.search(r'<enclosure\s+[^>]*url="([^"]+)"', APPCAST, re.S).group(1)

failures = []


def check(name, ok, detail=""):
    mark = "ok  " if ok else "FAIL"
    print(f"{mark} {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.html_lang = None
        self.h1_count = 0
        self.title = ""
        self._in_title = False
        self.meta_description = None
        self.links = []
        self.anchors = []
        self.resources = []
        self.imgs = []
        self.forms = []
        self.script_srcs = []
        self.inline_scripts = []
        self._in_script = False
        self.onclick_count = 0
        self.positive_tabindex = 0
        self.stylesheets = []
        self.alternates = []
        self.canonicals = []
        self.meta = {}

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if any(k.startswith("on") for k in a):
            self.onclick_count += 1
        ti = a.get("tabindex")
        if ti and ti.lstrip("-").isdigit() and int(ti) > 0:
            self.positive_tabindex += 1
        if tag == "html":
            self.html_lang = a.get("lang")
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content")
            if a.get("name") == "description":
                self.meta_description = a.get("content")
        elif tag == "a":
            self.links.append(a.get("href", ""))
            self.anchors.append(a)
        elif tag == "img":
            self.imgs.append(a)
            if a.get("src"):
                self.resources.append(("img", a["src"]))
        elif tag == "source":
            for part in a.get("srcset", "").split(","):
                url = part.strip().split()[0] if part.strip() else ""
                if url:
                    self.resources.append(("source", url))
        elif tag == "link":
            href = a.get("href", "")
            rel = a.get("rel", "").split()
            if "stylesheet" in rel:
                self.stylesheets.append(href)
            if any(item in rel for item in ("stylesheet", "icon", "apple-touch-icon")):
                self.resources.append(("link", href))
            if "alternate" in rel:
                self.alternates.append((a.get("hreflang"), href))
            if "canonical" in rel:
                self.canonicals.append(href)
        elif tag == "script":
            self._in_script = True
            if a.get("src"):
                self.script_srcs.append(a["src"])
                self.resources.append(("script", a["src"]))
        elif tag == "form":
            self.forms.append(a.get("action", ""))

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "script":
            self._in_script = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_script:
            self.inline_scripts.append(data)


def parse_page(path):
    html = path.read_text(encoding="utf-8")
    parser = PageParser()
    parser.feed(html)
    return html, parser


def is_external(url):
    s = urlsplit(url)
    return s.scheme in ("http", "https") or url.startswith("//")


def resolves_locally(page_path, url):
    s = urlsplit(url)
    if s.scheme or url.startswith("//"):
        return False
    path = unquote(s.path)
    if not path:
        return True
    if path.startswith("/"):
        return (LANDING / path.lstrip("/")).is_file()
    return (page_path.parent / path).resolve().is_file()


def main():
    check("английская главная существует", EN_INDEX.is_file())
    check("русская версия существует в /ru/", RU_INDEX.is_file())
    check("английская privacy-страница существует", EN_PRIVACY.is_file())
    check("русская privacy-страница существует", RU_PRIVACY.is_file())
    if not EN_INDEX.is_file() or not RU_INDEX.is_file():
        return finish()

    en_html, en = parse_page(EN_INDEX)
    ru_html, ru = parse_page(RU_INDEX)
    pages = (("EN", EN_INDEX, en_html, en), ("RU", RU_INDEX, ru_html, ru))

    # Routes, metadata, and reciprocal language navigation.
    check("lang=en на главной", en.html_lang == "en", f"lang={en.html_lang!r}")
    check("lang=ru в /ru/", ru.html_lang == "ru", f"lang={ru.html_lang!r}")
    check("canonical главной", en.canonicals == ["https://amanu.me/"], str(en.canonicals))
    check("canonical русской версии", ru.canonicals == ["https://amanu.me/ru/"], str(ru.canonicals))
    expected_alternates = {
        ("en", "https://amanu.me/"),
        ("ru", "https://amanu.me/ru/"),
        ("x-default", "https://amanu.me/"),
    }
    for label, _, _, page in pages:
        check(
            f"{label}: полная карта hreflang",
            set(page.alternates) == expected_alternates,
            str(page.alternates),
        )
        check(f"{label}: ровно один <h1>", page.h1_count == 1, f"h1×{page.h1_count}")
        check(f"{label}: <title> непустой", bool(page.title.strip()))
        check(
            f"{label}: meta description непустой",
            bool(page.meta_description and page.meta_description.strip()),
        )
        check(f"{label}: social preview — large image", page.meta.get("twitter:card") == "summary_large_image")
        check(f"{label}: Open Graph image", page.meta.get("og:image") == "https://amanu.me/assets/social-preview.png")
        check(f"{label}: Open Graph URL", page.meta.get("og:url") == page.canonicals[0])

    en_to_ru = [a for a in en.anchors if a.get("href") == "/ru/"]
    ru_to_en = [a for a in ru.anchors if a.get("href") == "/en/"]
    check(
        "EN: единственный переключатель в футере ведёт на русский",
        len(en_to_ru) == 1
        and all(a.get("lang") == "ru" and a.get("hreflang") == "ru" for a in en_to_ru),
        str(en_to_ru),
    )
    check(
        "RU: единственный переключатель в футере ведёт на английский",
        len(ru_to_en) == 1
        and all(a.get("lang") == "en" and a.get("hreflang") == "en" for a in ru_to_en),
        str(ru_to_en),
    )
    check(
        "EN: ресурсы абсолютны и работают на ручном адресе /en/",
        all(url.startswith("/") for _, url in en.resources),
        str(en.resources),
    )
    for label, html in (("EN", en_html), ("RU", ru_html)):
        masthead = re.search(r'<header class="masthead">(.*?)</header>', html, re.S)
        check(
            f"{label}: в шапке нет переключателя языка",
            bool(masthead) and 'class="lang"' not in masthead.group(1),
        )

    # Requested Russian copy and attribution remain intact after moving to /ru/.
    readable_ru = ru_html.replace("&nbsp;", " ")
    flat_ru = re.sub(r"\s+", " ", readable_ru)
    check(
        "RU: бинарник назван нотаризованным Apple",
        readable_ru.count("нотаризован Apple") == 1
        and "подписанный бинарник" not in readable_ru,
    )
    check(
        "RU: нижний блок говорит о бесплатности и открытом коде",
        bool(re.search(
            r'Amanu полностью бесплатная, у неё <a href="https://github\.com/gsamat/amanu">'
            r'открытый исходный код</a>\. Установка лёгкая — скачайте и запустите\.',
            flat_ru,
        ))
        and "Amanu полностью бесплатная:" not in flat_ru,
    )
    check(
        "RU: заголовок честно говорит о локальной библиотеке",
        "<h2>Ваша библиотека встреч хранится на маке</h2>" in readable_ru,
    )
    check(
        "RU: в футере Самат Галимов со ссылкой на samat.me/ru",
        bool(re.search(
            r'<footer>.*<a href="https://samat\.me/ru">Самат Галимов</a>.*</footer>',
            ru_html,
            re.S,
        ))
        and "mailto:s@samat.me" not in ru_html,
    )
    check(
        "RU: подпись к статусу без «уже»",
        "<figcaption>Встреча идёт — Amanu пишет.</figcaption>" in ru_html
        and "Amanu уже пишет" not in ru_html,
    )
    check(
        "RU: модели должны работают по-полной",
        "Я считаю, что модели должны работают по-полной, тем более если у вас уже "
        "есть подписка на клод или chatgpt." in flat_ru
        and "нужно экономить наше время" not in flat_ru,
    )
    check(
        "EN: Windows-кнопка обещает уведомление",
        bool(re.search(r">\s*Notify me when Windows is available\s*</a>", en_html))
        and "Ask about the Windows version" not in en_html,
    )

    # Public links, local resources, scripts, and accessibility on both pages.
    expected_windows_bodies = {
        "EN": "Please let me know when the Windows version is available!",
        "RU": "Сообщите мне, когда появится windows версия, пожалуйста!",
    }
    for label, path, html, page in pages:
        check(
            f"{label}: обе кнопки ведут прямо на DMG",
            page.links.count(DMG) == 2,
            f"ссылок на DMG: {page.links.count(DMG)}",
        )
        check(
            f"{label}: нет ссылок на releases/latest",
            not any("releases/latest" in href for href in page.links),
        )
        check(
            f"{label}: ссылка на исходный код",
            any(re.search(r"github\.com/gsamat/amanu/?$", href) for href in page.links),
        )

        windows_mailto = [
            href for href in page.links
            if href.startswith("mailto:amanu-windows@samat.me")
        ]
        check(f"{label}: mailto для Windows-интереса", bool(windows_mailto))
        if windows_mailto:
            query = parse_qs(urlsplit(windows_mailto[0]).query)
            body = (query.get("body") or [""])[0]
            check(
                f"{label}: в письме про Windows готовое тело",
                body.strip() == expected_windows_bodies[label],
                f"body={body!r}",
            )
        check(
            f"{label}: нет формы с сетевым action",
            all(not action or action.startswith("mailto:") for action in page.forms),
        )
        check(
            f"{label}: скрипт локальный и общий",
            page.script_srcs == ["/script.js"],
            str(page.script_srcs),
        )
        check(
            f"{label}: нет внешних ресурсов (img/link/source)",
            all(not is_external(url) for _, url in page.resources),
            str([url for _, url in page.resources if is_external(url)]),
        )
        check(
            f"{label}: все локальные ресурсы существуют",
            all(resolves_locally(path, url) for _, url in page.resources),
            str([url for _, url in page.resources if not resolves_locally(path, url)]),
        )
        scripts = (LANDING / "script.js").read_text(encoding="utf-8")
        check(f"{label}: нет inline-скриптов", not "".join(page.inline_scripts).strip())
        check(
            f"{label}: инлайн-скрипты не ходят на чужие домены",
            not re.search(r"fetch\(|XMLHttpRequest|https?://", scripts),
        )
        check(
            f"{label}: просмотр считается через first-party /m",
            bool(re.search(r"new URL\(['\"]\/m['\"],\s*location\.origin\)", scripts))
            and "location.pathname" in scripts
            and "document.title" in scripts
            and "screen.width" in scripts
            and "document.referrer" in scripts
            and "new Image().src" in scripts,
        )
        expected_privacy = "/privacy/" if label == "EN" else "/ru/privacy/"
        check(f"{label}: privacy доступна из футера", expected_privacy in page.links)
        check(f"{label}: у всех <img> есть alt", all("alt" in attrs for attrs in page.imgs))
        check(
            f"{label}: у всех <img> есть width и height",
            all("width" in attrs and "height" in attrs for attrs in page.imgs),
        )
        check(f"{label}: нет inline-обработчиков on*", page.onclick_count == 0)
        check(f"{label}: нет tabindex > 0", page.positive_tabindex == 0)
        check(
            f"{label}: скриншоты в обеих темах",
            any("dark" in url for _, url in page.resources)
            and any("light" in url for _, url in page.resources),
        )

        entries = re.findall(r'<section class="entry[^"]*">(.*?)</section>', html, re.S)
        timed = [entry for entry in entries if re.search(r'<p class="tc"[^>]*>\s*\d', entry)]
        check(
            f"{label}: четыре записи протокола с таймкодами",
            len(timed) == 4,
            f"с таймкодом: {len(timed)}",
        )
        if entries:
            first = entries[0]
            check(f"{label}: первая запись без заголовка", "<h2" not in first)
            check(
                f"{label}: первая запись — одна фраза",
                len(re.findall(r"<p[ >]", first)) == 2,
            )

    en_accent = re.search(r'<em class="self">(.*?)</em>', en_html, re.S)
    ru_accent = re.search(r'<em class="self">(.*?)</em>', ru_html, re.S)
    check(
        "EN: акцент в заголовке — Automatically",
        bool(en_accent) and "Automatically" in en_accent.group(1),
    )
    check(
        "RU: акцент в заголовке — «Автоматом»",
        bool(ru_accent) and "Автоматом" in ru_accent.group(1),
    )

    expected_en_shots = {
        "status-recording-light.png": "70c90f0201373d8ed3a5bb9fb89d2be109c69ed9112e2d1d72addb78a6f79687",
        "status-recording-dark.png": "ce72b49e27743bba25226e851ee57c7ee41b0ece37cafb0781e8da4ff8013172",
        "recordings-light.png": "9d2749fd675be63c53897b5327dd861a2aff03bdeb8c548781493af1d2f93b78",
        "recordings-dark.png": "af2d5e69c3133509a6ee3bc882fac29d3ba9a366ec4437a6c8f095a8d4ea29c3",
    }
    en_shot_urls = {url for _, url in en.resources if "/shots/" in url}
    check(
        "EN: страница использует отдельные английские скриншоты",
        en_shot_urls == {
            f"/assets/shots/en/{filename}" for filename in expected_en_shots
        },
        str(sorted(en_shot_urls)),
    )
    for filename, digest in expected_en_shots.items():
        shot = LANDING / "assets" / "shots" / "en" / filename
        check(f"EN: {filename} существует", shot.is_file())
        if shot.is_file():
            actual = hashlib.sha256(shot.read_bytes()).hexdigest()
            check(f"EN: {filename} — английский снимок", actual == digest, actual)

    ru_shot_urls = {url for _, url in ru.resources if "shots/" in url}
    check(
        "RU: страница сохранила русские скриншоты",
        len(ru_shot_urls) == 4 and all("/en/" not in url for url in ru_shot_urls),
        str(sorted(ru_shot_urls)),
    )

    # Shared CSS.
    css = (LANDING / "style.css").read_text(encoding="utf-8")
    check("CSS есть", bool(css.strip()))
    check("CSS уважает prefers-reduced-motion", "prefers-reduced-motion" in css)
    check(
        "CSS поддерживает тёмную тему",
        "prefers-color-scheme: dark" in css or "prefers-color-scheme:dark" in css,
    )
    check(
        "CSS не тянет внешние url()/@import",
        not re.search(r"url\(\s*['\"]?(https?:)?//|@import\s+['\"]?(https?:)?//", css),
    )

    # The same server-side language detection as samat.me: an independent `ru`
    # language tag anywhere in Accept-Language wins. Otherwise `/` serves English.
    nginx = NGINX.read_text(encoding="utf-8")
    for header in [
        "Strict-Transport-Security",
        "Content-Security-Policy",
        "X-Content-Type-Options",
        "Referrer-Policy",
        "Permissions-Policy",
    ]:
        check(f"nginx отдаёт {header}", f"add_header {header}" in nginx)
    language_map = re.search(
        r'map\s+\$http_accept_language\s+\$amanu_home_is_ru\s*\{(.*?)\}',
        nginx,
        re.S,
    )
    check("nginx выбирает язык по Accept-Language", bool(language_map))
    if language_map:
        rule = re.search(r'"~\*([^\"]+)"\s+1\s*;', language_map.group(1))
        check("nginx ищет ru как отдельный языковой тег", bool(rule))
        if rule:
            matcher = re.compile(rule.group(1), re.I)
            cases = {
                "ru-RU,ru;q=0.9,en;q=0.8": True,
                "en-US,en;q=0.9,ru;q=0.1": True,
                "fr-FR,fr;q=0.9": False,
                "en-RU,en;q=0.9": False,
                "": False,
            }
            for header, expected in cases.items():
                check(
                    f"Accept-Language {header or 'пустой'} → "
                    + ("RU" if expected else "EN"),
                    bool(matcher.search(header)) is expected,
                )
    root_location = re.search(
        r"location\s*=\s*/\s*\{(.*?)\n\s*\}\s*\n\s*location\s+/",
        nginx,
        re.S,
    )
    check(
        "русский браузер получает временный редирект на /ru/",
        bool(root_location)
        and "if ($amanu_home_is_ru)" in root_location.group(1)
        and "return 302 /ru/;" in root_location.group(1),
    )
    check(
        "без русского корень отдаёт английский index.html",
        bool(root_location) and "try_files /index.html =404;" in root_location.group(1),
    )
    explicit_english = re.search(r"location\s*=\s*/en/\s*\{(.*?)\}", nginx, re.S)
    check(
        "явный /en/ отдаёт английский без повторной детекции",
        bool(explicit_english) and "try_files /index.html =404;" in explicit_english.group(1),
    )

    robots = LANDING / "robots.txt"
    sitemap = LANDING / "sitemap.xml"
    check("robots.txt существует", robots.is_file())
    check("sitemap.xml существует", sitemap.is_file())
    if robots.is_file():
        check("robots.txt указывает sitemap", "https://amanu.me/sitemap.xml" in robots.read_text())
    if sitemap.is_file():
        sitemap_text = sitemap.read_text()
        for url in ["https://amanu.me/", "https://amanu.me/ru/", "https://amanu.me/privacy/", "https://amanu.me/ru/privacy/"]:
            check(f"sitemap содержит {url}", url in sitemap_text)

    return finish()


def finish():
    print()
    if failures:
        print(f"{len(failures)} провалено: " + "; ".join(failures))
        return 1
    print("все проверки прошли")
    return 0


if __name__ == "__main__":
    sys.exit(main())
