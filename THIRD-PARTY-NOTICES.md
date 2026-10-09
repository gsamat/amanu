# Third-party notices

Amanu includes the following open-source components. Exact copies of their
license texts are included in every application bundle under
`Contents/Resources/Licenses`.

| Component | Version | License |
|---|---:|---|
| [LocalVQE](https://github.com/localai-org/LocalVQE) (echo canceller) | f53063c | Apache License 2.0 |
| [ggml](https://github.com/ggml-org/ggml), distributed with LocalVQE | c044a8e | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache License 2.0 |
| fastcluster, distributed with FluidAudio | bundled | BSD 2-Clause |
| vbx, distributed with FluidAudio | bundled | Apache License 2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache License 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | MIT and bundled external notices |
| Ed25519 verification code distributed with Sparkle | bundled | zlib-style license |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 1.9.4 / b5130 (927cfce) | MIT |
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | 0.2.0 | MIT |
| ggml, distributed with transcribe.cpp | bundled | MIT |
| miniz, distributed with transcribe.cpp | bundled | MIT |

Amanu itself is available under the [MIT license](LICENSE), retaining the
copyright and license notice of the quill project from which it began.

The LocalVQE build uses a small Amanu macOS packaging patch to produce one
self-contained Intel dylib instead of runtime-loaded CPU-variant libraries.
The inference implementation and model are otherwise the pinned upstream work.

## Optional local diarization weights

The separate download from
[FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
is pinned to `df2625ac79a7ac6b65ad868fee6d80f320da4232`. Its Community-1
Segmentation, FBank, Embedding, PLDA, PldaRho, and serialized parameter artifacts
are distributed under CC BY 4.0. Amanu verifies their sizes and SHA-256 hashes
and retains `LICENSE`, `NOTICE.md`, `PROVENANCE.md`, `README.md`, and
`provenance.json` beside the downloaded models. The
[pinned notice](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md)
defines attribution and the exact license scope; the SDK's Apache 2.0 license
does not replace it. Legacy online diarizer models are not part of this
download. The published provenance records historical limitations, so these
binaries are not claimed to be fully reproducible conversions.
