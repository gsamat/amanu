#!/usr/bin/env python3
"""Automated checks for the amanu landing page.

Observable structure and behaviour only: the page exists, is Russian,
links to the real release, keeps every resource local, stays honest about
the Windows form, and respects reduced motion and both colour schemes.
No checks on exact wording.
"""

import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

LANDING = Path(__file__).resolve().parent.parent
INDEX = LANDING / "index.html"

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
        self.links = []            # <a href>
        self.resources = []        # (tag, url) for img/src, srcset, link href, script src, source srcset
        self.imgs = []             # dicts of attrs
        self.forms = []            # action attrs
        self.script_srcs = []
        self.inline_scripts = []
        self._in_script = False
        self.onclick_count = 0
        self.positive_tabindex = 0
        self.stylesheets = []

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
        elif tag == "meta" and a.get("name") == "description":
            self.meta_description = a.get("content")
        elif tag == "a":
            self.links.append(a.get("href", ""))
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
            self.resources.append(("link", href))
            if "stylesheet" in a.get("rel", ""):
                self.stylesheets.append(href)
        elif tag == "script":
            self._in_script = True
            if a.get("src"):
                self.script_srcs.append(a["src"])
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


def is_external(url):
    s = urlsplit(url)
    return s.scheme in ("http", "https") or url.startswith("//")


def resolves_locally(url):
    s = urlsplit(url)
    if s.scheme or url.startswith("//"):
        return False
    path = unquote(s.path)
    if not path:
        return True  # pure fragment
    return (LANDING / path).is_file()


def main():
    check("index.html существует", INDEX.is_file())
    if not INDEX.is_file():
        return finish()

    html = INDEX.read_text(encoding="utf-8")
    p = PageParser()
    p.feed(html)

    # Language and document basics
    check("lang=ru на <html>", p.html_lang == "ru", f"lang={p.html_lang!r}")
    check("ровно один <h1>", p.h1_count == 1, f"h1×{p.h1_count}")
    check("<title> непустой", bool(p.title.strip()))
    check("meta description непустой", bool(p.meta_description and p.meta_description.strip()))

    # Requested public wording and attribution.
    readable_html = html.replace("&nbsp;", " ")
    check(
        "бинарник назван нотаризованным Apple",
        readable_html.count("нотаризован Apple") == 2
        and "подписанный бинарник" not in readable_html,
    )
    check(
        "заголовок про локальные данные без точки",
        "<h2>Все данные хранятся у вас локально</h2>" in readable_html,
    )
    check(
        "в футере Самат Галимов со ссылкой на samat.me/ru",
        bool(re.search(
            r'<footer>.*<a href="https://samat\.me/ru">Самат Галимов</a>.*</footer>',
            html,
            re.S,
        ))
        and 'mailto:s@samat.me' not in html,
    )
    check(
        "подпись к статусу без «уже»",
        "<figcaption>Встреча идёт — Amanu пишет.</figcaption>" in html
        and "Amanu уже пишет" not in html,
    )

    # Verified outbound facts. The download goes straight to the published DMG:
    # the asset name carries the version, so /releases/latest/download cannot
    # be built reliably.
    DMG = ("https://github.com/gsamat/amanu/releases/download/"
           "v0.4.10/amanu-v0.4.10-macos-universal.dmg")
    check("обе кнопки ведут прямо на DMG", p.links.count(DMG) == 2,
          f"ссылок на DMG: {p.links.count(DMG)}")
    check(
        "ни одна ссылка не осталась на releases/latest",
        not any("releases/latest" in h for h in p.links),
        str([h for h in p.links if "releases/latest" in h]),
    )
    check(
        "ссылка на исходный код",
        any(re.search(r"github\.com/gsamat/amanu/?$", h) for h in p.links),
    )

    # Honest Windows-interest block: a mailto that opens a ready letter to the
    # address collecting the interest, and no form pretending to submit anywhere.
    windows_mailto = [h for h in p.links if h.startswith("mailto:amanu-windows@samat.me")]
    check("mailto для Windows-интереса на amanu-windows@samat.me", bool(windows_mailto))
    if windows_mailto:
        q = parse_qs(urlsplit(windows_mailto[0]).query)
        body = (q.get("body") or [""])[0]
        check(
            "в письме про Windows готовое тело",
            body.strip() == "Сообщите мне, когда появится windows версия, пожалуйста!",
            f"body={body!r}",
        )
    check(
        "нет формы с сетевым action",
        all(not a or a.startswith("mailto:") for a in p.forms),
        f"forms={p.forms}",
    )

    # Self-contained: no external scripts, no external resources at all.
    check("нет внешних <script src>", not p.script_srcs, str(p.script_srcs))
    check(
        "нет внешних ресурсов (img/link/source)",
        all(not is_external(u) for _, u in p.resources),
        str([u for _, u in p.resources if is_external(u)]),
    )
    check(
        "все локальные ресурсы существуют",
        all(resolves_locally(u) for _, u in p.resources),
        str([u for _, u in p.resources if not resolves_locally(u)]),
    )
    scripts = "\n".join(p.inline_scripts)
    check(
        "инлайн-скрипты не ходят на чужие домены",
        not re.search(r"fetch\(|XMLHttpRequest|https?://", scripts),
    )
    check(
        "просмотр считается через first-party /m",
        bool(re.search(r"new URL\(['\"]\/m['\"],\s*location\.origin\)", scripts))
        and "location.pathname" in scripts
        and "document.title" in scripts
        and "screen.width" in scripts
        and "document.referrer" in scripts
        and "new Image().src" in scripts,
    )

    # Accessibility basics
    check("у всех <img> есть alt", all("alt" in a for a in p.imgs))
    check(
        "у всех <img> есть width и height",
        all("width" in a and "height" in a for a in p.imgs),
    )
    check("нет inline-обработчиков on*", p.onclick_count == 0)
    check("нет tabindex > 0", p.positive_tabindex == 0)

    # CSS: gather inline <style> and local stylesheets
    css = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", html, re.S))
    for href in p.stylesheets:
        f = LANDING / unquote(urlsplit(href).path)
        if f.is_file():
            css += "\n" + f.read_text(encoding="utf-8")
    check("CSS есть", bool(css.strip()))
    check("CSS уважает prefers-reduced-motion", "prefers-reduced-motion" in css)
    check("CSS поддерживает тёмную тему", "prefers-color-scheme: dark" in css or "prefers-color-scheme:dark" in css)
    check(
        "CSS не тянет внешние url()/@import",
        not re.search(r"url\(\s*['\"]?(https?:)?//|@import\s+['\"]?(https?:)?//", css),
    )

    # Local ru screenshots are actually used (both colour schemes)
    check(
        "скриншоты в обеих темах",
        any("dark" in u for _, u in p.resources) and any("light" in u for _, u in p.resources),
    )

    # The first entry is one statement, not a heading with a subtitle under it.
    entries = re.findall(r'<section class="entry[^"]*">(.*?)</section>', html, re.S)
    timed = [e for e in entries if re.search(r'<p class="tc"[^>]*>\s*\d', e)]
    check("четыре записи протокола с таймкодами", len(timed) == 4, f"с таймкодом: {len(timed)}")
    if entries:
        first = entries[0]
        check("первая запись без заголовка", "<h2" not in first)
        check("первая запись — одна фраза", len(re.findall(r"<p[ >]", first)) == 2, first[:120])

    # The hero accent word the brief asks for.
    accent = re.search(r'<em class="self">(.*?)</em>', html, re.S)
    check(
        "акцент в заголовке — «Автоматом»",
        bool(accent) and "Автоматом" in accent.group(1),
        accent.group(1) if accent else "нет em.self",
    )

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
