#!/usr/bin/env bash
# Build GhosttyKit.xcframework from the pinned ghostty submodule and install
# it into Vendor/. This script is idempotent — it short-circuits when the
# framework already exists and matches the current submodule SHA.
#
# Requires: git, zig (>=0.13). On macOS: `brew install zig`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/ghostty"
VENDOR="$ROOT/Vendor"
TARGET="$VENDOR/GhosttyKit.xcframework"
MARKER="$VENDOR/.ghosttykit-sha"

if [ ! -d "$GHOSTTY/.git" ] && [ ! -f "$GHOSTTY/.git" ]; then
  cat >&2 <<EOF
ERROR: ghostty submodule is missing.

Initialize it first:
  git submodule update --init --recursive
EOF
  exit 1
fi

GHOSTTY_SHA="$(git -C "$GHOSTTY" rev-parse HEAD)"
GHOSTTY_TAG="$(git -C "$GHOSTTY" describe --tags --exact-match 2>/dev/null || echo "$GHOSTTY_SHA")"

# Fast path: framework present and built against the current submodule SHA.
if [ -d "$TARGET" ] && [ -f "$TARGET/Info.plist" ] && [ -f "$MARKER" ]; then
  if [ "$(cat "$MARKER")" = "$GHOSTTY_SHA" ]; then
    echo "GhosttyKit.xcframework up to date (ghostty $GHOSTTY_TAG)."
    exit 0
  fi
  echo "Vendor SHA mismatch — rebuilding for ghostty $GHOSTTY_TAG."
fi

if ! command -v zig >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: zig is not on PATH.

GhosttyKit is built from source via:
  zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast

Install zig and retry:
  brew install zig          # macOS
  # or download from https://ziglang.org/download/
EOF
  exit 1
fi

echo "Building GhosttyKit from ghostty $GHOSTTY_TAG (this can take 10-20 min on a cold cache)…"
(
  cd "$GHOSTTY"
  zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Doptimize=ReleaseFast
)

BUILT="$GHOSTTY/macos/GhosttyKit.xcframework"
if [ ! -d "$BUILT" ]; then
  # Older ghostty versions emit into zig-out/.
  BUILT="$GHOSTTY/zig-out/GhosttyKit.xcframework"
fi
if [ ! -d "$BUILT" ]; then
  echo "ERROR: zig build finished but GhosttyKit.xcframework was not produced." >&2
  find "$GHOSTTY" -maxdepth 4 -name 'GhosttyKit.xcframework' -type d >&2 || true
  exit 1
fi

mkdir -p "$VENDOR"
rm -rf "$TARGET"
cp -R "$BUILT" "$TARGET"
echo "$GHOSTTY_SHA" > "$MARKER"

echo "Installed GhosttyKit.xcframework (ghostty $GHOSTTY_TAG) at $TARGET"
