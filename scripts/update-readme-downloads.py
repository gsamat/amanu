#!/usr/bin/env python3
"""Synchronize README downloads with the highest public stable release per platform."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = 'gsamat/amanu'
VERSION_BLOCK = re.compile(
    r'(<!-- public-download-versions:start -->\n).*?(\n<!-- public-download-versions:end -->)',
    re.DOTALL,
)


def public_downloads(releases):
    downloads = {}
    for platform, prefix in (('macOS', 'v'), ('Windows', 'windows-v')):
        candidates = []
        for release in releases:
            match = re.fullmatch(re.escape(prefix) + r'(\d+)\.(\d+)\.(\d+)', release['tag_name'])
            if match and not release['draft'] and not release['prerelease']:
                candidates.append((tuple(map(int, match.groups())), release))
        if not candidates:
            raise ValueError(f'No public stable {platform} release found')
        _, release = max(candidates, key=lambda item: item[0])
        tag = release['tag_name']
        version = tag[len(prefix):]
        name = (f'amanu-{tag}-macos-universal.dmg' if platform == 'macOS'
                else f'Amanu-{version}-Setup.exe')
        assets = [asset for asset in release['assets'] if asset['name'] == name]
        expected = f'https://github.com/{REPO}/releases/download/{tag}/{name}'
        if (len(assets) != 1 or assets[0]['state'] != 'uploaded' or assets[0]['size'] <= 0
                or assets[0]['browser_download_url'] != expected):
            raise ValueError(f'{tag}: missing or invalid uploaded asset {name}')
        downloads[platform] = (version, expected)
    return downloads


def updated_readme(source, downloads):
    updated = source
    for platform, (_, url) in downloads.items():
        pattern = re.compile(r'\[Download for ' + re.escape(platform) + r'\]\([^\s)]+\)')
        updated, count = pattern.subn(f'[Download for {platform}]({url})', updated)
        if count != 1:
            raise ValueError(f'Expected exactly one {platform} README download link, found {count}')
    versions = (f'The current public downloads are macOS **{downloads["macOS"][0]}** '
                f'and Windows **{downloads["Windows"][0]}**.')
    if (updated.count('<!-- public-download-versions:start -->') != 1
            or updated.count('<!-- public-download-versions:end -->') != 1):
        raise ValueError('Expected exactly one public download versions block in README')
    updated, count = VERSION_BLOCK.subn(lambda match: match[1] + versions + match[2], updated)
    if count != 1:
        raise ValueError('Malformed public download versions block in README')
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--readme', type=Path, default=Path('README.md'))
    parser.add_argument('--releases-json', type=Path, help='Use an offline release API fixture')
    parser.add_argument('--verify-downloads', action='store_true', help='Check public assets with HTTP HEAD')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.releases_json:
        releases = json.loads(args.releases_json.read_text(encoding='utf-8'))
    else:
        # /releases/latest is shared by both platforms and can point at macOS
        # even when Windows has a higher version. Read all pages independently.
        response = subprocess.run(['gh', 'api', f'repos/{REPO}/releases?per_page=100',
                                   '--paginate', '--slurp'], check=True, capture_output=True, text=True)
        releases = [release for page in json.loads(response.stdout) for release in page]
    downloads = public_downloads(releases)
    source = args.readme.read_text(encoding='utf-8')
    updated = updated_readme(source, downloads)
    if args.check and source != updated:
        expected = '\n'.join(f'  {platform} {version}: {url}' for platform, (version, url) in downloads.items())
        raise ValueError('README downloads are stale. Expected:\n' + expected
                         + '\nRun python3 scripts/update-readme-downloads.py --write '
                         '--verify-downloads, then commit and push README.md.')
    if args.verify_downloads:
        for _, url in downloads.values():
            subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--head',
                            '--retry', '3', '--max-time', '120', url], check=True, stdout=subprocess.DEVNULL)
    if args.write and source != updated:
        args.readme.write_text(updated, encoding='utf-8')
    for platform, (version, url) in downloads.items():
        print(f'{platform} {version}: {url}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
