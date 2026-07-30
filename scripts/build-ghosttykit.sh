#!/usr/bin/env bash
# Build GhosttyKit.xcframework locally from the pinned ghostty submodule and
# install it into Vendor/.
#
# You only need this after bumping the ghostty submodule to a SHA that has no
# prebuilt artifact yet — `scripts/ghosttykit-checksums.txt` has no line for it,
# so `setup-ghosttykit.sh` fails and CI cannot build the app at all. Normal flow
# is: run this, sanity-check the app, then `publish-ghosttykit.sh` to upload the
# result and register its checksum. Day to day, nobody runs this: setup-ghosttykit.sh
# downloads the published artifact instead.
#
# Three things make this build non-obvious enough to deserve a script; all of
# them are handled below.
#
#   1. ghostty pins an exact zig. `minimum_zig_version` in build.zig.zon is a
#      floor by name only — a *newer* zig fails outright, because build.zig
#      calls std APIs that change shape between zig releases (0.16 renamed
#      Dir.readFileAlloc's signature, so build.zig doesn't even parse). We read
#      the required version and fetch that exact toolchain into a cache dir
#      rather than touching whatever zig is on PATH.
#
#   2. zig 0.15.2 cannot link against the macOS 26 (Tahoe) SDK — every libc
#      symbol (_malloc, _fork, _sigaction, …) comes up undefined while building
#      zig's own build runner. zig resolves the SDK by shelling out to `xcrun
#      --show-sdk-path`, and honours neither SDKROOT nor --sysroot for this
#      step, so the fix is a tiny xcrun shim earlier on PATH that answers with
#      an older SDK. Override with GLINT_GHOSTTY_SDKROOT if the autodetected
#      one is wrong.
#
#   3. The xcframework step runs `metal`, which lives in a separately
#      downloaded Xcode component. We check for it and print the one-liner
#      rather than letting the build die 15 minutes in.
#
# Requires full Xcode (not just Command Line Tools) — DEVELOPER_DIR is set
# below if xcode-select currently points at the CLT instance.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/ghostty"
VENDOR="$ROOT/Vendor"
FRAMEWORK="$VENDOR/GhosttyKit.xcframework"
MARKER="$VENDOR/.ghosttykit-sha"
CACHE="${GLINT_GHOSTTYKIT_CACHE:-$HOME/.cache/glint-ghosttykit}"

if [ ! -d "$GHOSTTY/.git" ] && [ ! -f "$GHOSTTY/.git" ]; then
  cat >&2 <<EOF
ERROR: ghostty submodule is missing.

Initialize it first:
  git submodule update --init --recursive
EOF
  exit 1
fi

GHOSTTY_SHA="$(git -C "$GHOSTTY" rev-parse HEAD)"
echo "Building GhosttyKit for ghostty $GHOSTTY_SHA"

# --- Xcode ------------------------------------------------------------------
# xcodebuild is invoked by ghostty's xcframework step and refuses to run under
# the Command Line Tools directory.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "  using DEVELOPER_DIR=$DEVELOPER_DIR (xcode-select points at the CLT)"
  else
    echo "ERROR: full Xcode is required; only Command Line Tools were found." >&2
    exit 1
  fi
fi

# --- Metal toolchain --------------------------------------------------------
if ! /usr/bin/xcrun -f metal >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: the Metal toolchain is not installed; the xcframework step needs it.

Install it (roughly 700 MB), then re-run:
  xcodebuild -downloadComponent MetalToolchain
EOF
  exit 1
fi

# --- zig --------------------------------------------------------------------
# Exact version, not a minimum — see note 1 at the top.
ZIG_VERSION="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
if [ -z "$ZIG_VERSION" ]; then
  echo "ERROR: could not read minimum_zig_version from $GHOSTTY/build.zig.zon" >&2
  exit 1
fi

ZIG_BIN=""
if command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; then
  ZIG_BIN="$(command -v zig)"
  echo "  zig $ZIG_VERSION found on PATH"
else
  case "$(uname -m)" in
    arm64) ZIG_ARCH="aarch64" ;;
    x86_64) ZIG_ARCH="x86_64" ;;
    *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  ZIG_DIR="$CACHE/zig-$ZIG_ARCH-macos-$ZIG_VERSION"
  if [ ! -x "$ZIG_DIR/zig" ]; then
    ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-macos-$ZIG_VERSION.tar.xz"
    echo "  fetching zig $ZIG_VERSION → $ZIG_DIR"
    mkdir -p "$CACHE"
    curl -fsSL "$ZIG_URL" -o "$CACHE/zig-$ZIG_VERSION.tar.xz"
    tar -xf "$CACHE/zig-$ZIG_VERSION.tar.xz" -C "$CACHE"
    rm -f "$CACHE/zig-$ZIG_VERSION.tar.xz"
  fi
  if [ ! -x "$ZIG_DIR/zig" ]; then
    echo "ERROR: zig $ZIG_VERSION was not where we expected: $ZIG_DIR/zig" >&2
    exit 1
  fi
  ZIG_BIN="$ZIG_DIR/zig"
  echo "  using cached zig $ZIG_VERSION"
fi

# --- SDK shim ---------------------------------------------------------------
# See note 2. Only needed while the host SDK is too new for the pinned zig.
SHIM_DIR=""
SDK_MAJOR="$(/usr/bin/xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
if [ -n "${GLINT_GHOSTTY_SDKROOT:-}" ]; then
  BUILD_SDK="$GLINT_GHOSTTY_SDKROOT"
elif [ -n "$SDK_MAJOR" ] && [ "$SDK_MAJOR" -ge 26 ]; then
  BUILD_SDK=""
  for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.sdk; do
    if [ -d "$candidate" ]; then BUILD_SDK="$candidate"; break; fi
  done
  if [ -z "$BUILD_SDK" ]; then
    cat >&2 <<EOF
ERROR: host SDK is macOS $SDK_MAJOR, which zig $ZIG_VERSION cannot link against,
and no macOS 15 SDK was found to fall back to.

Install the older SDK, or point at one explicitly:
  GLINT_GHOSTTY_SDKROOT=/path/to/MacOSX15.sdk $0
EOF
    exit 1
  fi
else
  BUILD_SDK=""
fi

if [ -n "$BUILD_SDK" ]; then
  echo "  shimming xcrun → $BUILD_SDK"
  SHIM_DIR="$(mktemp -d)"
  trap 'rm -rf "$SHIM_DIR"' EXIT
  cat > "$SHIM_DIR/xcrun" <<EOF
#!/bin/bash
# Only the SDK lookups are answered locally; everything else defers to the real
# xcrun so the rest of the toolchain behaves normally.
for arg in "\$@"; do
  case "\$arg" in
    --show-sdk-path) echo "$BUILD_SDK"; exit 0 ;;
    --show-sdk-version) basename "$BUILD_SDK" | sed -E 's/MacOSX([0-9.]*)\.sdk/\1/'; exit 0 ;;
  esac
done
exec /usr/bin/xcrun "\$@"
EOF
  chmod +x "$SHIM_DIR/xcrun"
  export PATH="$SHIM_DIR:$PATH"
fi

# --- build ------------------------------------------------------------------
# ARCHS is arm64 across CI and release, so a native (not universal) slice is
# what every consumer actually loads.
echo "Running zig build (this takes a while)"
BUILD_LOG="$(mktemp)"
set +e
(cd "$GHOSTTY" && "$ZIG_BIN" build \
  -Doptimize=ReleaseFast \
  -Dapp-runtime=none \
  -Demit-xcframework=true \
  -Dxcframework-target=native) > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

# The build's final step assembles ghostty's *own* macOS app bundle, which we
# neither need nor can always build. It is allowed to fail as long as the
# xcframework itself landed — so the artifact, not the exit code, is the test.
BUILT="$GHOSTTY/macos/GhosttyKit.xcframework"
if [ ! -d "$BUILT" ]; then
  echo "ERROR: build did not produce $BUILT" >&2
  echo "--- last 40 lines of build output ---" >&2
  tail -40 "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  exit 1
fi
if [ $BUILD_STATUS -ne 0 ]; then
  echo "  note: zig build exited $BUILD_STATUS after producing the xcframework"
  echo "        (ghostty's own app-bundle step is not needed here)"
fi
rm -f "$BUILD_LOG"

# --- install ----------------------------------------------------------------
mkdir -p "$VENDOR"
rm -rf "$FRAMEWORK"
cp -R "$BUILT" "$FRAMEWORK"
printf '%s\n' "$GHOSTTY_SHA" > "$MARKER"

echo
echo "Installed $FRAMEWORK (ghostty $GHOSTTY_SHA)."
echo "Next:"
echo "  1. build and smoke-test the app against it"
echo "  2. scripts/publish-ghosttykit.sh   # upload + register the checksum"
