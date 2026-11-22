#!/usr/bin/env python3
"""Make one small, annotated AMI ES2004a smoke fixture outside this checkout."""

import argparse
import json
import math
import os
from pathlib import Path
import wave
import xml.etree.ElementTree as ET


# These four single-speaker source spans were checked against all four AMI
# segment files. Keep the fixed choice: changing it changes the benchmark.
SPANS = (
    ("B", 10.944, 14.737),
    ("D", 49.613, 53.228),
    ("A", 63.063, 66.416),
    ("C", 428.096, 430.320),
)
RATE = 16_000
SILENCE_FRAMES = RATE // 2


def elements(path, name):
    return ET.parse(path).getroot().findall(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    checkout = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == checkout or checkout in output.parents:
        parser.error("output must be outside the checkout")
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be empty")

    all_segments = []
    for speaker in "ABCD":
        path = args.annotations / "segments" / f"ES2004a.{speaker}.segments.xml"
        for segment in elements(path, "segment"):
            start = float(segment.attrib["transcriber_start"])
            end = float(segment.attrib["transcriber_end"])
            all_segments.append((speaker, start, end))
    for speaker, start, end in SPANS:
        if not any(speaker == s and abs(start - a) < 0.001 and abs(end - b) < 0.001
                   for s, a, b in all_segments):
            parser.error("expected pinned AMI segment annotation is absent")
        if any(speaker != s and max(start, a) < min(end, b)
               for s, a, b in all_segments):
            parser.error("selected AMI spans overlap another annotated speaker")

    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output, 0o700)
    turns = []
    words = []
    with wave.open(str(args.audio), "rb") as source:
        if (source.getnchannels(), source.getframerate(), source.getsampwidth(),
                source.getcomptype()) != (1, RATE, 2, "NONE"):
            parser.error("expected mono 16 kHz signed 16-bit PCM WAV")
        with wave.open(str(output / "ami-four-voices.wav"), "wb") as target:
            target.setparams(source.getparams())
            offset_frames = 0
            for index, (speaker, start, end) in enumerate(SPANS):
                if index:
                    target.writeframes(b"\0\0" * SILENCE_FRAMES)
                    offset_frames += SILENCE_FRAMES
                first = math.floor(start * RATE)
                last = math.ceil(end * RATE)
                source.setpos(first)
                frames = source.readframes(last - first)
                if len(frames) != (last - first) * 2:
                    parser.error("selected AMI audio is truncated")
                target.writeframes(frames)
                shift = (offset_frames - first) / RATE
                turns.append({"speaker": speaker, "start": start + shift,
                              "end": end + shift})
                path = args.annotations / "words" / f"ES2004a.{speaker}.words.xml"
                for word in elements(path, "w"):
                    if word.attrib.get("punc") == "true":
                        continue
                    a = float(word.attrib["starttime"])
                    b = float(word.attrib["endtime"])
                    if start <= a < b <= end and (word.text or "").strip():
                        words.append({"text": word.text.strip(), "start": a + shift,
                                      "end": b + shift, "speaker": speaker})
                offset_frames += last - first
    if len(turns) != 4 or len(words) < 20:
        parser.error("AMI annotations did not produce the expected real-voice fixture")
    audio = output / "ami-four-voices.wav"
    os.chmod(audio, 0o600)
    manifest = {"version": 1, "samples": [{
        "variants": [{"format": "pcm", "audio": audio.name}],
        "referenceTurns": turns, "referenceWords": words,
    }]}
    destination = output / "corpus.json"
    destination.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    os.chmod(destination, 0o600)
    print("Prepared one public AMI sample with four distinct annotated voices")


if __name__ == "__main__":
    main()
