#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mode="${1:-run}"
app_name="EdwardScissorhands"
app_bundle="$project_dir/dist/Edward Scissorhands.app"
installed_bundle="/Applications/Edward Scissorhands.app"
contents="$app_bundle/Contents"

case "$mode" in run|--verify|--build-only|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2;; esac
./scripts/media-tools.sh
swift build --product EdwardScissorhands
swift build --product EdwardMediaWorker
binary_dir="$(swift build --show-bin-path)"
mkdir -p "$contents/MacOS" "$contents/Resources/bin"
mkdir -p "$contents/Resources/Licenses"
chmod -R u+w "$contents/Resources/Licenses"
cp -R licenses/. "$contents/Resources/Licenses/"
cp THIRD_PARTY_MEDIA.md "$contents/Resources/ThirdPartyNotices.md"
cp "$binary_dir/EdwardScissorhands" "$contents/MacOS/EdwardScissorhands"
cp "$binary_dir/EdwardMediaWorker" "$contents/Resources/bin/EdwardMediaWorker"
cp .tools/yt-dlp .tools/qjs "$contents/Resources/bin/"
for resource in "$binary_dir"/*.bundle; do
  [ -d "$resource" ] || continue
  cp -R "$resource" "$contents/Resources/"
  # The isolated command-line worker resolves resources relative to its executable.
  cp -R "$resource" "$contents/Resources/bin/"
done
if [ ! -f "$contents/Resources/AppIcon.icns" ]; then
  swift script/make_icon.swift "$project_dir/.build/Edward.iconset"
  iconutil -c icns "$project_dir/.build/Edward.iconset" -o "$contents/Resources/AppIcon.icns"
fi
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EdwardScissorhands</string>
<key>CFBundleIdentifier</key><string>com.edwardscissorhands.studio</string>
<key>CFBundleName</key><string>Edward Scissorhands</string>
<key>CFBundleDisplayName</key><string>Edward Scissorhands</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Edward Scissorhands — Personal Studio</string>
</dict></plist>
PLIST
chmod +x "$contents/MacOS/EdwardScissorhands" "$contents/Resources/bin/EdwardMediaWorker"
codesign --force --sign - "$contents/Resources/bin/EdwardMediaWorker"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
# Never stop a speech worker in the middle of a batch just to install a build.
if pgrep -x EdwardMediaWorker >/dev/null; then
  echo "Build ready. Finish the active batch, quit Edward, then run ./script/install_app.sh." >&2
  exit 1
fi
pkill -x "$app_name" 2>/dev/null || true
for attempt in {1..30}; do
  if ! pgrep -x "$app_name" >/dev/null; then break; fi
  sleep 0.1
done
./script/install_app.sh
case "$mode" in
  --build-only) echo "Built and installed: $installed_bundle" ;;
  --debug) lldb -- "$installed_bundle/Contents/MacOS/EdwardScissorhands" ;;
  --logs) open -n "$installed_bundle"; /usr/bin/log stream --info --style compact --predicate 'process == "EdwardScissorhands"' ;;
  --telemetry) open -n "$installed_bundle"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.edwardscissorhands.studio"' ;;
  --verify) open -n "$installed_bundle"; sleep 2; pgrep -x EdwardScissorhands >/dev/null; echo "Edward Scissorhands launched from $installed_bundle." ;;
  run) open -n "$installed_bundle" ;;
esac
