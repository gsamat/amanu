#!/usr/bin/env bash
# Build the pinned arm64 NeMo diarization CLI for macOS 14.2. The model is an
# optional user download; this target deliberately builds no model cache.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/nemotron"
SOURCE_REV=8642eaa5cc51efbc17ad0f3e433944ba858a873f
LLAMA_REV=bd4f514db14d87fded667787a7a963bfbaa98e89
SENTENCEPIECE_REV=31646a467d2051eb904e0b45de3a73e91fe1c1e3
MINIMUM_MACOS=${AMANU_MINIMUM_MACOS:-14.2}
JOBS=${AMANU_NEMOTRON_JOBS:-4}
CMAKE=${AMANU_CMAKE:-$(command -v cmake || true)}

[ "$MINIMUM_MACOS" = 14.2 ] || { echo "Nemotron helper requires macOS deployment target 14.2" >&2; exit 1; }
[ -n "$CMAKE" ] && [ -x "$CMAKE" ] || { echo "cmake is required" >&2; exit 1; }
case "$JOBS" in ''|*[!0-9]*) echo "AMANU_NEMOTRON_JOBS must be a positive integer" >&2; exit 1;; esac
[ "$JOBS" -ge 1 ] && [ "$JOBS" -le 8 ] || { echo "AMANU_NEMOTRON_JOBS must be 1..8" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Nemotron helper must be built on arm64 macOS" >&2; exit 1; }
for tool in git lipo otool vtool shasum python3; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

mkdir -p "$OUT"
SOURCE=${AMANU_NEMOTRON_SOURCE:-$OUT/source}
if [ ! -d "$SOURCE/.git" ]; then
    [ -z "${AMANU_NEMOTRON_SOURCE:-}" ] || { echo "AMANU_NEMOTRON_SOURCE is not a checkout" >&2; exit 1; }
    git init "$SOURCE"
    git -C "$SOURCE" remote add origin https://github.com/NVIDIA/NeMo-Speech.cpp.git
    git -C "$SOURCE" fetch --depth 1 origin "$SOURCE_REV"
    # This build excludes Mandarin TTS; its Git LFS data is not needed.
    git -C "$SOURCE" -c filter.lfs.process= -c filter.lfs.smudge= \
        -c filter.lfs.required=false checkout --detach "$SOURCE_REV"
fi
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REV" ] \
    || { echo "NeMo source revision mismatch" >&2; exit 1; }
if [ ! -f "$SOURCE/llama.cpp/ggml/CMakeLists.txt" ]; then
    [ -z "${AMANU_NEMOTRON_SOURCE:-}" ] || { echo "pinned llama.cpp submodule is missing" >&2; exit 1; }
    git -C "$SOURCE" submodule update --init --depth 1 llama.cpp
fi
[ "$(git -C "$SOURCE/llama.cpp" rev-parse HEAD)" = "$LLAMA_REV" ] \
    || { echo "llama.cpp submodule revision mismatch" >&2; exit 1; }
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] \
    || { echo "NeMo source has local edits" >&2; exit 1; }

SENTENCEPIECE=${AMANU_NEMOTRON_SENTENCEPIECE_SOURCE:-$OUT/sentencepiece-source}
if [ ! -d "$SENTENCEPIECE/.git" ]; then
    [ -z "${AMANU_NEMOTRON_SENTENCEPIECE_SOURCE:-}" ] \
        || { echo "AMANU_NEMOTRON_SENTENCEPIECE_SOURCE is not a checkout" >&2; exit 1; }
    git init "$SENTENCEPIECE"
    git -C "$SENTENCEPIECE" remote add origin https://github.com/google/sentencepiece.git
    git -C "$SENTENCEPIECE" fetch --depth 1 origin "$SENTENCEPIECE_REV"
    git -C "$SENTENCEPIECE" checkout --detach "$SENTENCEPIECE_REV"
fi
[ "$(git -C "$SENTENCEPIECE" rev-parse HEAD)" = "$SENTENCEPIECE_REV" ] \
    || { echo "SentencePiece revision mismatch" >&2; exit 1; }
[ -z "$(git -C "$SENTENCEPIECE" status --porcelain --untracked-files=no)" ] \
    || { echo "SentencePiece source has local edits" >&2; exit 1; }

SP_BUILD="$OUT/sentencepiece-build"
SP_PREFIX="$OUT/deps/sentencepiece"
# An explicit pinned source checkout can seed a local debug build. A later
# ordinary `make app` uses the build's own checkout, so discard only the stale
# CMake cache for that build rather than asking CMake to reuse another source.
reset_if_source_changed() {
    local build="$1" source="$2" cached
    [ -f "$build/CMakeCache.txt" ] || return 0
    cached=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$build/CMakeCache.txt")
    if [ "$cached" != "$(cd "$source" && pwd -P)" ]; then
        rm -rf "$build"
    fi
}
reset_if_source_changed "$SP_BUILD" "$SENTENCEPIECE"
"$CMAKE" -G 'Unix Makefiles' -S "$SENTENCEPIECE" -B "$SP_BUILD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 -DSPM_BUILD_TEST=OFF \
    -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF
"$CMAKE" --build "$SP_BUILD" --target sentencepiece-static -j "$JOBS"
install -d "$SP_PREFIX/lib" "$SP_PREFIX/include"
install -m 0644 "$SP_BUILD/src/libsentencepiece.a" "$SP_PREFIX/lib/libsentencepiece.a"
install -m 0644 "$SENTENCEPIECE/src/sentencepiece_processor.h" \
    "$SP_PREFIX/include/sentencepiece_processor.h"
SP_LICENSES="$SP_PREFIX/share/licenses/nemo-speech/third_party/sentencepiece"
install -d "$SP_LICENSES"
install -m 0644 "$SENTENCEPIECE/LICENSE" "$SP_LICENSES/LICENSE"
install -m 0644 "$SENTENCEPIECE/third_party/absl/LICENSE" "$SP_LICENSES/absl-LICENSE"
install -m 0644 "$SENTENCEPIECE/third_party/darts_clone/LICENSE" "$SP_LICENSES/darts-clone-LICENSE"
install -m 0644 "$SENTENCEPIECE/third_party/protobuf-lite/LICENSE" "$SP_LICENSES/protobuf-lite-LICENSE"

BUILD="$OUT/build"
reset_if_source_changed "$BUILD" "$SOURCE"
"$SOURCE/scripts/configure.sh" metal-diar -G 'Unix Makefiles' -B "$BUILD" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 \
    -DGGML_METAL_MACOSX_VERSION_MIN=14.2 -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DNEMO_SPEECH_DEPENDENCY_PREFIX="$OUT/deps"
"$CMAKE" --build "$BUILD" -j "$JOBS"
"$CMAKE" --install "$BUILD" --prefix "$OUT/stage"

install -d "$OUT/bin" "$OUT/lib" "$OUT/licenses"
install -m 0755 "$OUT/stage/bin/nemo-speech" "$OUT/bin/nemo-speech"
for library in \
    libnemo_speech_asr.dylib \
    libggml.0.25.1.dylib libggml-base.0.25.1.dylib \
    libggml-blas.0.25.1.dylib libggml-cpu.0.25.1.dylib \
    libggml-metal.0.25.1.dylib; do
    install -m 0755 "$OUT/stage/lib/$library" "$OUT/lib/$library"
done
for library in ggml ggml-base ggml-blas ggml-cpu ggml-metal; do
    ln -sfn "$(readlink "$OUT/stage/lib/lib$library.0.dylib")" "$OUT/lib/lib$library.0.dylib"
done
cp -R "$OUT/stage/share/licenses/nemo-speech/." "$OUT/licenses/"

python3 "$ROOT/scripts/verify-nemotron-diar.py" "$OUT" \
    --build "$BUILD" --sentencepiece-build "$SP_BUILD" --minimum 14.2
python3 - "$OUT" "$SOURCE_REV" "$LLAMA_REV" "$SENTENCEPIECE_REV" <<'PY'
import hashlib, json, pathlib, sys
root, source, llama, sentencepiece = pathlib.Path(sys.argv[1]), *sys.argv[2:]
artifacts = [root / 'bin/nemo-speech', *sorted((root / 'lib').glob('*.dylib'))]
payload = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in artifacts if not p.is_symlink()}
(root / 'verification.json').write_text(json.dumps({
    'source_revision': source,
    'llama_revision': llama,
    'sentencepiece_revision': sentencepiece,
    'minimum_macos': '14.2', 'architectures': ['arm64'],
    'embedded_metal': True, 'ggml_native': False,
    'unsigned_payload_sha256': payload,
}, indent=2, sort_keys=True) + '\n')
PY
echo "Nemotron helper ready → $OUT/bin/nemo-speech"
