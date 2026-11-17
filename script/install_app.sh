#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_bundle="$project_dir/dist/Edward Scissorhands.app"
installed_bundle="/Applications/Edward Scissorhands.app"
bundle_id="com.edwardscissorhands.studio"

# New builds keep the app-named staging path as a link to a non-app package.
# Only accept the exact project-owned links; never install an arbitrary target.
if [ -L "$source_bundle" ]; then
  [ -L "$project_dir/dist" ] && [ "$(readlink "$project_dir/dist")" = '.build/edward-staging.noindex' ] && \
    [ "$(readlink "$source_bundle")" = 'Edward Scissorhands.staging' ] || {
      echo "Refusing an unexpected staging symlink." >&2; exit 1;
    }
  source_bundle="$project_dir/.build/edward-staging.noindex/Edward Scissorhands.staging"
fi

check_bundle() {
  local candidate="$1"
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || { echo "Expected a real app bundle: $candidate" >&2; return 1; }
  [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")" = "$bundle_id" ] || {
    echo "Refusing to replace or install a different application: $candidate" >&2; return 1;
  }
  /usr/bin/codesign --verify --deep --strict "$candidate"
}

check_bundle "$source_bundle"
if [ -e "$installed_bundle" ] || [ -L "$installed_bundle" ]; then check_bundle "$installed_bundle"; fi
if /usr/bin/pgrep -x EdwardScissorhands >/dev/null || /usr/bin/pgrep -x EdwardMediaWorker >/dev/null; then
  echo "Finish active batches and quit Edward Scissorhands before installing an update." >&2
  exit 1
fi

# Copy and verify on the destination volume before replacing the installed bundle.
install_stage="$(/usr/bin/mktemp -d /Applications/.edward-install.XXXXXX)"
cleanup() {
  local result=$?
  if [ -d "$install_stage/previous.app" ] && [ ! -e "$installed_bundle" ]; then
    if ! /bin/mv "$install_stage/previous.app" "$installed_bundle"; then
      echo "Previous app retained for recovery at $install_stage/previous.app" >&2
      exit 1
    fi
  fi
  /bin/rm -rf "$install_stage"
  exit "$result"
}
trap cleanup EXIT
/usr/bin/ditto "$source_bundle" "$install_stage/Edward Scissorhands.app"
check_bundle "$install_stage/Edward Scissorhands.app"
if [ -d "$installed_bundle" ]; then /bin/mv "$installed_bundle" "$install_stage/previous.app"; fi
/bin/mv "$install_stage/Edward Scissorhands.app" "$installed_bundle"
echo "Installed: $installed_bundle"
