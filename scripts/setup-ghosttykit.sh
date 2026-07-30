#!/usr/bin/env bash
# Install GhosttyKit.xcframework into Vendor/ by downloading the prebuilt
# artifact that corresponds to the current ghostty submodule SHA.
#
# Why download instead of `zig build`? Two reasons:
#   1. ghostty pins minimum_zig_version to 0.15.2; that toolchain does not
#      link cleanly against the macOS 26 (Tahoe) SDK shipped on current
#      GitHub `macos-26` runners — libc symbols come up undefined.
#   2. ghostty's own DockTilePlugin Swift target fails on the Xcode 16.4
#      bundled with `macos-15` runners.
# Building locally on developer machines hits the same toolchain matrix.
# We side-step both problems by publishing a known-good xcframework from
# someone's working machine and consuming it everywhere.
#
# Resolution flow:
#   * Read the current ghostty submodule HEAD SHA.
#   * Look it up in scripts/ghosttykit-checksums.txt → release tag + sha256.
#   * Download the tar.gz from this repo's GitHub Releases, verify sha256,
#     unpack into Vendor/.
#   * Cache the build by writing Vendor/.ghosttykit-sha; subsequent runs
#     short-circuit when the marker already matches the submodule SHA.
#
# To publish a new framework (after bumping the ghostty submodule), run
# scripts/build-ghosttykit.sh — it pins the right zig and works around the
# toolchain quirks above — then scripts/publish-ghosttykit.sh to upload the
# result to releases and append a line to the registry.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/ghostty"
VENDOR="$ROOT/Vendor"
FRAMEWORK="$VENDOR/GhosttyKit.xcframework"
MARKER="$VENDOR/.ghosttykit-sha"
REGISTRY="$ROOT/scripts/ghosttykit-checksums.txt"
REPO="${GHOSTTYKIT_RELEASE_REPO:-chenbstack/glint}"

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

# Fast path: framework present and the marker matches the submodule.
if [ -d "$FRAMEWORK" ] && [ -f "$FRAMEWORK/Info.plist" ] && [ -f "$MARKER" ]; then
  if [ "$(cat "$MARKER")" = "$GHOSTTY_SHA" ]; then
    echo "GhosttyKit.xcframework up to date (ghostty $GHOSTTY_TAG)."
    exit 0
  fi
  echo "Vendor SHA mismatch — re-downloading for ghostty $GHOSTTY_TAG."
fi

if [ ! -f "$REGISTRY" ]; then
  echo "ERROR: $REGISTRY is missing — can't resolve a prebuilt." >&2
  exit 1
fi

# Look up the SHA → (sha256, tag). Strip comments and blank lines first.
ENTRY="$(grep -v '^[[:space:]]*#' "$REGISTRY" | awk -v sha="$GHOSTTY_SHA" '$1 == sha {print; exit}')"
if [ -z "$ENTRY" ]; then
  cat >&2 <<EOF
ERROR: no prebuilt GhosttyKit listed for ghostty $GHOSTTY_SHA.

Either:
  * roll the submodule back to a SHA listed in scripts/ghosttykit-checksums.txt, or
  * build and publish a fresh prebuilt (requires full Xcode):
      scripts/build-ghosttykit.sh && scripts/publish-ghosttykit.sh
EOF
  exit 1
fi

EXPECTED_SHA256="$(printf '%s' "$ENTRY" | awk '{print $2}')"
TAG="$(printf '%s' "$ENTRY" | awk '{print $3}')"
# Asset filename mirrors the release tag, e.g. xcframework-332b2ae-v1 → GhosttyKit-332b2ae-v1.tar.gz
ASSET="GhosttyKit-${TAG#xcframework-}.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading GhosttyKit from $URL"
if ! curl -fSL --retry 3 --retry-delay 2 -o "$TMPDIR/$ASSET" "$URL"; then
  echo "ERROR: download failed." >&2
  exit 1
fi

ACTUAL_SHA256="$(shasum -a 256 "$TMPDIR/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  cat >&2 <<EOF
ERROR: sha256 mismatch.
  expected: $EXPECTED_SHA256
  actual:   $ACTUAL_SHA256
EOF
  exit 1
fi

mkdir -p "$VENDOR"
rm -rf "$FRAMEWORK"
tar -xzf "$TMPDIR/$ASSET" -C "$VENDOR"

if [ ! -d "$FRAMEWORK" ] || [ ! -f "$FRAMEWORK/Info.plist" ]; then
  echo "ERROR: tarball didn't produce $FRAMEWORK." >&2
  exit 1
fi

echo "$GHOSTTY_SHA" > "$MARKER"
echo "Installed GhosttyKit.xcframework (ghostty $GHOSTTY_TAG, $TAG)."
