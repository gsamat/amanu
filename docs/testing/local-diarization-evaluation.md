# Local diarization evaluation

This is an opt-in test for an **already downloaded and verified** FluidAudio
OfflineDiarizer model and a caller-supplied annotated corpus. The ordinary test
suite skips it. The runner never downloads a model, calls a cloud service, reads
the user's Amanu configuration, or invokes a summarizer. `Home.sandbox` scopes
the evaluation, and the model store verifies every pinned asset before loading.

Use audio and annotations you created or are allowed to evaluate. Keep the
corpus outside the checkout. Do not add recordings, words, paths, or the corpus
manifest to an issue or PR. The report contains only numbers and public
hardware/model identifiers; it uses sample numbers instead of file names.

## Corpus manifest

Put `corpus.json` beside its audio files, outside the checkout. Audio paths are
relative to that directory and cannot escape it through `..` or symlinks. All
times are seconds on the decoded audio clock. A single-source or separated
system track is mono; each variant is decoded to the same 16 kHz PCM format
the production pipeline uses. Reference turns and words must be manually
checked against the audio. Different real voices need different `speaker`
values; labels may be arbitrary strings.

```json
{
  "version": 1,
  "samples": [
    {
      "variants": [
        {"format": "caf", "audio": "clip.caf"},
        {"format": "aac", "audio": "clip.m4a"}
      ],
      "referenceTurns": [
        {"speaker": "person-1", "start": 0.3, "end": 1.9},
        {"speaker": "person-2", "start": 2.1, "end": 3.6}
      ],
      "referenceWords": [
        {"text": "Привет", "start": 0.4, "end": 0.9, "speaker": "person-1"}
      ],
      "asrWords": [
        {"text": "Привет", "start": 0.4, "end": 0.9, "speaker": null}
      ]
    }
  ]
}
```

`asrWords` is optional: supply actual timed ASR output from the engine being
assessed. The runner uses Amanu's production `DiarizationAlignment` to assign
those words to the model's turns. It does **not** substitute reference words as
ASR output. Without `asrWords`, word attribution and ASR WER are absent from
the report. `referenceWords` can be empty when only DER is available.

Optional fields on each sample are `pr37Turns` (a map from `"0.6"`, `"0.7"`,
`"0.8"` to independently captured PR #37 turn arrays), `gigaAMOldWords`, and
`gigaAMNewWords`. The latter two use the same word object shape and produce
separate WER values. The runner does not execute PR #37 or old/new GigaAM ASR;
leave those fields absent unless the respective outputs were measured on the
**same** corpus. A missing control is omitted from the report, never recorded
as a zero score.

Use several approved examples: clear 2–3 voices, 5–8 voices, short replies and
interruptions, similar voices, noise/compression, mic/system overlap, and a
single-source import. A public AMI corpus crop with verified annotations can
exercise real multi-voice smoke. It does not establish accuracy on Russian
Zoom or КTalk meetings. Pitch-shifting one voice does not create an independent
speaker-quality sample.

For a reproducible English smoke sample, `prepare-ami-diarization-fixture.py`
accepts the public AMI `ES2004a` mono 16 kHz WAV and the extracted
`annotations/{segments,words}/ES2004a.[ABCD].*.xml` files. It checks the
selected four source spans against every speaker's segment annotations, cuts
them in a fixed order with half-second digital silence, and shifts the actual
word and turn timings onto the new PCM clock. It writes `corpus.json` and a
14.485-second WAV to an empty directory outside Git. It makes no network call
and prints no annotated words.

The validation run used the [public AMI mirror](https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/tree/722d8891643e1e4dc62cfd0d198fa05a1646c3cc)
at revision `722d8891643e1e4dc62cfd0d198fa05a1646c3cc`, with
`sdm/ES2004a.Mix-Headset.wav` and `annotations/ami_public_manual_1.6.2.zip`.
Its dataset card declares CC BY 4.0 and credits the AMI Consortium; keep that
attribution with any redistributed crop. The crop and annotations used here
remain outside Git.

```sh
python3 docs/testing/prepare-ami-diarization-fixture.py \
  --audio /absolute/AMI/ES2004a.wav \
  --annotations /absolute/AMI/annotations \
  --output /absolute/outside-checkout/ami-evaluation
```

That smoke manifest intentionally has no `asrWords`, so ASR WER and
speaker-attributed word errors remain unmeasured until actual timed ASR output
is supplied. The four voices are real people, but the constructed clip omits
overlapping speech and does not stand in for a natural meeting.

## Run

Use an absolute model directory that already passes Amanu's model verification.
The report path must be inside this checkout's `.build` directory. The suite
runs thresholds 0.6, 0.7, and 0.8 on every sample and format, twice each. It
does not tune the threshold per file.

```sh
AMANU_DIAR_EVAL_RUN=1 \
AMANU_DIAR_EVAL_CORPUS=/absolute/private/corpus.json \
AMANU_DIAR_EVAL_MODELS=/absolute/verified/diarization \
AMANU_DIAR_EVAL_REPORT="$PWD/.build/evaluation/report.json" \
swift test --no-parallel --filter DiarizationEvaluationTests
```

The model directory can be the one populated by Amanu's explicit model
download control. This evaluation does not download it. A separate clean invocation avoids
other tests contributing to process-wide peak resident memory. Keep the JSON
local; its numeric scores may still describe a private meeting even though no
text or path is emitted.

## Read the report

DER (diarization error rate) is `(missed + false alarm + speaker confusion) /
reference speaker-seconds`. The evaluator sweeps exact annotation boundaries.
Its fixed 0.25-second collar excludes time within 0.25 seconds of **either
side** of every reference turn start or end. It reports both overlap-included
and overlap-excluded DER; exclusion removes intervals with more than one
reference speaker. A global one-to-one maximum-coactive-time Hungarian mapping
matches hypothesis IDs to reference IDs, with no speaker-count cap. An absent DER
means there was no scored reference speech after exclusions. Raw miss, false
alarm, confusion, and reference speaker-seconds accompany the rate.

Word attribution uses one-to-one maximum temporal overlap between reference
and hypothesis words, then the same global speaker mapping. `matched`,
`wrong`, `unknown`, and `unmatchedReference` are separate counts. The report
also counts all hypothesis words and all unknown hypothesis words, including
those without a reference-word match. All-unknown output therefore cannot look
accurate. WER tokenizes Unicode letters/numbers,
folds case, and computes edit distance; it is independent of speaker errors.
Unmatched hypothesis words contribute to WER but not to the word-attribution
denominator. Compare ASR WER and speaker errors together.

Each observation records diarization wall time divided by audio duration,
model preparation time, audio duration, process peak RSS, hardware model,
macOS version, CPU count, pinned model revision/fingerprint, and runtime
version. Preparation time is repeated on rows from the same threshold load;
the first load in a process and subsequent loads are distinguishable by row
order, but an OS cache may already be warm. RSS is a process high-water mark,
not model-only allocation. Every observation includes `sourceFingerprint`
for the prepared PCM; repeated runs of a variant must have the same value.
`variantsSameDecodedPCM` compares the actual
decoded PCM fingerprints for CAF/AAC inputs; a difference is evidence of
different decoder input, not necessarily a diarization defect. The second run
on each identical prepared PCM exposes runtime variability in the recorded
scores and wall time. Neither cluster count nor a synthetic demo alone proves
speaker quality.

Record separately which corpus categories, model smoke, CAF/AAC comparisons,
GigaAM controls, and Russian calls were actually checked. If annotated Russian
multi-speaker audio is unavailable, leave Russian meeting quality unverified.

## Native model comparison, 2026-10-10

The comparison used an Apple M3 Pro, 18 GiB RAM, macOS 26.7.1 (25G241),
Xcode 27.0 and FluidAudio 0.15.5. Every model saw the same mono 16 kHz PCM
and human reference turns. Each inference ran twice, with identical normalized
turns on repeats. Scoring reused `DiarizationEvaluation` with the fixed collar
and mapping above. There were no reference speaker-count hints or per-file
settings. Community-1 used its default clustering threshold of 0.6; the
separate 0.7/0.8 observations did not determine its primary score.

AMI contains two natural 180-second windows of ES2004a, starting at 180 and
600 seconds, from the pinned public mirror above. NOTSOFAR evaluation recordings
come from [Microsoft's dataset](https://huggingface.co/datasets/microsoft/NOTSOFAR/tree/ba8fd0f034ce185fe4d24f47e53b4b8194795f07),
revision `ba8fd0f034ce185fe4d24f47e53b4b8194795f07`, under
`benchmark-datasets/eval_set/240825.1_eval_full_with_GT/MTG`.
The first sorted seven-person and six-person meetings were chosen from all
129 available metadata records before inference: MTG32100 (478.163 seconds)
and MTG32175 (357.573 seconds), channel `sc_meetup_0/ch0.wav`. No eight-person
meeting exists in that evaluation split. Audio LFS hashes and annotation Git
blob hashes were verified; both datasets declare CC BY 4.0. Audio, annotations
and raw reports remain outside source control.

Primary overlap-included DER, followed by detected/reference speaker count:

| Recording | Community-1 | LS-EEND AMI 500 ms | Nemotron 3 Q8_0 |
| --- | --- | --- | --- |
| AMI 180–360 s | 24.45%, 2/4 | 21.66%, 3/4 | 31.46%, 4/4 |
| AMI 600–780 s | 15.26%, 3/4 | 6.07%, 4/4 | 7.75%, 4/4 |
| NOTSOFAR eval MTG32100 | 45.34%, 4/7 | Capacity limited to four | 4.27%, 7/7 |
| NOTSOFAR eval MTG32175 | 45.09%, 3/6 | Capacity limited to four | 3.08%, 6/6 |

LS-EEND AMI uses the published AMI 500 ms preset, CPUOnly, from
[FluidInference/ls-eend-coreml](https://huggingface.co/FluidInference/ls-eend-coreml/tree/28ce1b1f8ef186729df63b3886fbaae7bc10c4a1)
at `28ce1b1f8ef186729df63b3886fbaae7bc10c4a1`; its compiled bundle is
44,674,992 bytes and has four speaker tracks. It processed a three-minute
AMI window in 1.37–1.80 seconds, excluding initialization, with process peak
RSS of 125–157 MiB. The DIHARD3 100 ms variant was also checked but had
higher DER on these recordings and was not selected for the app.

Nemotron uses [NVIDIA's Q8_0 model](https://huggingface.co/nvidia/Nemotron-3-Diarization/tree/f667ed73aee57d40cc39428eb768b4fd87a0a29e)
at `f667ed73aee57d40cc39428eb768b4fd87a0a29e` (107,012,128 bytes), with
[NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp/tree/8642eaa5cc51efbc17ad0f3e433944ba858a873f)
at `8642eaa5cc51efbc17ad0f3e433944ba858a873f`, Metal and fixed `v3-offline`
chunked inference. The rebuilt helper and its dependency closure target
macOS 14.2. Its first held-out invocation took 42.84 seconds, including cold
Metal shader initialization; repeats took 1.11–2.07 seconds. Process peak RSS
was 291–328 MiB. These are native probe measurements, not end-to-end Amanu
timings; Swift test-process RSS for Community-1 is not directly comparable.

Earlier NOTSOFAR train probes MTG30940 and MTG31005 established native
seven/eight-speaker execution but are not independent quality evidence:
[NVIDIA's model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)
lists NOTSOFAR train and development recordings among its training data.
The evaluation-split recordings above were added for the default decision.
This remains a small comparison of public English speech; it does not prove
unseen-data status for every model, Russian-call accuracy, ASR word attribution,
an hour-long meeting's memory use, or operation on an actual macOS 14.2 machine.

Nemotron 3 is the new default because of its six/seven-speaker evaluation
results and eight-speaker capacity. LS-EEND AMI remains an explicit option for
meetings with at most four speakers, where it performed better on both AMI
windows. Community-1 remains the compact compatibility option. Diarization
itself stays off by default; older persisted requests retain Community-1.

The selected-model paths were also checked through Amanu's actual
`DiarizationEngine.prepare/diarize/release` with separately staged, hash-verified
assets and no model download or ordinary profile access. Nemotron on eval
MTG32175 returned six of six voices with 3.08% overlap-included DER; its first
invocation of the product helper took 27.488 seconds, plus 0.072 seconds of
preparation. LS-EEND AMI on the 600–780-second AMI window returned four of four
voices with 6.07% DER in 1.225 seconds, plus 0.338 seconds of preparation.
Both match their qualification scores. These timings exclude ASR, transcript
attribution and app UI; the Nemotron invocation includes cold initialization.

The opt-in `DiarizationNativeSelectionTests` requires all three variables:
`AMANU_DIAR_NATIVE_MODEL` (`nemotron-3` or `ls-eend-ami`),
`AMANU_DIAR_NATIVE_MODELS` (the matching verified store root), and
`AMANU_DIAR_NATIVE_AUDIO` (mono 16 kHz public audio). For this bounded comparison,
the latter two paths must resolve under `/tmp/amanu-diarization-model-comparison/`.
Run it alone with `swift test --no-parallel --filter DiarizationNativeSelectionTests`.
It writes numeric turns and timings under `.build/diarization-native-<model>.json`;
the same fixed scorer, rather than detected counts alone, supplies the DER above.
