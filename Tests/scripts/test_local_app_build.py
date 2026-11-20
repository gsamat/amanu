import os
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LocalAppBuildTests(unittest.TestCase):
    def dry_run(self, target):
        with tempfile.TemporaryDirectory() as temporary:
            tools = Path(temporary)
            swift = tools / "swift"
            swift.write_text("#!/bin/sh\necho /tmp/amanu-test-build\n")
            swift.chmod(0o755)
            result = subprocess.run(
                ["make", "-n", target], cwd=ROOT,
                env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_app_keeps_the_universal_default(self):
        output = self.dry_run("app")
        self.assertIn("swift build -c release --arch arm64 --arch x86_64", output)
        self.assertIn("for arch in arm64 x86_64", output)

    def test_local_app_builds_and_checks_the_host_architecture(self):
        output = self.dry_run("local-app")
        architecture = platform.machine()
        self.assertIn(f"swift build -c release --arch {architecture}\n", output)
        self.assertIn(f"for arch in {architecture};", output)

    def test_default_all_still_builds_a_universal_app(self):
        output = self.dry_run("all")
        self.assertIn("swift build -c release --arch arm64 --arch x86_64", output)


if __name__ == "__main__":
    unittest.main()
