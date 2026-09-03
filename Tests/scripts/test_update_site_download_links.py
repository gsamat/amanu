import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
UPDATER = ROOT / "scripts" / "update-site-download-links.py"


class UpdateSiteDownloadLinksTests(unittest.TestCase):
    def test_both_languages_point_directly_at_the_released_dmg(self) -> None:
        asset = (
            "https://github.com/gsamat/amanu/releases/download/v0.4.11/"
            "amanu-v0.4.11-macos-universal.dmg"
        )
        with tempfile.TemporaryDirectory() as temporary:
            site = Path(temporary)
            (site / "ru").mkdir(parents=True)
            (site / "index.html").write_text(
                '<a href="https://github.com/gsamat/amanu/releases/latest">one</a>\n'
                '<a href="https://github.com/gsamat/amanu/releases/latest">two</a>\n'
                '<a href="https://github.com/gsamat/amanu">source</a>\n',
                encoding="utf-8",
            )
            (site / "ru" / "index.html").write_text(
                '<a href="https://github.com/gsamat/amanu/releases/download/v0.4.10/'
                'amanu-v0.4.10-macos-universal.dmg">one</a>\n'
                '<a href="https://github.com/gsamat/amanu/releases/latest">two</a>\n',
                encoding="utf-8",
            )

            completed = subprocess.run(
                [sys.executable, str(UPDATER), str(site), asset],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            english = (site / "index.html").read_text(encoding="utf-8")
            russian = (site / "ru" / "index.html").read_text(encoding="utf-8")
            self.assertEqual(english.count(f'href="{asset}"'), 2)
            self.assertEqual(russian.count(f'href="{asset}"'), 2)
            self.assertNotIn("/releases/latest", english + russian)
            self.assertIn('href="https://github.com/gsamat/amanu"', english)


if __name__ == "__main__":
    unittest.main()
