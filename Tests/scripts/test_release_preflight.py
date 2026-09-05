import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleasePreflightTests(unittest.TestCase):
    def test_a_clean_checkout_reports_a_missing_prerequisite_before_build_artifacts_exist(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            (checkout / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/release.sh", checkout / "scripts/release.sh")
            (checkout / "Makefile").write_text("VERSION ?= 0.4.15\n")
            subprocess.run(["git", "init", "--quiet", str(checkout)], check=True)
            subprocess.run([
                "git", "-C", str(checkout), "-c", "user.name=Audit fixture",
                "-c", "user.email=audit@example.invalid", "commit", "--quiet",
                "--allow-empty", "-m", "Fixture",
            ], check=True)
            # This copy deliberately has no signing configuration, so it must
            # stop before building, contacting a service, or modifying a tag.
            completed = subprocess.run(
                ["bash", str(checkout / "scripts/release.sh"), "--dry-run"],
                capture_output=True, text=True, check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertRegex(completed.stderr, r"no (Sparkle signing key|\.env\.asc)")
            self.assertFalse((checkout / ".build").exists())


if __name__ == "__main__":
    unittest.main()
