# Recovered behavior and data contracts

The following combines packaged data, Swift reflection metadata, static string literals, and the separately recorded live UI observations. Names and fields are source-bound static facts; algorithms and execution are established only where explicitly stated. Do not copy the original implementation or its service credentials into Edward.

## Processing flow

The declared `JobStage` cases are `idle`, `fetching`, `extractingAudio`, `transcribing`, `curating`, `awaitingSelection`, `rendering`, `finished`, and `failed`. `Pipeline` retains progress, transcript, candidates, speaker seats/portraits, source and curated titles, selected options, pending render data, workspaces, and video-fetch state. This establishes represented state, not every allowed state transition.

Source is a `file` or `link`. Job options separately represent mode (`auto`/`manual`), count, minimum and maximum clip duration, burned subtitles, speaker colors, speaker recognition, pause tightening, caption placement, quality, standing instruction, run instruction, and output directory. The original UI corroborates these controls.

Audio chunk records contain `file`, `offset`, and `keep`. Native function `0x10033cba4` checks cancellation/error cases before a branch logging newer-endpoint failure and older-endpoint chunked fallback. Exact chunk sizes/overlap and retry policy remain unresolved. New providers should use their own validated limits.

## Transcript and curation

`Word` has text/start/end/speaker; `Transcript` has words/segments/language/duration; `TranscriptSegment` has start/end/text/speaker. Packaged examples use source-time seconds for clips, lines, and words. Edited output must translate source ranges into output positions, rather than subtracting one initial offset after discontinuous cuts.

`ClipCandidate` has ID/start/end/title/score/label/reason/onRequest. The embedded curation instructions choose complete thoughts, use exact transcript boundary timestamps, and produce a short source-language project title. The original prompt is retained only as research evidence; Edward should express its own provider-independent selection contract and validate proposed ranges.

`OpenAICompatibleCuration` represents endpoint, model, session, candidate count, and transport. Its endpoint includes name/baseURL/API-key/extra-headers/routed fields; the selection envelope has project title and segments. This is evidence of an abstraction in the shipped app, not evidence that the Setapp UI exposes arbitrary providers.

`CurationMemo.Key` includes source, words, speech end, speakers, count, duration limits, standing instruction, and run instruction. Logs explicitly describe reuse for identical transcript/settings. Edward must additionally include its provider/model, selected visual mode, and schema version where those affect its results.

## Editing, speaker framing, and captions

Live UI observations confirm sentence inclusion, per-sentence speaker reassignment, and swapping speakers. `ClipSpec` stores ordered `Piece` ranges. Persisted clips also contain `pieces`, `dropped`, and `tightened`, establishing that a clip can represent discontinuous source intervals and edit history.

Speaker framing represents seats (`speaker`, `x`, `votes`, `rival`), corrections (`at`, `speaker`), turns (`speaker`, `start`, `end`), crop placements (`from`, `duration`, `at`), and crop moves (`at`, `focusX`, `ramped`). Static logs describe object/hand fallback when people are absent and a warning when multiple subjects cannot fit a portrait window. Exact thresholds and smoothing are not established by names alone.

`SubtitleBuilder.Cue` has start/end/words. `SubtitleLayer.Style` contains font, text/highlight/stroke/shadow, karaoke, speaker palette/lookup, and placement. `SubtitleBuilder.SafeArea.Chrome` represents platform/top/bottom/leading/trailing/crop/measured/source. UI confirms top/bottom/off and optional speaker color. [caption-safearea-facts.json](caption-safearea-facts.json) records recovered per-platform constants. Native aggregation combines maxima across the three tables, supporting conservative shared placement rather than requiring a platform-picker UI.

`Cloth.YtDlp.Quality` represents standard/sharp/maximum. Function `0x10038c07c` changes source-acquisition codec/format preferences. Native video composition uses 1080×1920 geometry and Core Animation caption layers. Do not assume the quality control necessarily changes export resolution.

## Persistence and failure handling

`JobRecord` represents ID/title/date/source duration/clips/full transcript/speaker seats/corrections/source/run instruction. A stored clip has ID/title/path/source bounds/lines/pieces/dropped/rating/tightened. Its line records retain text, bounds, and words. Root observed rename/re-run/reveal/delete, full transcript copy/save, and source-link operations.

`TranscriptCache.Stored` represents words/language/duration. `JobStore` has a file URL and a title-migration marker. These do not yet establish storage path, serialization atomicity, or migration algorithm.

`ClothError` cases represent missing API key, transcription/curation/media/download failures, too-short video, nothing fitting duration, empty transcript, no segments, and cancellation. `ExportGate.State` represents waiting/exporting/cancelled with a lock; `Recut.Stage` represents idle/fetching/rendering/done/failed. Original failure wording and code do not substitute for testing Edward's job cancellation and recovery.

## Coverage boundary

The observed original account has no remaining Setapp credits. No fresh paid run or actual AI/network request was performed. Quality names and controls are observed; rendered quality, exact AI choices, and recovery under real provider failure are unverified. Broad FluidAudio/Setapp SDK symbols include capabilities unrelated to Cloth; they are not app feature claims. The Ghidra default Objective-C message analyzer stalled and was disabled in the explicitly recorded analysis profile; missing dynamic dispatch facts remain unknown.
