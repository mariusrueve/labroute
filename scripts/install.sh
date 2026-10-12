#!/bin/bash
# Build a release LabRoute.app and install it into ~/Applications (no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
target="$HOME/Applications/LabRoute.app"
if pgrep -f "$target/Contents/MacOS/LabRouteApp" >/dev/null; then
  echo "LabRoute is running. Choose Disconnect and Quit from its menu, then run this again." >&2
  exit 1
fi
bash scripts/build-app.sh release
mkdir -p "$HOME/Applications"
rm -rf "$target"
ditto dist/LabRoute.app "$target"
echo "Installed $target"
echo "Open it with: open \"$target\""
