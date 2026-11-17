#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tool_dir="$project_dir/.tools"
mkdir -p "$tool_dir"
if [ "$(uname -m)" != "arm64" ]; then
  echo 'This dependency bundle targets Apple Silicon.' >&2
  exit 1
fi
fetch_checked() {
  local name="$1" url="$2" expected="$3"
  if [ -f "$tool_dir/$name" ] && [ "$(shasum -a 256 "$tool_dir/$name" | cut -d ' ' -f 1)" = "$expected" ]; then
    chmod +x "$tool_dir/$name"
    return
  fi
  local temporary="$tool_dir/$name.download"
  curl --fail --location --retry 3 "$url" --output "$temporary"
  local actual
  actual="$(shasum -a 256 "$temporary" | cut -d ' ' -f 1)"
  if [ "$actual" != "$expected" ]; then
    rm -f "$temporary"
    echo "Checksum mismatch for $name" >&2
    exit 1
  fi
  chmod +x "$temporary"
  mv "$temporary" "$tool_dir/$name"
}
fetch_checked yt-dlp 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos' '0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa'
fetch_checked qjs 'https://github.com/quickjs-ng/quickjs/releases/download/v0.17.0/qjs-darwin-arm64' '8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11'
echo 'Verified yt-dlp 2026.10.26 and QuickJS-NG 0.17.0 in .tools.'
