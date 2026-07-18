#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:?usage: verify-ghostty-resources.sh /path/to/Glint.app}"
RESOURCES="$APP_PATH/Contents/Resources"

EXPECTED_GHOSTTY_SHA="$(cat "$ROOT/GhosttyResources/.ghostty-sha")"
ACTUAL_GHOSTTY_SHA="$(git -C "$ROOT" rev-parse :ghostty)"
if [ "$EXPECTED_GHOSTTY_SHA" != "$ACTUAL_GHOSTTY_SHA" ]; then
  echo "ERROR: bundled Ghostty resources do not match the pinned submodule." >&2
  echo "  resources: $EXPECTED_GHOSTTY_SHA" >&2
  echo "  submodule: $ACTUAL_GHOSTTY_SHA" >&2
  exit 1
fi

required_files=(
  "$RESOURCES/terminfo/67/ghostty"
  "$RESOURCES/terminfo/78/xterm-ghostty"
  "$RESOURCES/ghostty/shell-integration/bash/ghostty.bash"
  "$RESOURCES/ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
  "$RESOURCES/ghostty/shell-integration/zsh/ghostty-integration"
)

for file in "${required_files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "ERROR: missing bundled Ghostty resource: $file" >&2
    exit 1
  fi
done

echo "Verified bundled Ghostty shell integration and terminfo resources."
