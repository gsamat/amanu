import plistlib
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APPCAST = ROOT / "landing" / "appcast.xml"
INFO_PLIST = ROOT / "Packaging" / "Amanu-Info.plist"
FEED_URL = "https://amanu.me/appcast.xml"


class UpdateFeedLocationTests(unittest.TestCase):
    def test_canonical_appcast_lives_at_the_amanu_site_root(self) -> None:
        channel = ET.parse(APPCAST).getroot().find("channel")

        self.assertIsNotNone(channel)
        self.assertEqual(channel.findtext("link"), FEED_URL)

    def test_new_builds_check_the_canonical_feed(self) -> None:
        with INFO_PLIST.open("rb") as source:
            bundle_info = plistlib.load(source)

        self.assertEqual(bundle_info.get("SUFeedURL"), FEED_URL)


if __name__ == "__main__":
    unittest.main()
