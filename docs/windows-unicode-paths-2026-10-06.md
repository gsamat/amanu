# Windows native transcription: Unicode paths (3699)

Validated on the available Windows host on 2026-10-06, from
`origin/codex/ready-0.6.3` at `d5cb1ff713243d4dbb8e5c5b4ceba2cc8bc83d6d`.
Changes are isolated in `codex/windows-unicode-paths`. The earlier silence fix
and the primary checkout were preserved.

## Reproduction before the fix

The installed signed `transcribe-cli.exe` has SHA256
`391e644eb664ec4967fbe966cfd9ad3e1a5f0cac3fd269f5234584761fe28b58`.
It uses transcribe.cpp 0.1.3, pinned commit
`a94e021ef658dc7c788837341a13f6acea3baf3c`.

The host's ANSI code page is 1252. A test directory named
`Сотрудник 模型 café 😀` reproduced the reported exception:

```text
[info] load_backend: loaded CPU backend ... ggml-cpu-haswell.dll
[info] transcribe_init_backends: ... CPU
[error] transcribe_model_load_file: caught backend exception:
No mapping for the Unicode character exists in the target multi-byte code page.
```

CPU discovery succeeded from the Unicode runtime directory. With ASCII WAV
and model paths, the one-byte model reached the expected `short read on file
magic` diagnostic. A Unicode model path instead caused the exception above;
a Unicode WAV path failed with `could not open WAV file`; a Unicode batch-list
path failed with `cannot open batch file`. The displayed narrow paths had
question marks/replacement characters. Four of six regression cases failed.

The accented character supplies an invalid UTF-8 ANSI byte on this CP1252
host; characters outside CP1252 are lost during narrow argv construction.
This reproduces both the exact exception and path corruption without changing
the computer's locale. It does not claim to have tested a CP1251 user account.

An isolated Debug Amanu instance also imported the public JFK fixture using
the unmodified runtime and showed the same `Локальная расшифровка не удалась:
(1)` / Unicode-mapping exception in recording management.

## Cause and patch

Windows `main(int, char**)` obtains narrow arguments in the ANSI code page.
The library's public path contract is UTF-8 and its Windows filesystem helper
uses `std::filesystem::u8path`. Passing those ANSI bytes violates that contract.
Backend discovery already uses wide Windows APIs and was functioning.

`windows/patches/transcribe-cli-unicode-paths.patch` makes three changes:

- Use `wmain` on Windows and convert all UTF-16 arguments to UTF-8 with
  `WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS)` before existing parsing.
  Keep narrow `main` on other platforms. MinGW receives the `-municode` entry
  option; MSVC recognizes `wmain` through its normal console startup.
- Open the batch-list filename as `std::filesystem::u8path`.
- Convert WAV filenames to a Windows filesystem path and use
  `drwav_init_file_w`; keep the original narrow WAV API off Windows.

The runtime build applies this patch after the existing backend bootstrap
patch. It then runs the new `windows/tests/Test-NativeUnicodePaths.ps1` in
addition to the CPU smoke test. No app transcription policy, model, language
pin, silence filter, or decoder setting changed.

## Windows checks after the fix

| Check | Result |
|---|---|
| Release managed solution build | Passed, 0 warnings / 0 errors |
| Debug Amanu build | Passed, 0 warnings / 0 errors |
| Core tests | 141 / 141 passed |
| Live tests | 38 / 38 passed |
| Patched CLI linked to unchanged installed DLLs | All 6 Unicode regression cases passed |
| Full `Build-LocalRuntime.ps1` build | Passed, all CPU variants and both smoke tests |
| Full rebuilt runtime, independent Unicode test | All 6 cases passed |
| Real model, single-file, all Unicode paths | Exit 0, 21.42 seconds |
| Real model, Unicode batch list and WAV | Exit 0, 28.72 seconds |
| Amanu UI retry of the failed recording | Completed and displayed the expected transcript |

Native tooling was portable LLVM/MinGW (Clang 23.1.2), CMake 4.4.4 and Ninja,
kept under the ignored `windows/.tools` directory. The full build used the
actual repository script with `CMAKE_GENERATOR=Ninja Multi-Config`, `CC=clang`,
`CXX=clang++`, `LDFLAGS=-static` and its normal `--parallel 2`. MSVC was not
installed, so an MSVC build and signed release packaging were not performed.
The native build reported three pre-existing unused-variable warnings in
upstream Voxtral, Voxtral Realtime and Canary Qwen sources. No warnings arose
from the changed CLI/WAV code.

The real fixture was pinned upstream `samples/jfk.wav`, 11 seconds, mono
PCM16 at 16 kHz. SHA256:
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
The previously downloaded Whisper large-v3-turbo Q8 model was copied into the
test directory and verified as
`b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183`.
Both real native modes returned:

```text
And so, my fellow Americans, ask not what your country can do for you,
ask what you can do for your country.
```

In the UI check, `AMANU_TEST_DATA` selected a new isolated data directory;
auto recording, live transcription, summaries, speaker naming, analytics and
startup registration were disabled for this test instance. Its application,
model, recording and temporary directories contained Cyrillic, CJK, spaces,
an accented character and emoji. Computer Use clicked `Доделать` on the
previously failed recording, observed `расшифровывается…`, then
`Whisper large-v3-turbo — готово` with the transcript rendered in the app.
The processing ledger ended with `last_error: null`; the deferred marker was
gone. Only the two test-instance PIDs (12036 before / 18728 after) were stopped.
The already running installed Amanu was left running.

## Evidence

Raw evidence is retained locally in the ignored
`windows/artifacts/unicode-3699/` directory of the worktree:

- `red-installed/`, `green-cli-only/`, `green-full-runtime/`: raw stdout,
  stderr and invocation/results JSON for the regression matrix.
- `native-build.log`, managed build logs, `core-test.log`, `live-test.log`,
  `tests/*.trx`: actual Windows build/test outcomes.
- `cli-only-real-*`, `full-runtime-real-*`: native single/batch output,
  arguments, PIDs, exit codes and measured wall times.
- `ui-red-transcribe.log`, `ui-final-transcript.*`,
  `ui-final-processing.json`, `ui-verification.json`: UI reproduction and
  successful production-flow retry.
- `runtime-hashes.json`, `real-input-hashes.json` and tool-source metadata.

Full rebuilt CLI SHA256:
`bb632dc5c26b24831eac025fbc34e4e6e54b9610d335f598187b5c5960b25080`.
The installed CLI hash remained unchanged. No installed application, user
settings, recording or model was overwritten. No release was published and
no Telegram message was sent.
