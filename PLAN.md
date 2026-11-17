# Edward Scissorhands: investigation and build plan

## Summary

Build a personal, native Mac application that automatically turns podcasts, interviews, tutorials, and YouTube videos into finished clips. Support local files, video URLs, user-supplied AI keys, and optional local models. Create an original interface using the supplied palette and both requested design skills.

Development will proceed through **REA investigation → processing engine → provider integration → interface → acceptance testing**. Functional coverage will remain comprehensive throughout these stages.

Planning checks confirmed Cloth 0.1.0, your connected REA checkout, and an M4 Pro Mac with 24 GB memory. Detailed decompilation and implementation have not started.

## 1. Comprehensive REA investigation

- Inventory the entire REA repository, classifying authored source, documentation, tests, dependencies, and generated files. Review its investigation workflows and evidence contracts before using them.
- Configure Ghidra 12.1.x with its required JDK for deep native analysis. REA is connected, but currently reports no available decompiler. Keep the tool setup isolated and reproducible.
- Inventory and hash Cloth’s complete bundle, including both executable architectures, helpers, resources, models, dependencies, signing metadata, and packaged data formats.
- Trace every discovered subsystem: ingestion, downloads, transcription, speaker identification, clip selection, framing, captions, editing, rendering, project storage, background jobs, networking, and error recovery.
- Corroborate static findings with controlled application workflows. Account for every reachable screen, menu, setting, and action, including cancellation and failure states.
- Maintain an evidence ledger distinguishing observed behavior, inferred implementation, and unresolved questions. Record remote or credit-gated behavior as unverified when it cannot be observed.

Deliverables will include an artifact inventory, subsystem dossiers, data-flow diagrams, and a feature-to-test matrix. The reconstruction target is complete coverage of useful observable behavior; recovered original source and unseen server implementation cannot be promised.

The initial feature checklist includes configurable clip counts/durations, topic requests, sentence-based cuts, speaker-follow framing, timed captions, optional manual selection, transcript-based recutting, and saved runs. These are documented product claims to verify during investigation. [Cloth feature reference](https://setapp.com/apps/cloth)

## 2. Application architecture and processing

Use **SwiftUI/AppKit**, with separate Swift modules for domain models, media processing, AI providers, jobs, persistence, and design components. Target Apple Silicon and macOS 14 or later.

- **Media engine:** AVFoundation/VideoToolbox for playback and export, Vision for tracking, and native text composition for captions. Preview and export consume the same `RenderPlan` to keep cuts, framing, and captions consistent.
- **Dependencies:** Obtain pinned tools and models from their upstream projects. Use yt-dlp for supported downloadable URLs and FFmpeg where conversion or normalization is needed. The installed FFmpeg lacks subtitle-rendering filters, so caption rendering will remain native.
- **Persistence:** SQLite behind a dedicated actor, with transactional job checkpoints; store large media in project directories and credentials in macOS Keychain.
- **Job pipeline:** Import → probe → extract audio → transcribe/identify speakers → select clips → analyze visuals → frame/caption → render → verify/export.
- **Recovery:** Resume completed stages after restart, cache paid analysis, isolate failed sources, and clean up owned subprocesses on cancellation. Pause at stage boundaries.
- **Concurrency:** Default to one intensive local operation and two cloud requests. Persist usage and request identifiers; uncertain paid-request outcomes require resolution before retrying.

Shared contracts will cover `MediaAsset`, `TimedTranscript`, `SpeakerTrack`, `ClipProposal`, `RenderPlan`, `JobCheckpoint`, and `ProviderCapabilities`. Media timestamps remain tied to the source timebase; model-generated timestamps must be validated before editing.

## 3. Interchangeable AI providers

Implement adapters for OpenAI, Anthropic, Gemini, OpenAI-compatible endpoints, and local inference through Ollama.

The portable analysis path uses **timed transcripts plus selected frames**. This lets suitable OpenAI and Claude models contribute without requiring direct video input. Gemini’s direct video understanding becomes an optional enhancement for visually dependent material. Compatibility is checked per model and task. [OpenAI model capabilities](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [Claude vision](https://platform.claude.com/docs/en/build-with-claude/vision), [Gemini video](https://ai.google.dev/gemini-api/docs/video-understanding)

- Use upstream FluidAudio for default local transcription and speaker segmentation; offer WhisperKit for additional language/model choices. Validate timing quality on representative footage. [FluidAudio](https://github.com/FluidInference/FluidAudio), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- Allow independent provider/model selection for transcription, editorial analysis, and visual analysis.
- Support configurable model IDs and compatible endpoint URLs without assuming every model supports every modality.
- Show expected uploads, cost estimates when available, usage, and a user-set spending ceiling before a batch starts.
- Process long material in timestamped chunks, consolidate candidates globally, remove duplicates, and reject invalid boundaries.
- Keep rendering and caption changes independent of paid inference. Never silently switch providers or upload additional media.

## 4. Automatic workflow and original design

The primary experience is: **add sources → select a preset → start batch → receive finished clips**. An optional inspector supports corrections.

Default settings:

- Up to five distinct clips per source, targeting 30–90 seconds; return fewer when suitable material is insufficient.
- Vertical 1080×1920 H.264/AAC MP4, burned captions, and SRT sidecars.
- Speaker-aware framing for interviews; preserve screen content in tutorials when cropping would obscure the demonstration.
- Adjustable clip count, duration, topic instructions, caption styling, output location, and provider choices.
- Saved source library, transcripts, results, presets, and job history.

Apply `frontend-design` and `ui-ux-pro-max` during interface creation, translating their principles into native controls.

Create a dark editing workspace with a source sidebar, central batch queue/results, large preview, and contextual inspector. Use carbon black `#030706`, green `#39FF6A`, frost white `#F3FAF6`, amber `#F2B53A`, and the supplied supporting tones. Use clear typography, precise time displays, restrained glow, and motion tied to processing activity. Provide keyboard navigation, accessible labels, readable contrast, and reduced-motion support.

## 5. Validation and completion

- Test solo speech, multiple speakers, screen tutorials, silent sections, portrait footage, variable frame rates, 4K sources, and a two-hour recording.
- Exercise broken URLs, corrupt files, missing models, rejected keys, rate limits, budget exhaustion, malformed AI responses, cancellation, application restart, and insufficient disk space.
- Verify sentence boundaries, caption synchronization, speaker changes, tutorial readability, duplicate avoidance, preview/export agreement, and audio/video synchronization.
- Test provider contracts with deterministic fixtures and perform live checks for configured providers. Clearly identify integrations lacking live validation.
- Compare results against the investigation’s feature matrix. Every required feature must have an implementation and acceptance result; unresolved original behavior must have a documented replacement contract.

Delivery includes the runnable Mac app, reproducible build instructions, dependency/model notices, investigation reports, and validation results. Initial scope is personal use, local exports, and downloadable video URLs; public distribution, social posting, cloud-library integrations, and live-stream capture are outside this build.
