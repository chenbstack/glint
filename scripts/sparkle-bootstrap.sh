#!/usr/bin/env bash
# Generate (or reuse) a Sparkle EdDSA keypair for Glint and wire it up:
#   * write the public key into Glint/Resources/Info.plist as SUPublicEDKey
#   * export the private key and offer to upload it to the
#     SPARKLE_ED_PRIV_KEY GitHub secret on chenbstack/glint, so the release
#     workflow can sign update DMGs.
#
# The private key is stored in the macOS login Keychain by `generate_keys`
# and is also written to a 0600 temp file just long enough to push it as
# a secret. The temp file is removed before this script exits.
#
# Run from the repo root. Requires `gh` logged in to the repo's owner.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
SPARKLE_DIR="$ROOT/.sparkle"
GEN_KEYS="$SPARKLE_DIR/bin/generate_keys"
INFO_PLIST="Glint/Resources/Info.plist"
REPO="${SPARKLE_REPO:-chenbstack/glint}"
PRIV_TMP="$(mktemp -t sparkle-priv.XXXXXX)"
trap 'rm -f "$PRIV_TMP"' EXIT

# 1. Fetch Sparkle's tools if missing.
if [ ! -x "$GEN_KEYS" ]; then
  echo "Downloading Sparkle $SPARKLE_VERSION…"
  mkdir -p "$SPARKLE_DIR"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    | tar -xJ -C "$SPARKLE_DIR" --strip-components=1
fi

# 2. Either reuse an existing keypair from the Keychain, or generate one.
if PUB="$("$GEN_KEYS" -p 2>/dev/null)" && [ -n "$PUB" ]; then
  echo "Reusing existing Sparkle keypair from Keychain."
else
  echo "No Sparkle keypair found — generating one. Keychain may prompt."
  "$GEN_KEYS"
  PUB="$("$GEN_KEYS" -p)"
fi
echo "Public key: $PUB"

# 3. Export the private key (Sparkle 2.6+: `generate_keys -x <path>`).
"$GEN_KEYS" -x "$PRIV_TMP" >/dev/null
chmod 0600 "$PRIV_TMP"
if [ ! -s "$PRIV_TMP" ]; then
  echo "ERROR: private key export produced an empty file." >&2
  exit 1
fi

# 4. Stamp the public key into Info.plist.
plutil -replace SUPublicEDKey -string "$PUB" "$INFO_PLIST"
echo "Wrote SUPublicEDKey into $INFO_PLIST."

# 5. Offer to push the private key to the repo's GitHub Secret.
if command -v gh >/dev/null 2>&1; then
  echo
  echo "Push private key to GitHub secret SPARKLE_ED_PRIV_KEY on $REPO?"
  printf "  [y/N] "
  read -r reply
  if [ "${reply:-N}" = "y" ] || [ "${reply:-N}" = "Y" ]; then
    gh secret set SPARKLE_ED_PRIV_KEY --repo "$REPO" < "$PRIV_TMP"
    echo "Uploaded SPARKLE_ED_PRIV_KEY."
  else
    echo "Skipped. To upload later:"
    echo "  gh secret set SPARKLE_ED_PRIV_KEY --repo $REPO < <(this script with --print-priv)"
  fi
else
  echo "gh CLI not on PATH — cannot push secret automatically."
  echo "Set it manually: chenbstack/glint → Settings → Secrets → SPARKLE_ED_PRIV_KEY"
fi

echo
echo "Done. Commit Info.plist next:"
echo "  git add $INFO_PLIST && git commit -m 'sparkle: wire public EdDSA key'"
