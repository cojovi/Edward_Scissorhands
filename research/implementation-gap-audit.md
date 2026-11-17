# Reconstruction source audit

Final source verification on 2026-10-29 confirms that the integration issues below have been addressed. This document distinguishes inspected implementation from executed test results. The root build owns the final test and GUI-run records.

## Main workflow

The independent app represents local/link ingestion, local word-timed transcription, direct AI provider selection, automated/manual clip selection, sentence editing, speaker assignment/swap, caption and framing previews, local export, a per-run library, preset persistence, transcript copy/save, diagnostics, and completion preferences. No additional absent high-level processing stage was found in this source review.

The [feature-to-implementation map](feature-implementation-map.md) links the original behaviors to Edward source files and specific tests. Source presence does not mean every path was executed.

## Resolved integration findings

| Finding | Verified implementation | Validation reference |
|---|---|---|
| Disabling speaker recognition still ran diarization. | `JobCoordinator` now passes the configured `recognizeSpeakers` value through `MediaEngine` and the worker; `LocalTranscriber` returns before diarization when false. | Verified call chain in source. |
| A recoverable diarizer failure discarded successful transcription. | `LocalTranscriber.attachSpeakers` retains words and adds an unavailable-speaker annotation on failure; cancellation still throws. | `MediaTranscriptionTests.testDiarizationFailureRetainsSuccessfulTranscript` and `testDiarizationCancellationIsNotSilentlySwallowed`. |
| Sentence editing could lose tightened pieces or change selection identity after word/speaker corrections. | `ClipEditorView` includes overlapping sentences, intersects retained sentences with original piece ranges, and keeps original sentence IDs/bounds while refreshing their words. | Source verified; `MediaTimelineTests.testDiscontiguousEditsMapWordsAndSourceClock` covers the downstream time map. The SwiftUI editor's exact interactions remain a GUI validation responsibility. |
| Symmetric caption margins did not allow for right-side controls. | Portrait `CaptionPainter` now reserves asymmetric leading/trailing margins and protects top/bottom caption padding. | Source verified; `MediaRenderTests.testNativeRenderRecutsAudioVideoAndCaptions` covers rendering. A current-platform overlay comparison is still separate visual validation. |
| Library rename, source-link operations, and readable transcript lacked UI entry points. | `WorkspaceView` has rename, read/copy/save transcript, and copy/open source-link actions; `TranscriptSheet` presents selectable sentence text and speaker labels. | Source verified; persistence and queue tests cover underlying saved records. Root owns GUI action verification. |
| Manual review could not choose individual candidates. | `WorkspaceView` has per-clip inclusion and a selected-count render action; `JobCoordinator.approve` validates a nonempty subset. | `JobIntegrationTests.testManualReviewRequiresValidSelectionAndExportsOnlyApprovedClip`. |

## Intentional differences

- Edward preserves the full source frame when face/speaker association is ambiguous. It does not reproduce Cloth's body/pose/object/hand fallback. This is an intentional choice to preserve tutorial and screen content, not a missing editing stage.
- Local FluidAudio/WhisperKit speech recognition and direct provider adapters replace Setapp-mediated paid transcription/selection. New models must satisfy actual stage capabilities; a general chat model is not automatically a word-timed transcription engine.
- Edward's provider validation uses known transcript segment IDs and a source/output time map. It does not depend on accepting arbitrary timestamps from a model.

## Remaining validation boundary

Actual paid-provider interactions were not exercised by this research agent. Native tests include synthetic long/VFR/rotated/4K/silent/corrupt media, interruption recovery, local speech inference, and opt-in research footage. Their presence is not a blanket claim that every gated test ran. Root is performing the actual local Ollama/FluidAudio GUI batch; its result belongs in the final build validation record.

Difficult real multi-speaker/offscreen content, subjective clip quality, current platform overlays, and provider-specific live billing still need bounded evidence. Original paid Cloth runs remain unavailable, so passing Edward tests does not establish verified original behavior equivalence.

The inspected built app's `Contents/Resources` contained no video or audio sample files. Optional Cloth research tests refer to the installed external bundle and write only ignored test artifacts; those samples are not app resources or distributable dependencies.
