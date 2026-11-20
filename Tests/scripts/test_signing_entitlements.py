import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "prepare-signing-entitlements.py"
LIBRARY_VALIDATION = "com.apple.security.cs.disable-library-validation"


class SigningEntitlementsTests(unittest.TestCase):
    def prepare(self, values, *flags):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.plist"
            output = Path(temporary) / "output.plist"
            original = plistlib.dumps(values)
            source.write_bytes(original)
            result = subprocess.run(
                ["python3", str(SCRIPT), str(source), str(output), *flags],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(source.read_bytes(), original)
            return plistlib.loads(output.read_bytes())

    def test_certificate_signing_preserves_the_entitlements(self):
        values = {"com.apple.security.device.audio-input": True}
        self.assertEqual(self.prepare(values), values)

    def test_ad_hoc_signing_can_load_bundled_non_platform_frameworks(self):
        values = {"com.apple.security.device.audio-input": True,
                  "com.apple.security.personal-information.calendars": True}
        self.assertEqual(self.prepare(values, "--ad-hoc"), {**values, LIBRARY_VALIDATION: True})

    def test_an_existing_false_value_is_changed_only_for_ad_hoc_signing(self):
        values = {LIBRARY_VALIDATION: False}
        self.assertEqual(self.prepare(values), values)
        self.assertEqual(self.prepare(values, "--ad-hoc"), {LIBRARY_VALIDATION: True})


if __name__ == "__main__":
    unittest.main()
