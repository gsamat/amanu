import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode")
class LocalSigningTests(unittest.TestCase):
    def signing_option(self, identity):
        completed = subprocess.run(
            ["make", "--no-print-directory", "--dry-run", "app", f"SIGN_ID={identity}"],
            cwd=ROOT, capture_output=True, text=True, check=True, timeout=60,
        )
        commands = completed.stdout.replace("\\\n", " ")
        options = re.findall(r"codesign --force --sign .*?\s--options\s+(\S+)", commands)
        self.assertTrue(options, "app recipe has no explicit signing options")
        self.assertEqual(len(set(options)), 1, "app and nested code use different signing modes")
        return options[0]

    def test_ad_hoc_build_can_load_its_bundled_native_library(self):
        option = self.signing_option("-")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            library_source = directory / "answer.c"
            main_source = directory / "main.c"
            library = directory / "libanswer.dylib"
            executable = directory / "main"
            library_source.write_text("int answer(void) { return 42; }\n")
            main_source.write_text("extern int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }\n")
            subprocess.run([
                "xcrun", "clang", "-dynamiclib", str(library_source),
                "-Wl,-install_name,@rpath/libanswer.dylib", "-o", str(library),
            ], capture_output=True, text=True, check=True)
            subprocess.run([
                "xcrun", "clang", str(main_source), "-L", str(directory), "-lanswer",
                "-Wl,-rpath,@executable_path", "-o", str(executable),
            ], capture_output=True, text=True, check=True)
            for code in (library, executable):
                subprocess.run([
                    "codesign", "--force", "--sign", "-", "--options", option,
                    "--timestamp=none", str(code),
                ], capture_output=True, text=True, check=True)
                subprocess.run([
                    "codesign", "--verify", "--strict", str(code),
                ], capture_output=True, text=True, check=True)
            completed = subprocess.run(
                [str(executable)], capture_output=True, text=True, check=False, timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_certificate_build_keeps_hardened_runtime(self):
        self.assertEqual(
            self.signing_option("Developer ID Application: Signing Test (TESTTEAM)"),
            "runtime",
        )


if __name__ == "__main__":
    unittest.main()
