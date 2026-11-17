# Edward Scissorhands

A native, personal macOS studio for turning long-form video into short clips. Uses your own AI connections and local speech models. **No Setapp integration, account, or credits are required.**

## Run

Requires an Apple Silicon Mac, macOS 14+, and Xcode's Swift toolchain to build. This checkout was built and tested on macOS 27.0.1 with Xcode 27.1.

```sh
./script/build_and_run.sh
```

The canonical app is `/Applications/Edward Scissorhands.app`. This script and the Codex **Run** action build, install or update that copy, and launch it. `dist/Edward Scissorhands.app` is a link to generated staging output in an unindexed build folder, so macOS does not show it as a second app.

`--build-only` also installs or updates the canonical app but does not launch it; `--verify` checks launch; `--debug`, `--logs`, and `--telemetry` support debugging. To install an already packaged `dist` bundle without rebuilding:

```sh
./script/install_app.sh
```

Let active batches finish before relaunching. Updates preserve Application Support data, Keychain credentials, original media and exports. App changes are delivered only after the installed copy has been refreshed and checked.

The build downloads checksum-pinned yt-dlp and QuickJS from their official releases. Swift dependencies are locked by `Package.resolved`.

The shared app artwork lives in `Sources/EdwardApp/Resources/EdwardLogo.png`. The build generates the macOS app icon from that image, including a modern icon catalog with Xcode 26 or later; the sidebar, welcome screen and clip placeholders use the same artwork.

## First batch

1. Open **AI connections**. Select OpenAI, Anthropic, Gemini, a compatible endpoint, or Ollama. Choose a model and save a key in Keychain where required; local Ollama needs no key. **Test connection & list models** performs discovery, not paid inference. Add separate profiles to use different models or keys for different stages.
2. Select a local transcription engine: FluidAudio or WhisperKit. Models download on first use and are cached locally. You can alternatively import a timed JSON/SRT transcript from a source's context menu.
3. For paid providers, enter token rates from your account and set a per-source estimated budget. Unknown-cost processing is disabled by default and requires explicit confirmation when enabled. Provider billing is authoritative.
4. Add videos or supported downloadable URLs. Choose a preset, clip count, duration, topic and framing. Tutorials should use **Preserve content**.
5. Start the batch. Video processing remains local. Editorial cloud analysis receives transcripts; optional visual analysis receives selected frames and transcript context, as disclosed in the batch review.

Default output: up to five 30–90 second vertical H.264/AAC MP4 clips, burned captions and SRT sidecars. Exports are placed under `~/Movies/Edward Scissorhands` unless changed. Files that do not provide enough suitable moments produce fewer clips.

## Edit and recover

- Disable automatic export to review and select candidate clips first.
- Click a clip to preview, trim, exclude sentences, correct words, assign/swap speakers, and adjust captions/framing. Local edits reuse AI results and create new export revisions.
- Right-click a source to read/copy/save its transcript, rename, rerun, reveal exports, or remove its library record. Removing a record retains original media and exports.
- Pause stops at a stage boundary. Cancel interrupts the current operation. Completed stage results survive restart.
- AI analysis saves each completed part. For Gemini 3.7/3.8 Flash, Edward uses a larger output allowance and low thinking; a confirmed output-limit result can be retried once with a larger allowance. A retry can be billed and respects the configured estimated budget; no ceiling can be enforced when unknown-cost processing is allowed.
- If a failed AI stage needs another connection, select it in **AI connections**, then right-click the source and choose **Resume with current AI connections…**. The saved transcript and original source preset are kept; changing providers may require new paid analysis.
- Each project has two private, independent recovery checkpoints under its `Projects/<id>/Recovery` folder. If an individual library record becomes unreadable, Edward tries those copies. They contain project/transcript metadata, not the original media or Keychain; a whole-library or machine backup is still separate.
- A cloud request interrupted before its outcome is known is not blindly repeated. **Resolve** asks you to check provider usage before acknowledging a possible additional charge.
- AI credentials live in macOS Keychain. Projects, checkpoints and private caches live in `~/Library/Application Support/Edward Scissorhands`. Do not publish that directory. Diagnostics intentionally omit keys, links, prompts, transcripts and server responses.

## Architecture

`EdwardDomain` defines source-time transcript/edit/render contracts. `EdwardMedia` handles native AVFoundation/Vision processing and an isolated local speech worker. `EdwardProviders` contains capability-aware adapters and durable request journals. `EdwardPersistence` stores transactional SQLite checkpoints. `EdwardJobs` orchestrates resumable processing. `EdwardApp` contains the original SwiftUI interface.

Preview and export share one native composition. Captions and edits map absolute source timestamps into the final timeline. Mouth-motion/speaker association is a heuristic; ambiguous multi-face scenes preserve the full frame instead of choosing an arbitrary speaker.

Ollama supports downloaded local models. Cloud model tags and remote aliases are rejected before inference. Compatible loopback endpoints are also available, but their own servers may forward requests elsewhere; configure their keys and prices as needed.

## Validation and investigation

```sh
swift test
```

Local speech and larger media checks are opt-in; see `docs/MEDIA.md`. Tests use generated media and mock provider responses for reproducible queue behavior. Real paid inference is not exercised without user-configured credentials.

- `research/README.md`: Cloth investigation, evidence boundaries and reconstruction findings.
- `research/runtime-observations.md`: controls observed directly in Cloth.
- `docs/VALIDATION.md`: executed checks and limitations.
- `docs/MEDIA.md` and `THIRD_PARTY_MEDIA.md`: media dependencies, models and licensing.

The application is an independent implementation. Cloth's proprietary executable, branding, icons and sample media are not included in the app. Remote Cloth/Setapp implementation remains outside the observable evidence boundary.
