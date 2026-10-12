#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  echo 'Usage: scripts/build-app.sh [debug|release] [--universal] [--version X.Y.Z]' >&2
  exit 1
fi
build_arguments=(-c "$configuration")
shift || true
output_path=""
version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) build_arguments+=(--arch arm64 --arch x86_64); shift ;;
    --output) [[ $# -ge 2 ]] || exit 2; output_path="$2"; shift 2 ;;
    --version)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must look like 1.2.3' >&2; exit 2; }
      version="$2"; shift 2 ;;
    *) echo 'Unknown build option' >&2; exit 2 ;;
  esac
done
swift build "${build_arguments[@]}"
binary_path="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_path="$PWD/dist/LabRoute.app"
if [[ "$configuration" == debug ]]; then app_path="$PWD/dist/LabRoute Development.app"; fi
if [[ -n "$output_path" ]]; then app_path="$output_path"; fi
python3 - "$app_path" "$PWD/dist" <<'PY'
from pathlib import Path
import sys
target, root = (Path(value).resolve() for value in sys.argv[1:])
if root not in target.parents or target.suffix != '.app':
    raise SystemExit('Build output must be a generated .app below this repository\'s dist directory')
PY
# Only replace the generated build artifact, never an installed application.
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/LabRouteApp" "$binary_path/labroute" "$binary_path/LabRouteAskPass" "$app_path/Contents/MacOS/"
# Keep package resources in the standard app resource directory.
for bundle in "$binary_path"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$app_path/Contents/Resources/"
  fi
done
cp Sources/LabRouteCore/Resources/route-packs.json "$app_path/Contents/Resources/"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/"
if [[ -n "$version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app_path/Contents/Info.plist"
fi
if [[ "$configuration" == debug ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.labroute.development' "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName LabRoute Development' "$app_path/Contents/Info.plist"
fi
codesign --force --sign - "$app_path/Contents/MacOS/labroute"
codesign --force --sign - "$app_path/Contents/MacOS/LabRouteAskPass"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
echo "Built $app_path (ad-hoc signed, not notarized)"
