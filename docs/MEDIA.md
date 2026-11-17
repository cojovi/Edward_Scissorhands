# Media engine and local model setup

Edward's production media implementation is independent code. It does not load Cloth binaries, models, credentials, or bundled resources. Explicit opt-in research tests can read selected installed Cloth sample media; they are not app dependencies or redistributed fixtures.

## Build and dependencies

Use Xcode 27.1 / Swift 6.4 on the development Mac. The package targets macOS 14; acceptance testing was performed on an Apple M4 Pro with 24 GB RAM running macOS 27.0.1. Older deployment targets have not been runtime-tested.

```sh
./scripts/media-tools.sh
swift build --product EdwardMediaWorker
swift build --product EdwardScissorhands
```

The dependency script verifies SHA-256 before installing yt-dlp 2026.10.26 and QuickJS-NG 0.17.0 into the ignored `.tools` directory. A packaged app needs those two executables and `EdwardMediaWorker` in `Contents/Resources/bin`, plus SwiftPM resource bundles produced by the build. FFmpeg is used by the test suite to generate synthetic fixtures; production extraction, muxing, preview, captions, and export use Apple frameworks.

SwiftPM pins FluidAudio 0.18.0 and WhisperKit 1.1.1. Upstream model downloads occur on first use; this may take substantially longer than subsequent runs. SDK model repositories can change independently of the pinned Swift packages. No exact model-weight revision pin is claimed for default automatic downloads.

## Selecting local speech models

- **FluidAudio:** blank means Parakeet v3. Enter `v2` for English-only Parakeet or `v3` for the multilingual version. An absolute folder containing compatible Parakeet CoreML bundles is also accepted. The default cache is `~/Library/Application Support/FluidAudio/Models/`.
- **WhisperKit:** blank means `openai_whisper-large-v3_turbo`. Enter another compatible model folder name from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml). The SDK's default download cache is `~/Documents/huggingface`. `openai_whisper-base.en` was used for the actual inference smoke test; the larger default was not separately benchmarked.
- **Speaker recognition:** FluidAudio's offline Community-1 pipeline is applied after speech recognition. Disabling recognition skips this model and its download. If recognition fails after ASR succeeds, the transcript is retained and its engine label reports `speaker recognition unavailable`. Cancellation still propagates.
- **Imported transcripts:** UTF-8 SRT or Edward's Codable `TimedTranscript` JSON. SRT has cue-level times; its interpolated word times are explicitly labeled as such.

Audio stays local for these speech stages. The AI editorial/visual provider selected elsewhere in the app controls subsequent cloud transmission.

## Long videos and failure recovery

Local inference runs in the separate `EdwardMediaWorker` process. Cancellation terminates that owned process, and force-stops it after a grace period if necessary. Temporary request/result files are removed. Provider API credentials are not inherited by these subprocesses.

FluidAudio uses `transcribeDiskBacked`; WhisperKit uses incremental 300-second audio chunks with one buffered chunk. Offline diarization consumes the file through FluidAudio's memory-mapped audio source. The complete PCM recording is not intentionally materialized in the app. Model weights and intermediate tensors still occupy memory; transcript words, diarization embeddings, and metadata grow with recording length. A full two-hour ASR/diarization workload has not been benchmarked.

Video extraction and rendering stream through AVFoundation. Edits are ordered source ranges, quantized to a 60,000 Hz media clock. The same `AVVideoComposition` supplies preview and export. Export uses H.264/AAC MP4 with 30 fps output, independently selected bitrate (5/12/22 Mbps), and SRT sidecars. These bitrate presets are Edward design choices; research established Cloth's quality picker controls acquisition, not its export bitrates.

Downloaded MP4/AAC tracks are muxed natively without reencoding. Unavailable/private/protected links surface downloader errors. No browser cookies or paid-service credentials are automatically collected. Local source files remain unmodified. Final video filenames appear only after duration, decoded frame, and audio-sample validation; interrupted exports leave no published partial MP4.

## Framing and captions

Single visible faces can guide crops. For multiple faces, nearby mouth-landmark changes are compared and associated conservatively with diarized speaker labels. Ambiguous associations, absent faces, and tutorial mode preserve the complete frame. This is a heuristic, not an audiovisual speaker-recognition model. It has not been broadly validated against representative interviews, obscured mouths, dubbing, or rapid camera cuts; it must not be presented as guaranteed active-speaker tracking.

With explicit authorization, the installed Cloth onboarding source was used read-only for a narrow qualitative check: two people, 13.07 seconds, 960×540. The source has no audio, so its supplied speaker labels were used as reference timing. Framing consistently selected the left speaker during S1 speech and preserved both people around the short S2 interval; it did not establish a reliable crop of S2. A separate 42.77-second already-cropped portrait demo produced 118 words and one speaker label through local Parakeet v3 plus Community-1 diarization. These checks do not validate diarization on an original two-person recording. Derived research outputs stay under ignored `.test-artifacts/media-research`, and no Cloth media ships in the app.

Portrait captions reserve an asymmetric conservative safe area: 48 px left, at least 176 px right, 230 px top, and 300 px bottom against a 1080×1920 canvas. The requested inset can increase that margin. The area is an editorial default across common short-video layouts, not a guarantee against current or future platform overlays. Top/bottom captions, speaker colors, and active-word highlights use CoreText in both preview and export.

## Verification

```sh
swift build --target EdwardTests
swift test --filter Media
EDWARD_TEST_MODELS=1 swift test --filter MediaTranscriptionTests
EDWARD_TEST_WHISPER=1 swift test --filter MediaTranscriptionTests
# Optional only when the installed Cloth sample is an authorized research input:
EDWARD_TEST_CLOTH=1 swift test --filter MediaResearchTests
```

Model tests are opt-in because they may download large upstream weights. They synthesize speech with macOS `say`, run real local inference in the worker, and require usable word timestamps and speaker labels. Synthetic rendering cases cover reordered ranges, rotated footage, video/audio muxing, HTTP URL import, 4K screen content, variable frame timing, silent/corrupted files, cancellation, and source-time selection near the end of a two-hour low-bitrate file. These tests validate engineering behavior; they do not establish editorial quality or speaker-framing quality on real productions.

If app UI work temporarily prevents `swift test` from building the entire package, build the test target and use `xcrun xctest` on `.build/out/Products/Debug/EdwardTests.xctest` with a minimal environment. Avoid invoking `xctest -help`: on this Xcode release an invalid invocation prints the inherited environment.
