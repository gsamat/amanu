import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "Resources" / "Amanu.icon"
CLASSIC_ICON = ROOT / "Resources" / "Amanu.icns"
BUILD_SCRIPT = ROOT / "scripts" / "build-app-icon.sh"


def xcode_major_version():
    result = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        return None
    first = result.stdout.splitlines()[0].split()
    return int(first[1].split(".")[0]) if len(first) > 1 else None


@unittest.skipUnless(
    (xcode_major_version() or 0) >= 26,
    "Icon Composer assets require Xcode 26 or later",
)
class AppIconTests(unittest.TestCase):
    def test_icon_composer_asset_builds_all_macos_appearances(self):
        self.assertTrue(
            (ICON / "icon.json").is_file(),
            "Resources/Amanu.icon/icon.json is missing",
        )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            partial_plist = output / "partial.plist"
            result = subprocess.run(
                [
                    "xcrun",
                    "actool",
                    "--compile",
                    str(output),
                    "--platform",
                    "macosx",
                    "--minimum-deployment-target",
                    "14.2",
                    "--app-icon",
                    "Amanu",
                    "--output-partial-info-plist",
                    str(partial_plist),
                    str(ICON),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((output / "Assets.car").is_file())
            self.assertTrue((output / "Amanu.icns").is_file())

            with partial_plist.open("rb") as file:
                generated_info = plistlib.load(file)
            self.assertEqual(generated_info["CFBundleIconName"], "Amanu")
            self.assertEqual(generated_info["CFBundleIconFile"], "Amanu")

            catalog = subprocess.run(
                ["assetutil", "--info", str(output / "Assets.car")],
                capture_output=True,
                text=True,
                check=True,
            )
            renditions = json.loads(catalog.stdout)
            stacks = {
                item.get("Appearance"): item
                for item in renditions
                if item.get("AssetType") == "IconImageStack"
                and item.get("Name") == "Amanu"
            }
            self.assertEqual(
                set(stacks),
                {
                    "NSAppearanceNameAqua",
                    "NSAppearanceNameDarkAqua",
                    "ISAppearanceTintable",
                },
            )
            for appearance, stack in stacks.items():
                self.assertGreaterEqual(
                    stack["LayerCount"],
                    2,
                    f"{appearance} lost the feather foreground layer",
                )

            groups = {
                item.get("Appearance"): item
                for item in renditions
                if item.get("AssetType") == "IconGroup"
                and item.get("Name") == "Amanu/Group"
            }
            self.assertEqual(set(groups), set(stacks))
            for appearance, group in groups.items():
                layer = group["Layers"][0]
                self.assertEqual(
                    layer["AssetType"],
                    "Image",
                    f"{appearance} must preserve the hollow raster outline",
                )
                self.assertFalse(layer["Opaque"])
                width, height = map(int, layer["LayerSize"].split(","))
                self.assertGreaterEqual(width, 1200)
                self.assertGreaterEqual(height, 1200)

    def test_app_icon_build_keeps_the_classic_fallback(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), "scripts/build-app-icon.sh is missing")

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = subprocess.run(
                [
                    str(BUILD_SCRIPT),
                    str(ICON),
                    str(CLASSIC_ICON),
                    str(output),
                    "14.2",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((output / "Assets.car").is_file())
            self.assertEqual(
                (output / "Amanu.icns").read_bytes(),
                CLASSIC_ICON.read_bytes(),
            )


class PrebuiltAppIconTests(unittest.TestCase):
    def run_prebuilt(self, directory, *, matching=True, catalog=True):
        root = Path(directory)
        prebuilt = root / "prebuilt resources"
        prebuilt.mkdir()
        (prebuilt / "Amanu.icns").write_bytes(
            CLASSIC_ICON.read_bytes() if matching else b"a different icon"
        )
        if catalog:
            (prebuilt / "Assets.car").write_bytes(b"precompiled catalog")
        tools = root / "tools"
        tools.mkdir()
        xcrun = tools / "xcrun"
        xcrun.write_text("#!/bin/sh\necho 'actool must not run' >&2\nexit 99\n")
        xcrun.chmod(0o755)
        output = root / "output"
        result = subprocess.run(
            [str(BUILD_SCRIPT), str(ICON), str(CLASSIC_ICON), str(output), "14.2"],
            env={**os.environ, "PATH": str(tools) + ":/usr/bin:/bin",
                 "AMANU_PREBUILT_ICON_RESOURCES": str(prebuilt)},
            capture_output=True, text=True, check=False,
        )
        return result, output

    def test_explicit_prebuilt_resources_do_not_need_actool(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_prebuilt(directory)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((output / "Assets.car").read_bytes(), b"precompiled catalog")
            self.assertEqual((output / "Amanu.icns").read_bytes(), CLASSIC_ICON.read_bytes())

    def test_prebuilt_resources_must_match_the_current_classic_icon(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_prebuilt(directory, matching=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("precompiled", result.stderr)
            self.assertFalse((output / "Assets.car").exists())

    def test_prebuilt_resources_must_include_a_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_prebuilt(directory, catalog=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("precompiled", result.stderr)
            self.assertFalse((output / "Amanu.icns").exists())


if __name__ == "__main__":
    unittest.main()
