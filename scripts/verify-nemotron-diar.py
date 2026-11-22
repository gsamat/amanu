#!/usr/bin/env python3
"""Check the exact bundled NeMo CLI closure without loading a model or audio."""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REQUIRED = {
    "libnemo_speech_asr.dylib",
    "libggml.0.25.1.dylib", "libggml-base.0.25.1.dylib",
    "libggml-blas.0.25.1.dylib", "libggml-cpu.0.25.1.dylib",
    "libggml-metal.0.25.1.dylib",
}
LICENSES = {
    "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md",
    "third_party/ggml/LICENSE", "third_party/sentencepiece/LICENSE",
    "third_party/sentencepiece/absl-LICENSE",
    "third_party/sentencepiece/darts-clone-LICENSE",
    "third_party/sentencepiece/protobuf-lite-LICENSE",
}


def command(*argv: str) -> str:
    result = subprocess.run(argv, check=True, capture_output=True, text=True)
    return result.stdout


def mach_o(path: Path, minimum: str) -> None:
    if command("lipo", "-archs", str(path)).strip() != "arm64":
        raise ValueError(f"{path}: expected only arm64")
    build = command("vtool", "-show-build", str(path))
    versions = re.findall(r"^\s*minos\s+([0-9.]+)$", build, re.M)
    if versions != [minimum]:
        raise ValueError(f"{path}: minOS {versions}, expected {minimum}")


def rpaths(path: Path) -> list[str]:
    loads = command("otool", "-l", str(path))
    paths = re.findall(
        r"^\s*cmd LC_RPATH\s*\n\s*cmdsize \d+\s*\n\s*path (\S+) \(offset \d+\)",
        loads, re.M,
    )
    if len(paths) != loads.count("cmd LC_RPATH"):
        raise ValueError(f"{path}: malformed LC_RPATH load command")
    return paths


def verify(root: Path, minimum: str, builds: list[Path], check_licenses: bool) -> int:
    executable = root / "bin/nemo-speech"
    library_dir = root / "lib"
    if executable.is_symlink() or library_dir.is_symlink() or not library_dir.is_dir():
        raise ValueError("the CLI and lib directory must be bundled directly")
    if not executable.is_file() or not all((library_dir / name).is_file() for name in REQUIRED):
        raise ValueError("the CLI or a required dylib is missing")
    bundled_lib = library_dir.resolve(strict=True)
    for path in library_dir.iterdir():
        if path.is_symlink():
            target = Path(os.readlink(path))
            if target.is_absolute() or not path.resolve(strict=True).is_relative_to(bundled_lib):
                raise ValueError(f"{path}: absolute or escaping library symlink")
    if check_licenses and not all((root / "licenses" / name).is_file() for name in LICENSES):
        raise ValueError("a pinned runtime license or notice is missing")
    if any(root.rglob("*.metallib")):
        raise ValueError("Metal shaders must be embedded")
    objects = []
    for build in builds:
        found = list(build.rglob("*.o"))
        if not found:
            raise ValueError(f"requested build object verification has no objects: {build}")
        objects.extend(found)
    for path in [executable, *(library_dir / name for name in sorted(REQUIRED)), *objects]:
        mach_o(path, minimum)

    libraries = [executable, *(library_dir / name for name in sorted(REQUIRED))]
    for path in libraries:
        loads = command("otool", "-L", str(path)).splitlines()[1:]
        for line in loads:
            dependency = line.strip().split(" (")[0]
            if dependency.startswith("@rpath/"):
                name = dependency[len("@rpath/"):]
                if Path(name).name != name or not (library_dir / name).is_file():
                    raise ValueError(f"{path}: missing {dependency}")
            elif not (dependency.startswith("/usr/lib/") or
                      dependency.startswith("/System/Library/")):
                raise ValueError(f"{path}: external dependency {dependency}")
        expected = ["@loader_path/../lib"] if path == executable else [
            "@loader_path", "@loader_path/../lib",
        ]
        actual = rpaths(path)
        if sorted(actual) != sorted(expected):
            raise ValueError(f"{path}: unexpected RPATH set {actual}")
    help_result = subprocess.run([str(executable), "help", "diarize"],
                                 capture_output=True, text=True, check=True, timeout=15)
    if "v3-offline" not in help_result.stdout:
        raise ValueError("installed helper does not advertise the pinned preset")
    print(f"Nemotron helper verified: {len(libraries)} Mach-O files, "
          f"{len(objects)} objects, arm64 macOS {minimum}, relative dependency closure")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--minimum", default="14.2")
    parser.add_argument("--build", type=Path)
    parser.add_argument("--sentencepiece-build", type=Path)
    parser.add_argument("--skip-licenses", action="store_true",
                        help="licenses are verified separately in a signed app bundle")
    args = parser.parse_args()
    builds = [path for path in [args.build, args.sentencepiece_build] if path]
    try:
        return verify(args.root, args.minimum, builds, not args.skip_licenses)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Nemotron helper verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
