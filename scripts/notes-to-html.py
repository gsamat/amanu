#!/usr/bin/env python3
"""Turn the release notes into the HTML Sparkle shows in its update window.

Deliberately not a Markdown implementation. It understands the four things the
notes actually use — headings, bullets, paragraphs and inline code — and the
release script fails loudly rather than quietly mangling anything it meets
that it does not know, because a release is the wrong moment to discover that
a table came out as literal pipes in front of every user.
"""

import html
import re
import sys


def inline(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', escaped)


def convert(source: str) -> str:
    out: list[str] = []
    in_list = False
    paragraph: list[str] = []

    def flush_paragraph() -> None:
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in source.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_paragraph()
            close_list()
        elif line.startswith("#"):
            flush_paragraph()
            close_list()
            level = len(line) - len(line.lstrip("#"))
            # h1 belongs to the page, not to a section of release notes.
            tag = f"h{min(level + 1, 4)}"
            out.append(f"<{tag}>{inline(line.lstrip('#').strip())}</{tag}>")
        elif line.startswith(("- ", "* ")):
            flush_paragraph()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:].strip())}</li>")
        elif line.startswith("    ") or line.startswith("\t") or line.startswith("```"):
            raise SystemExit(
                f"notes-to-html: code blocks are not supported, and this line "
                f"would have been shown as prose: {line!r}"
            )
        else:
            if in_list:
                # A continuation line under a bullet, indented away by rstrip.
                out[-1] = out[-1][: -len("</li>")] + " " + inline(line.strip()) + "</li>"
            else:
                paragraph.append(line.strip())

    flush_paragraph()
    close_list()
    return "\n".join(out)


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(convert(handle.read()))
