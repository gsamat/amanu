#!/usr/bin/env python3
"""Point both amanu landing pages directly at one released disk image."""

import re
import sys
from pathlib import Path


DOWNLOAD = re.compile(
    r"https://github\.com/gsamat/amanu/releases/"
    r"(?:latest|download/v[^/\"\s]+/amanu-v[^/\"\s]+-macos-universal\.dmg)"
)


def update(page: Path, asset_url: str) -> None:
    source = page.read_text(encoding="utf-8")
    updated, count = DOWNLOAD.subn(asset_url, source)
    if count != 2:
        raise SystemExit(
            f"{page}: expected exactly 2 amanu download links, found {count}"
        )
    page.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: update-site-download-links.py SITE_ROOT ASSET_URL")
    site = Path(sys.argv[1])
    for relative in ("amanu/index.html", "amanu/ru/index.html"):
        update(site / relative, sys.argv[2])
