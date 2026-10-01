# Contributing

Amanu has native macOS and Windows applications. macOS is a Swift 6 package
assembled without an Xcode project; Windows uses C#/.NET 10 and WPF with WASAPI
capture. Both editions keep meetings in ordinary folders and have separate
packaging and update feeds.

Read [CLAUDE.md](CLAUDE.md) and [Things that will bite](docs/pitfalls.md) before
changing macOS capture, permissions, or packaging. For Windows, follow
[windows/README.md](windows/README.md) to get the current release source and
build prerequisites, and use the [hardware checklist](https://github.com/gsamat/amanu/blob/windows-v0.6.2/windows/BETA.md) for
capture, device, lifecycle, and installer changes.

Keep changes focused and add a regression test before fixing a bug. On macOS:

```sh
swift test
python3 landing/tests/check.py
python3 -m unittest discover -s Tests/scripts -p 'test_*.py'
```

From the released Windows source's `windows` directory, on Windows:

```powershell
dotnet build Amanu.Windows.slnx -c Release
dotnet test tests\Amanu.Core.Tests\Amanu.Core.Tests.csproj -c Release
dotnet test tests\Amanu.Live.Tests\Amanu.Live.Tests.csproj -c Release
```

Use `scripts\Build-Release.ps1` for the native transcription runtimes and a
complete package. Verify changes to Windows UI and recording behavior in the
actual app on Windows. Mac-only checks do not validate Windows behavior.

Never commit recordings, transcripts, calendar data, API keys, signing
credentials, or notarization credentials. By contributing, you agree that your
work is distributed under the repository's MIT license.
