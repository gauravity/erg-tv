#!/bin/bash
set -euo pipefail

if (( $# > 1 )); then
  printf 'Usage: %s [output-directory]\n' "$0" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="${1:-$project_dir/outputs}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
destination="$output_dir/Ride Screen.app"
lock_dir="$output_dir/.ride-screen-build.lock"

if ! mkdir "$lock_dir"; then
  printf 'Could not lock the output directory for packaging: %s\n' "$output_dir" >&2
  exit 1
fi

staging_dir=''
backup=''
cleanup() {
  if [[ -n "$backup" && -d "$backup" && ! -e "$destination" && ! -L "$destination" ]]; then
    if ! mv "$backup" "$destination"; then
      printf 'The previous app is still available at %s\n' "$backup" >&2
      rmdir "$lock_dir"
      return
    fi
  fi
  if [[ -n "$staging_dir" ]]; then
    rm -rf "$staging_dir"
  fi
  rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [[ -e "$destination" || -L "$destination" ]]; then
  if [[ ! -d "$destination" || -L "$destination" || ! -f "$destination/Contents/Resources/.ride-screen-build" ]]; then
    printf 'An existing item blocks the app destination: %s\n' "$destination" >&2
    exit 1
  fi
fi

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
swift_options=(--configuration release --cache-path "$project_dir/.build/cache" --manifest-cache local -debug-info-format none)
# Set this in a managed environment that already sandboxes the build.
if [[ "${RIDE_SCREEN_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
  swift_options+=(--disable-sandbox)
fi
swift build "${swift_options[@]}" --product RideScreen
bin_dir="$(swift build "${swift_options[@]}" --show-bin-path)"

staging_dir="$(mktemp -d "$output_dir/.ride-screen.XXXXXXXX")"
staged_app="$staging_dir/Ride Screen.app"
contents="$staged_app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 755 "$bin_dir/RideScreen" "$contents/MacOS/RideScreen"
install -m 644 "$project_dir/Packaging/Info.plist" "$contents/Info.plist"
touch "$contents/Resources/.ride-screen-build"

for bundle in "$bin_dir"/RideScreen_*.bundle; do
  if [[ -d "$bundle" ]]; then
    ditto "$bundle" "$contents/Resources/${bundle##*/}"
  fi
done

plutil -lint "$contents/Info.plist"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -d "$destination" ]]; then
  backup="$staging_dir/Previous Ride Screen.app"
  mv "$destination" "$backup"
fi
mv "$staged_app" "$destination"
printf 'Built %s\n' "$destination"
