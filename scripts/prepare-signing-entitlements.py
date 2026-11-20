#!/usr/bin/env python3
"""Keep certificate signing unchanged and let ad-hoc builds load their frameworks."""

import argparse
import plistlib
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ad-hoc", action="store_true")
    args = parser.parse_args()
    entitlements = plistlib.loads(args.source.read_bytes())
    if args.ad_hoc:
        # Ad-hoc code has no Team ID, so hardened library validation cannot
        # establish a common team with its bundled non-platform frameworks.
        entitlements["com.apple.security.cs.disable-library-validation"] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(entitlements))


if __name__ == "__main__":
    main()
