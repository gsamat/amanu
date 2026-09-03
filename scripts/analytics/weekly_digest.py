#!/usr/bin/env python3
"""Render Amanu's rolling seven-day product analytics as a Markdown digest."""

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path


def parse_payload(raw: str) -> dict:
    value = json.loads(raw.strip())
    if not isinstance(value, dict):
        raise ValueError("weekly digest query must return one JSON object")
    return value


def percentage(part: int, whole: int) -> str:
    return "—" if not whole else f"{part / whole * 100:.1f}%"


def trend(current: int, previous: int) -> str:
    if not previous:
        return "new" if current else "flat"
    delta = (current - previous) / previous * 100
    return f"{delta:+.1f}%"


def rows(items: list, dimensions: tuple[str, ...]) -> list[str]:
    if not items:
        return ["- No events."]
    return [
        "- " + " / ".join(str(item.get(key, "unknown")) for key in dimensions)
        + f": {int(item.get('count', 0))}"
        for item in items
    ]


def format_digest(payload: dict) -> str:
    period = payload.get("period", {})
    metrics = payload.get("metrics", {})
    previous = payload.get("previous", {})
    installed = int(metrics.get("installed", 0))
    activated = int(metrics.get("activated", 0))
    started = int(metrics.get("recording_started", 0))
    finished = int(metrics.get("recording_finished", 0))
    transcripts = int(metrics.get("transcript_finished", 0))
    summaries = int(metrics.get("summary_finished", 0))
    lines = [
        f"# Amanu weekly analytics · {period.get('start', '?')}–{period.get('end', '?')}",
        "",
        "## Signal",
        "",
        f"- {installed} installs ({trend(installed, int(previous.get('installed', 0)))} vs previous 7 days)",
        f"- {activated} activated ({percentage(activated, installed)} of installs)",
        f"- {int(metrics.get('active_users', 0))} users completed a transcript "
        f"({trend(int(metrics.get('active_users', 0)), int(previous.get('active_users', 0)))} vs previous)",
        f"- Processing volume: {started} → {finished} → {transcripts} → {summaries} "
        "(started → saved → transcript → summary)",
        f"- {int(metrics.get('speaker_names_finished', 0))} speaker-name passes; "
        f"{int(metrics.get('transcript_fallback', 0))} STT fallbacks; "
        f"{int(metrics.get('artifact_opened', 0))} transcript/library opens",
        "",
        "## STT engine / model",
        "",
        *rows(payload.get("stt", []), ("engine", "model")),
        "",
        "## Summary backend / model",
        "",
        *rows(payload.get("summaries", []), ("backend", "model")),
        "",
        "## Failures",
        "",
        *rows(payload.get("failures", []), ("event", "reason")),
        "",
        "Activation is computed across app sessions with the pseudonymous install UUID. "
        "Counts are aggregate, retained for one year, and small samples should not drive product decisions alone.",
        "",
    ]
    return "\n".join(lines)


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip("'\"")
    return values


def query(compose_dir: Path, sql_path: Path) -> dict:
    config = load_env(compose_dir / ".env")
    command = [
        "docker", "compose", "exec", "-T", "database", "psql", "-X", "-qAt",
        "-v", "ON_ERROR_STOP=1", "-U", config["UMAMI_DB_USER"],
        "-d", config["UMAMI_DB_NAME"],
    ]
    result = subprocess.run(
        command, cwd=compose_dir, input=sql_path.read_text(), text=True,
        capture_output=True, check=True)
    return parse_payload(result.stdout)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> None:
    parser = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    parser.add_argument("--compose-dir", type=Path, default=here)
    parser.add_argument("--output-dir", type=Path, default=here / "reports")
    args = parser.parse_args()
    payload = query(args.compose_dir, here / "weekly-digest.sql")
    markdown = format_digest(payload)
    end = payload.get("period", {}).get("end", "unknown")
    atomic_write(args.output_dir / f"{end}.md", markdown)
    atomic_write(args.output_dir / "latest.md", markdown)
    print(markdown, end="")


if __name__ == "__main__":
    main()
