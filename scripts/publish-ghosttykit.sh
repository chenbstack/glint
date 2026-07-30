#!/usr/bin/env bash
# Publish the current Vendor/GhosttyKit.xcframework as a GitHub Release
# asset and register its sha256 in scripts/ghosttykit-checksums.txt.
#
# Run this locally after bumping the ghostty submodule. Requires:
#   * a working GhosttyKit.xcframework in Vendor/ — run
#     scripts/build-ghosttykit.sh, which handles the toolchain quirks
#   * `gh` CLI logged in with write access to chenbstack/glint
#
# The release tag follows: xcframework-<short-sha>-v<N>
# where N starts at 1 and bumps if you have to re-publish for the same SHA.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/ghostty"
VENDOR="$ROOT/Vendor"
FRAMEWORK="$VENDOR/GhosttyKit.xcframework"
REGISTRY="$ROOT/scripts/ghosttykit-checksums.txt"
REPO="${GHOSTTYKIT_RELEASE_REPO:-chenbstack/glint}"

if [ ! -d "$FRAMEWORK" ]; then
  echo "ERROR: $FRAMEWORK is missing — run scripts/build-ghosttykit.sh first." >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not on PATH." >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C "$GHOSTTY" rev-parse HEAD)"
SHORT_SHA="$(printf '%s' "$GHOSTTY_SHA" | cut -c1-7)"

# Determine next vN for this SHA.
N=1
if [ -f "$REGISTRY" ]; then
  EXISTING_MAX="$(grep -v '^[[:space:]]*#' "$REGISTRY" \
    | awk -v sha="$GHOSTTY_SHA" '$1 == sha {print $3}' \
    | sed -E 's/.*-v([0-9]+)$/\1/' \
    | sort -n | tail -n1 || true)"
  if [ -n "${EXISTING_MAX:-}" ]; then
    N=$((EXISTING_MAX + 1))
  fi
fi
TAG="xcframework-${SHORT_SHA}-v${N}"
# Filename must match what setup-ghosttykit.sh derives from the tag:
# xcframework-<short>-v<N> → GhosttyKit-<short>-v<N>.tar.gz
ASSET="GhosttyKit-${SHORT_SHA}-v${N}.tar.gz"
TARBALL="$(mktemp -d)/$ASSET"

echo "Packing $FRAMEWORK → $TARBALL"
tar -czf "$TARBALL" -C "$VENDOR" GhosttyKit.xcframework
SIZE="$(du -h "$TARBALL" | awk '{print $1}')"
SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "  size:   $SIZE"
echo "  sha256: $SHA256"

echo "Creating release $TAG on $REPO"
# --prerelease keeps build-artifact releases away from the repo's
# "Latest" slot — that belongs to the newest vX.Y.Z app release (the
# cask's livecheck `:github_latest` reads it, and so do visitors).
gh release create "$TAG" \
  --repo "$REPO" \
  --prerelease \
  --title "GhosttyKit prebuilt — ghostty $SHORT_SHA (v$N)" \
  --notes "Prebuilt GhosttyKit.xcframework for ghostty $GHOSTTY_SHA.

Consumed by scripts/setup-ghosttykit.sh during CI and local builds.
sha256: $SHA256" \
  "$TARBALL"

# Append to the registry.
{
  printf '%s %s %s\n' "$GHOSTTY_SHA" "$SHA256" "$TAG"
} >> "$REGISTRY"

echo
echo "Done. Don't forget to commit scripts/ghosttykit-checksums.txt:"
echo "  git add scripts/ghosttykit-checksums.txt"
echo "  git commit -m 'ghosttykit: publish $TAG'"
