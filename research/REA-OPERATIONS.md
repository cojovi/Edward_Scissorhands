# Reproducing or extending the investigation

All commands run from the project root. Original target files are read-only inputs. Tool installations, downloaded archives, thin binary copies, native pseudocode, query queues, and complete Evidence are ignored local artifacts.

```sh
python3 tools/rea/install_toolchain.py
python3 tools/rea/inventory.py
python3 tools/rea/swift_metadata.py
python3 tools/rea/summarize_evidence.py
```

The installer checks the approved official archive SHA-256 values recorded in [toolchain.json](toolchain.json). Ghidra's included decompiler source needed a local macOS arm64 build with `make -j6 ghidra_opt ARCH_TYPE='-arch arm64' OSDIR=mac_arm_64`. The installer includes this step when the matching native binary is absent. It does not change a global Java installation, shell profile, or MCP client configuration.

`tools/rea/session.mjs` starts the supplied `/Volumes/FastSSD/github/clones/rea` MCP server through that checkout's own SDK dependency, with a project-scoped `JAVA_HOME`, `GHIDRA_INSTALL_DIR`, heap, provider, and analyzer profile. It consumes named `.request.json` files in `research/evidence/queue/` and retains corresponding complete responses. Completed requests are renamed `.done.json`; they are not automatically replayed. The executed request sequence remains available there.

The session was closed after successful Evidence export and snapshot save. To extend analysis, start a fresh session, create a new open request for the hashed thin target, and import the saved snapshot if desired. `open_binary` accepts an absolute `snapshot_path`. Do not copy or reuse old evidence IDs for new bytes or changed analysis settings. Eligible exact queries can be served from the snapshot; new native questions may still require Ghidra startup.

The universal binary was thinned with `lipo` to `research/evidence/Cloth.arm64`. Its SHA-256 is `a9bd174f25fd6cae2dddf9110f45a048f93aab60f1baac015e9a3db10a978065`. No app executable was patched or launched by this static investigation.

The final profile sets `REA_GHIDRA_DISABLED_ANALYZERS='Objective-C Message Analyzer'`. The default analyzer stalled inside recursive Objective-C message resolution; `evidence/ghidra-default-analysis.log` and `evidence/ghidra-threads.txt` retain the diagnosis. This omission is part of the evidence profile and must remain visible in any report. The reduced analysis completed in approximately 310 seconds.

| Retained artifact | Size | SHA-256 |
|---|---:|---|
| `evidence/native-evidence-bundle.json` | 54,779,989 bytes | `3177f08d5f2d49a00f76278adac80351b502f47ef8b697ae885b11e4d434b80c` |
| `evidence/native-analysis-snapshot.json` | 105,095,023 bytes | `7a3217536173717ec2b59cc45a5d0fa38ec499606e78bf29488930d3e3f8fe4e` |

The snapshot has 13 primitive entries, 54 workflow entries, and 106 Evidence records. The native export has 106 records. The compact index also includes separate command-line artifact inspections, so its count differs. Snapshots are cached observations, not a saved Ghidra database or recovered source. Never treat empty formal-unknown records as proof of comprehensive behavior closure.

Selected bundle metadata is allowlisted. Hash manifests contain paths and digests, not file payloads. Tracked reports contain structural facts and short technical identifiers; full binary literals and pseudocode remain ignored. Do not publish raw research artifacts without reviewing them separately, and do not use proprietary app resources or embedded service identity in the independent build.
