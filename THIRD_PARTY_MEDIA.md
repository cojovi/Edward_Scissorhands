# Third-party media components

The versions below were independently acquired from their upstream sources. Full available license and notice files are retained in `licenses/media/`; include that directory with packaged distributions.

| Component | Version / source | Upstream license information |
| --- | --- | --- |
| FluidAudio | [0.18.0](https://github.com/FluidInference/FluidAudio/tree/v0.18.0) | Apache-2.0; component notices include fastcluster, VBx, NemoTextProcessing, and packaged language resources. |
| WhisperKit / Argmax OSS Swift | [1.1.1](https://github.com/argmaxinc/WhisperKit/tree/v1.1.1) | MIT, copyright Argmax, Inc. |
| yt-dlp standalone macOS executable | [2026.10.26](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26) | The source is Unlicense; the PyInstaller-bundled executable is a GPLv3+ combined work. Retained `THIRD_PARTY_LICENSES.txt` describes bundled components. |
| QuickJS-NG arm64 executable | [0.17.0](https://github.com/quickjs-ng/quickjs/releases/tag/v0.17.0) | MIT; see retained copyright/license text. |
| NemoTextProcessing binary target | [text-processing-rs 0.3.1](https://github.com/FluidInference/text-processing-rs/releases/tag/v0.3.1) | Apache-2.0 and component notices supplied by FluidAudio; SPM verifies the upstream archive checksum. |
| FFmpeg | Host installation 8.1.1 | Used only to generate test fixtures; not copied into Edward's app bundle by the media implementation. The current host build enables GPL components. |

## Runtime-downloaded model attribution

Model weights are separate from the SDK code licenses. They are downloaded by the SDKs into the user's cache, rather than shipped from Cloth or embedded by this project.

- **Parakeet TDT v3:** NVIDIA's Parakeet model, converted for Core ML by Fluid Inference. The [Core ML model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) identifies CC-BY-4.0. Edward does not modify these model weights. The v2 option uses its separate [model repository](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml); consult that model's terms when selecting it.
- **Offline Community-1 diarization:** attribute **pyannote, WeSpeaker, BUT Speech@FIT, and Fluid Inference**. The supported Segmentation, FBank, Embedding, PLDA/PldaRho, and accompanying parameter files are modified Core ML conversions of Community-1 components, scoped under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). The retained [upstream notice](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md) distinguishes these artifacts from separately licensed legacy models. Edward uses the offline Community-1 API, not the legacy online diarizer.
- **WhisperKit models:** OpenAI Whisper models converted/optimized for Core ML by Argmax. The [argmaxinc/whisperkit-coreml model repository](https://huggingface.co/argmaxinc/whisperkit-coreml) identifies MIT. Individual alternative model selections may carry their own upstream terms.

Default downloads follow the pinned SDK's current repository configuration. The model-card snapshot reviewed on 2026-10-29 was Parakeet v3 `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, diarization `7eab74f3463c736418d0eb10296261ae581146c9`, and WhisperKit models `0f63a7800b00dd0226abd051b906c246e1907482`. These are documentation snapshot identities, not a claim that the download helper pins all weights to those revisions.

## Download identities

- `yt-dlp_macos`: SHA-256 `0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa`
- `qjs-darwin-arm64`: SHA-256 `8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11`

Hashes identify upstream downloads before local application code signing.
