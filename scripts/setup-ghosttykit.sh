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

REQUIRED_ZIG="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$GHOSTTY/build.zig.zon" | head -n1 | tr -d '"')"
if [ -z "$REQUIRED_ZIG" ]; then REQUIRED_ZIG="0.15.2"; fi

if ! command -v zig >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: zig is not on PATH.

GhosttyKit needs zig $REQUIRED_ZIG specifically (ghostty pins it in
build.zig.zon). Homebrew's \`zig\` formula tracks the latest release and
will be wrong — download $REQUIRED_ZIG from https://ziglang.org/download/
and put it on PATH, or use a version manager:

  mise use zig@$REQUIRED_ZIG
  asdf install zig $REQUIRED_ZIG && asdf local zig $REQUIRED_ZIG
EOF
  exit 1
fi

CURRENT_ZIG="$(zig version)"
if [ "$CURRENT_ZIG" != "$REQUIRED_ZIG" ]; then
  cat >&2 <<EOF
WARNING: zig $CURRENT_ZIG is on PATH but ghostty wants $REQUIRED_ZIG.
The build will likely fail. Install the exact version:
  https://ziglang.org/download/
Continuing anyway in case ghostty has loosened the requirement…
EOF
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
