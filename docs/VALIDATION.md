# Validation record

## Gemini recovery update — 2026-11-16

- The affected saved job contained a complete transcription, one successful Gemini analysis response, and a second response with `MAX_TOKENS`. The latter had consumed 3,773 thinking tokens and 309 visible output tokens against the old 4,096-token allowance. Its saved incomplete response was replayed indefinitely by the old Resume path.
- Deterministic provider tests cover legacy cache migration, bounded output-limit recovery, accounting for thought-only token usage, budget checks, safety blocks, uncertain requests, and usage-save failure. The actual saved job and its cache were also replayed from a private disposable copy with all provider traffic mocked: the completed part was reused and the remaining part was requested once through the mock. No live Gemini inference was performed during that replay.
- SQLite recovery tests damaged both a job row and its latest snapshot, then successfully recovered its earlier checkpoint without changing the source media. Queue tests cover preserving the original transcript and preset when explicitly changing connections, and preventing retries of unresolved requests from a recovered failed state.
- `swift test`: 64 tests executed, seven opt-in tests skipped, zero failures. The private checkpoint replay was run separately and passed.
- The installed app then resumed the affected 18:22 project with its saved transcript and Gemini 3.7 Flash configuration. After macOS downloaded the iCloud-only source, the job finished with five clips and one new Gemini request; the previously successful part was reused. Independent `ffprobe` checks confirmed each MP4 has 1080×1920 H.264 video and AAC audio, and each has an SRT sidecar. This is one live Gemini recovery, not broad certification of cloud models or editorial quality.

The provider tests do not guarantee a particular Gemini model will finish or produce acceptable clips. Automatic recovery cannot enforce a budget when token prices are unknown and the user has opted into unknown-cost processing. A whole SQLite-file failure still requires restoring a library backup; per-project snapshots alone are not a full media or machine backup.

Executed on 2026-10-29 on an Apple M4 Pro with 24 GB RAM, macOS 27.0.1, Xcode 27.1 / Swift 6.4. Deployment target is macOS 14; older macOS releases have not been runtime-tested.

## Automated checks

`swift test` completed 56 tests: 50 passed, six opt-in tests skipped, zero failures. The six opt-in tests were each executed successfully in separate runs. The standard suite log is the ignored `.build/tests.log`.

| Area | Executed evidence |
|---|---|
| Native media | Real AVFoundation export and frame/audio validation; H.264/AAC, burned captions, SRT, separate-track native mux, portrait rotation, cancellation without publishing partial output. |
| Timing and edits | Discontiguous and reordered ranges; source/output timestamp mapping; sentence edits preserve previously removed filler/pause gaps; invalid ranges rejected. |
| Input variety | 4K screen-content preservation, silent source, corrupt file rejection, variable frame timing, a real 7,200-second low-bitrate fixture with selection near its end. |
| URL acquisition | Pinned yt-dlp against a controlled HTTP video server. Arbitrary YouTube sites/accounts and private/protected links are not certified by that test. |
| Queue and recovery | SQLite restart, cached AI reuse, pause/resume, cancellation with uncertain paid outcomes, failed-source isolation, manual candidate selection, recovery of a published export before its checkpoint. |
| Source identity | Streaming SHA-256 detects changed bytes even with unchanged file length and modification time. Legacy analyzed checkpoints without recorded identity cannot silently adopt changed media. |
| Provider contracts | Deterministic transport fixtures for OpenAI, Anthropic, Gemini, compatible endpoints and Ollama; malformed output, invented source IDs, rate/key errors, unknown prices, spending ceiling, chunk deduplication, pending journals, cache replay, and visual-stage cut preservation. |
| Privacy boundary | Remote plaintext/credential-bearing/query endpoints and redirects rejected; error-body redaction; known Ollama cloud tags and remote aliases rejected before inference. |
| Caption composition | Real green/white glyph painting inside asymmetric safe bounds; bounded cache stores small caption panels; shared native composition feeds preview and export. |

## Actual local inference

- FluidAudio Parakeet v3 plus Community-1 diarization: generated spoken fixture produced usable words, timestamps and speaker labels in the isolated worker.
- WhisperKit `openai_whisper-base.en`: actual generated-speech transcription passed. The larger default model was not separately benchmarked.
- Existing local Ollama `qwen3.5:2b`: actual provider test selected a valid 13.02-second clip, using 654 input / 127 output tokens in approximately 1.87 seconds after request fixes. API cost was $0. No cloud inference occurred.
- Read-only research checks against original Cloth demo media: a 42.77-second audio sample produced 118 words and one speaker label; a silent 13.07-second two-person sample supported consistent S1 framing and full-frame fallback around ambiguous S2 speech. Reliable S2 isolation was **not** demonstrated. These media and derived test artifacts are not shipped.

The local smoke tests exposed and led to fixes for model thinking exhausting the answer limit, excessive default context, invented segment IDs, and candidates outside requested durations. The adapter uses metadata-supported thinking controls, a 16K context, a schema constrained to supplied source IDs, and bounded legal-range guidance. Invalid-duration candidates are dropped without changing their boundaries; a response with no valid candidates remains an explicit error. Materially overlapping candidates are deduplicated before rendering.

## Desktop acceptance

The packaged app builds, ad-hoc signs and launches; `codesign --verify --deep --strict` passes. Direct UI checks covered the welcome screen, connection/model discovery, local model selection, source import through the native picker, duration settings, batch disclosure, progress, error recovery and saved transcript availability.

The app completed a fully local batch using the generated 48.3-second `Studio-Demo.mp4`, FluidAudio and existing Ollama `qwen3.5:2b`. The temporary test recipe requested up to five 10–22 second clips. After duration validation and overlap deduplication, one 12.72-second clip was published with burned captions and an SRT sidecar. Independent ffprobe inspection confirmed 1080×1920 H.264 and AAC, with video/audio duration difference below one millisecond.

The native editor opened the export, excluded its first sentence, previewed the revised composition and rendered a new 8.96-second revision titled **Local pipeline demo**. The original export remains intact. The persistent usage record count stayed at four before/after the edit: there was no new AI request. The app returned to `COMPLETED`, and normal five-clip / 30–90 second defaults were restored.

The editor initially exposed a system `_AVKit_SwiftUI` superclass-metadata crash on this development OS. Hosting an explicit AppKit `AVPlayerView` replaced that wrapper. The same opening, preview and edit/export sequence then passed. The completed job and previous output survived the crash and app restart.

Generated demonstration exports are under `~/Movies/Edward Scissorhands/Studio-Demo-34AE3B58/`. They are test material, not an editorial-quality benchmark for real interviews.

## Remaining validation boundaries

- Cloud providers have contract tests. One configured Gemini 3.7 Flash recovery was exercised live on 2026-11-16; the other paid adapters have not been live-validated here. Model capability and price settings must match the chosen account/model.
- Speaker framing is a conservative visual heuristic. Representative user interviews, obscured/offscreen speakers, rapid camera cuts and editorial quality still require content-specific assessment.
- The two-hour test verifies media timing/export. Full two-hour ASR/diarization runtime and peak memory have not been benchmarked.
- Selected-frame visual analysis is implemented. Direct raw-video upload to Gemini is not part of this build. Transcription choices are local FluidAudio, local WhisperKit and imported timed transcripts.
- Default speech weights are fetched by pinned upstream SDKs, but their automatic model repository revisions are not frozen. A reproducible model installation requires retaining the resolved model files; see MEDIA.md.
- Disk-space checks exist, but the machine was not deliberately filled to exercise actual ENOSPC behavior. The app is ad-hoc signed for personal use, not notarized for public distribution.
- Original Cloth paid processing was unobservable without credits. No Setapp credit was bought or used. This limits comparison against Cloth's remote behavior; it does not limit Edward's independent local pipeline.

See [feature-to-implementation map](../research/feature-implementation-map.md) and [investigation](../research/native-findings.md) for the exact reconstruction evidence boundary.
