# Contributing

Amanu is a Swift 6 package and a native macOS application assembled without an
Xcode project. Read [CLAUDE.md](CLAUDE.md) and
[Things that will bite](docs/pitfalls.md) before changing capture, permissions,
or packaging.

Keep changes focused, add a regression test before fixing a bug, and run:

```sh
swift test
python3 landing/tests/check.py
python3 -m unittest discover -s Tests/scripts -p 'test_*.py'
```

Never commit recordings, transcripts, calendar data, API keys, signing
credentials, or notarization credentials. By contributing, you agree that your
work is distributed under the repository's MIT license.
