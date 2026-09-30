# Windows live transcription

Live transcription uses the Nemotron 3.5 streaming model locally, independently
of the engine selected for the final transcript. Download the live model in
Settings. It is about 750 MB; its checksum and URL are pinned in `ModelCatalog`.

Microphone and system audio each have a persistent CPU model and decoder in a
separate child process. A native decoder failure stops live recognition while
the main process continues writing both recording tracks. Each decoder uses up
to four threads (two per decoder on an eight-logical-processor host). Two loaded models require substantially more memory than the
single model file on disk.
Live decoder processes use Windows `AboveNormal` priority so ordinary background
work does not starve audio deadlines; their thread budget stays bounded. Batch
transcription uses `Idle` priority and is interrupted when live recognition starts.

WASAPI packets are continuously converted to 16 kHz mono and fed in 2.24-second
frames with the model's 13-frame right context. This amortizes CPU inference
while retaining partial updates. The live queue is
limited to five seconds per side. If recognition cannot keep up, live stops and
shows a message; it does not build an increasingly late transcript. Toggle Live
transcript off and on to restart it. Near-zero frames below -80 dBFS are skipped only
when no utterance is active. The original WAV tracks receive every packet.

Partial text replaces the current paragraph. Pauses close a paragraph; continuous
utterances are limited to sixty seconds of decoder context. Stop finishes the
current decoder call and short tail, with a five-second grace period before
cancellation. Final transcription starts after the live models have been freed.
If a previous recording is still being transcribed, live interrupts its batch
pass and reserves CPU until it stops. The batch pass then retries automatically;
this interruption does not consume a processing attempt or modify the recording.

`scripts/Build-LiveRuntime.ps1` builds the pinned transcribe.cpp 0.2.4 CPU DLLs
with static MSVC runtime libraries. It requires CMake and the MSVC C++ build
tools, as does the existing final-transcription runtime build. The beta build
and Windows workflow include both runtimes.
Both runtime builds disable build-host CPU targeting and include CPU variants
selected at runtime; the final CLI must also run on older supported processors.
The final CLI has a pinned patch that initializes these modules before ordinary
and batch model loads. `Test-NativeCpu.ps1` checks both device discovery and
ordinary startup during the build.

Windows validation:

```powershell
dotnet test tests/Amanu.Core.Tests/Amanu.Core.Tests.csproj -c Release
dotnet test tests/Amanu.Live.Tests/Amanu.Live.Tests.csproj -c Release
dotnet build tests/Amanu.Live.Harness/Amanu.Live.Harness.csproj
```

The harness accepts an application directory containing `Amanu.exe` and
`live-runtime`, a data directory containing the model, and two 16 kHz mono PCM16
WAV fixtures. It feeds both recordings at their original arrival rate and saves
text, processed-audio lag, errors, and stop time:

```powershell
dotnet run --project tests/Amanu.Live.Harness -- APP_DIR DATA_DIR mic.wav system.wav 510 result.json
```

To validate a signed package instead of the source build, build the harness with
`-p:CandidateDirectory=APP_DIR` and use that package's `Amanu.dll` and
`Amanu.Core.dll` in the harness output directory.

`--capture APP_DIR DATA_DIR playback.wav OUTPUT_DIR` instead exercises the real
WASAPI devices, durable WAV recording, pause, live off/on, and stop. Playback
uses the default speaker, and the microphone records the test environment.
GUI verification still requires exercising the actual Amanu window.
