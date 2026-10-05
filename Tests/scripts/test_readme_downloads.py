import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/update-readme-downloads.py'
MAC = 'https://github.com/gsamat/amanu/releases/download/v0.6.4/amanu-v0.6.4-macos-universal.dmg'
WIN = 'https://github.com/gsamat/amanu/releases/download/windows-v0.6.5/Amanu-0.6.5-Setup.exe'


def release(tag, name, **extra):
    return dict(tag_name=tag, draft=False, prerelease=False, assets=[dict(
        name=name, state='uploaded', size=123,
        browser_download_url=f'https://github.com/gsamat/amanu/releases/download/{tag}/{name}'
    )], **extra)


class ReadmeDownloadsTests(unittest.TestCase):
    def run_script(self, readme, releases, *args):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            page = directory / 'README.md'
            page.write_text(readme)
            data = directory / 'releases.json'
            data.write_text(json.dumps(releases))
            result = subprocess.run([sys.executable, str(SCRIPT), '--readme', str(page),
                                     '--releases-json', str(data), *args], capture_output=True, text=True)
            return result, page.read_text()

    def fixture(self):
        return [release('v0.6.4', 'amanu-v0.6.4-macos-universal.dmg'),
                release('windows-v0.6.5', 'Amanu-0.6.5-Setup.exe')]

    def readme(self):
        return ('# Custom intro\n'
                '[Download for macOS](https://example.invalid/old.dmg) ·\n'
                '[Download for Windows](https://example.invalid/old.exe)\n'
                '<!-- public-download-versions:start -->\nold versions\n'
                '<!-- public-download-versions:end -->\nUnrelated 0.6.4 documentation.\n')

    def test_write_updates_both_platforms_and_versions_without_changing_other_prose(self):
        result, text = self.run_script(self.readme(), self.fixture(), '--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'[Download for macOS]({MAC})', text)
        self.assertIn(f'[Download for Windows]({WIN})', text)
        self.assertIn('macOS **0.6.4** and Windows **0.6.5**', text)
        self.assertTrue(text.startswith('# Custom intro\n'))
        self.assertTrue(text.endswith('Unrelated 0.6.4 documentation.\n'))
        checked, unchanged = self.run_script(text, self.fixture(), '--check')
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(unchanged, text)

    def test_check_fails_on_stale_readme_without_writing_it(self):
        result, text = self.run_script(self.readme(), self.fixture(), '--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stale', result.stderr)
        self.assertEqual(text, self.readme())

    def test_selects_highest_numeric_version_not_api_order_or_github_latest(self):
        releases = self.fixture() + [release('windows-v0.6.10', 'Amanu-0.6.10-Setup.exe'),
                                    release('windows-v0.6.2', 'Amanu-0.6.2-Setup.exe')]
        result, text = self.run_script(self.readme(), releases, '--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('windows-v0.6.10/Amanu-0.6.10-Setup.exe', text)

    def test_drafts_prereleases_and_unrelated_tags_do_not_replace_public_downloads(self):
        draft = release('v9.0.0', 'amanu-v9.0.0-macos-universal.dmg')
        draft['draft'] = True
        beta = release('windows-v9.0.0', 'Amanu-9.0.0-Setup.exe')
        beta['prerelease'] = True
        result, text = self.run_script(self.readme(), self.fixture() + [draft, beta,
                                  release('nightly', 'Amanu-nightly-Setup.exe')], '--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(WIN, text)
        self.assertIn(MAC, text)

    def test_missing_newest_installer_fails_instead_of_falling_back(self):
        broken = release('windows-v0.6.6', 'SHA256SUMS')
        result, text = self.run_script(self.readme(), self.fixture() + [broken], '--write')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Amanu-0.6.6-Setup.exe', result.stderr)
        self.assertEqual(text, self.readme())

    def test_wrong_url_empty_asset_or_missing_platform_cannot_be_published(self):
        for mutation in ('url', 'size', 'state', 'platform'):
            releases = self.fixture()
            if mutation == 'platform':
                releases.pop()
            else:
                asset = releases[1]['assets'][0]
                asset[{'url': 'browser_download_url', 'size': 'size', 'state': 'state'}[mutation]] = {
                    'url': MAC, 'size': 0, 'state': 'new'}[mutation]
            with self.subTest(mutation=mutation):
                result, text = self.run_script(self.readme(), releases, '--write')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(text, self.readme())

    def test_missing_or_duplicate_link_or_version_block_fails_before_writing(self):
        for text in (self.readme().replace('Download for Windows', 'Missing'),
                     self.readme() + '[Download for Windows](https://example.invalid/extra.exe)',
                     self.readme().replace('public-download-versions:end', 'missing:end')):
            with self.subTest(text=text):
                result, unchanged = self.run_script(text, self.fixture(), '--write')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(unchanged, text)


if __name__ == '__main__':
    unittest.main()
