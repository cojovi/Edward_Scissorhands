# Cloth reconstruction research

This folder records evidence for an independently implemented Edward Scissorhands application. The target is the installed Cloth 0.1.0 build 12. Original binaries, credentials, branding, and media are not application dependencies.

The planned static/native investigation pass is complete within the bounds documented below. Evidence and a reusable query snapshot were saved, and the REA/Ghidra session was closed. Reconstruction validation is a separate requirement.

## Evidence status

- Every regular file under the supplied Cloth bundle has a SHA-256 record in `cloth-manifest.json`; the selected public bundle metadata is in `cloth-metadata.json`.
- Every path in the supplied REA checkout is classified in ignored `evidence/rea-tree.json`; `inventory-summary.json` records counts and the exact Git revision. Inventory coverage does not imply semantic review of all third-party dependencies or generated files.
- `sample-data-schemas.json` documents packaged demo/onboarding JSON shapes. They are examples, not an established production persistence specification.
- `feature-obligations.json` tracks the required user-visible behaviors and source confidence. It is an explicit human checklist, not a fabricated authenticated REA closure result.
- `runtime-observations.md`, when present, records the root agent's live UI observations. Disclosures in that UI are not network captures.
- Complete REA evidence and local analysis artifacts live in ignored `evidence/`. Reproducible scripts live in `tools/rea/`.
- [native-findings.md](native-findings.md) gives the readable native architecture, procedure/evidence anchors, 4,995-function decompilation coverage, and explicit limitations.
- [implementation-gap-audit.md](implementation-gap-audit.md) verifies that the reported integration issues were resolved in source and separates remaining runtime validation.
- [feature-implementation-map.md](feature-implementation-map.md) maps original behaviors to Edward files and specific test coverage, including intentional replacements.

## Current concrete contracts

Cloth's packaged example stores clip, line, and word start/end times in the original source timebase. Captions after sentence removal or pause cuts require a source-to-output time map. A word has text, start, end, and speaker; clips have title, bounds, transcript lines, and a rating. Do not assume the demo format is the complete live persistence model.

Static curation instructions require standalone complete thoughts with source transcript boundary timestamps. The result includes a project title, clip title, score, short label, and reason. Persistent and per-run instructions, requested clip count, and duration bounds are distinct inputs. Edward should validate output against these constraints independently of the selected AI provider.

Static disclosure strings identify Setapp-mediated ElevenLabs transcription and OpenAI GPT-5 mini selection. Root's runtime settings inspection corroborates the UI disclosure and specifically names ElevenLabs Scribe v2. Local speaker models are packaged. This investigation has not observed actual provider requests or purchased/consumed credits.

The main executable imports AVFoundation, VideoToolbox, Vision, CoreML, SwiftUI, and AppKit. The bundled FFmpeg notice describes a minimal networking/demux/mux build. Native function evidence now confirms AVFoundation audio preparation, Vision detection, 1080×1920 video composition, and Core Animation subtitle layers. FFmpeg's presence alone is not evidence that it performs rendering.

## Tools and reproducibility

`tools/rea/install_toolchain.py` downloads the explicitly approved official Ghidra 12.1.4 and Temurin JDK21 arm64 archives, verifies their published SHA-256 values, and extracts them into ignored `.tools/`. The Ghidra macOS arm64 decompiler was built from the matching included source using the REA-documented make overrides. No global MCP/client configuration is changed.

`tools/rea/inventory.py` reproduces the file inventory and metadata/schema projections. `tools/rea/session.mjs` runs the supplied REA checkout through a separate, project-scoped MCP connection with one persistent Ghidra session. Its queued requests and complete results are retained in `evidence/`. A thin arm64 analysis copy is required because REA 6.5.0 rejects universal Mach-O imports for Ghidra; `analysis-target.json` records its identity. The installed app is unchanged.

The completed session exported 106 native Evidence records and saved a matching REA query snapshot before closing. [REA-OPERATIONS.md](REA-OPERATIONS.md) records reproducibility, artifact hashes, and the disabled analyzer. `tools/rea/summarize_evidence.py` refreshes the compact provenance index without copying target pseudocode or literals into tracked reports.

## Completion boundary

The static pass accounts for the required subsystems, their evidence, and remaining uncertainty. Reconstruction acceptance additionally requires corresponding workflow validation. Hashing, strings, type names, or successful decompilation alone do not prove functional equivalence. Paid Cloth workflows lack replay evidence because the observed Setapp balance is zero. Edward's independent provider contracts can be tested without asserting unobserved original behavior; the final GUI/local-model run and application test results are owned by the root build.
