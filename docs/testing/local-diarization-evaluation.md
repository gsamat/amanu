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
