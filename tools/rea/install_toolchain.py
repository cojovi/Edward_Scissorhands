#!/usr/bin/env python3
"""Install the explicitly approved, project-local REA analysis prerequisites."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".tools"
ASSETS = [
    {
        "name": "ghidra_12.1.4_PUBLIC_20260921.zip",
        "url": "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip",
        "sha256": "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db",
        "expected_root": "ghidra_12.1.4_PUBLIC",
    },
    {
        "name": "OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz",
        "url": "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz",
        "sha256": "bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a",
        "expected_root": "jdk-21.0.13+9",
    },
]

def install(asset):
    archive = TOOLS / "downloads" / asset["name"]
    if not archive.exists():
        partial = archive.with_name(archive.name + ".part")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error", asset["url"], "--output", str(partial)], check=True)
        partial.rename(archive)
    with archive.open("rb") as stream:
        observed = hashlib.file_digest(stream, "sha256").hexdigest()
    if observed != asset["sha256"]:
        raise RuntimeError(f"Checksum mismatch for {archive.name}: {observed}")
    destination = TOOLS / asset["expected_root"]
    if not destination.exists():
        if archive.suffix == ".zip":
            # ditto preserves executable permissions shipped in the ZIP.
            subprocess.run(["ditto", "-x", "-k", str(archive), str(TOOLS)], check=True)
        else:
            subprocess.run(["tar", "-xzf", str(archive), "-C", str(TOOLS)], check=True)
    print(f"Verified and extracted {asset['name']}", flush=True)
    return {**asset, "observed_sha256": observed, "destination": str(destination)}

if __name__ == "__main__":
    (TOOLS / "downloads").mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(install, ASSETS))
    native = None
    if platform.system() == 'Darwin' and platform.machine() == 'arm64':
        ghidra = TOOLS / 'ghidra_12.1.4_PUBLIC'
        binary = ghidra / 'Ghidra/Features/Decompiler/os/mac_arm_64/decompile'
        build = ghidra / 'Ghidra/Features/Decompiler/src/decompile/cpp'
        if not binary.exists():
            log_path = ROOT / 'research/evidence/ghidra-native-build.log'
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open('w') as log:
                subprocess.run(['make', '-j6', 'ghidra_opt', 'ARCH_TYPE=-arch arm64', 'OSDIR=mac_arm_64'], cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True)
            binary.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['install', '-m', '755', str(build / 'ghidra_opt'), str(binary)], check=True)
        with binary.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        native = {'path': str(binary), 'sha256': digest, 'source': 'Matching Ghidra release source; make ghidra_opt ARCH_TYPE=-arch arm64 OSDIR=mac_arm_64'}
    (ROOT / "research" / "toolchain.json").write_text(json.dumps({"source": "official GitHub release assets and authenticated release API digests", "assets": results, 'native_decompiler': native}, indent=2) + "\n")
