#!/usr/bin/env python3
"""Regression checks for the shipped NeMo helper's relative library closure."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts/verify-nemotron-diar.py"
ALIAS = "libggml.0.dylib"
TARGET = "libggml.0.25.1.dylib"


def fixture(source: Path, destination: Path) -> Path:
    (destination / "bin").mkdir(parents=True)
    (destination / "lib").mkdir()
    shutil.copy2(source / "bin/nemo-speech", destination / "bin/nemo-speech")
    for item in (source / "lib").iterdir():
        copied = destination / "lib" / item.name
        if item.is_symlink():
            copied.symlink_to(item.readlink())
        elif item.is_file():
            shutil.copy2(item, copied)
    return destination


def check(name: str, helper: Path, should_pass: bool) -> None:
    result = subprocess.run(
        ["python3", str(VERIFIER), str(helper), "--skip-licenses"],
        capture_output=True, text=True, timeout=30,
    )
    if (result.returncode == 0) != should_pass:
        raise AssertionError(
            f"{name}: expected {'pass' if should_pass else 'failure'}, "
            f"got exit {result.returncode}: {result.stdout}{result.stderr}"
        )
    print(f"{name}: {'passed' if should_pass else 'rejected'}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", type=Path, help="an already-built NeMo helper root")
    source = parser.parse_args().helper.resolve(strict=True)
    external = (source / "lib" / TARGET).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="amanu-nemotron-verifier-") as temporary:
        base = Path(temporary)
        check("current helper", source, True)
        check("copied relative closure", fixture(source, base / "positive"), True)

        absolute = fixture(source, base / "absolute-alias")
        alias = absolute / "lib" / ALIAS
        alias.unlink()
        alias.symlink_to(external)
        check("absolute escaping alias", absolute, False)

        escaping = fixture(source, base / "relative-escape")
        alias = escaping / "lib" / ALIAS
        alias.unlink()
        alias.symlink_to(os.path.relpath(external, alias.parent))
        check("relative escaping alias", escaping, False)

        rpath = fixture(source, base / "absolute-rpath")
        subprocess.run(
            ["install_name_tool", "-add_rpath", "/tmp/amanu-verifier-outside",
             str(rpath / "bin/nemo-speech")],
            check=True, capture_output=True, text=True,
        )
        check("extra absolute RPATH", rpath, False)


if __name__ == "__main__":
    main()
