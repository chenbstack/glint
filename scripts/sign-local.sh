#!/usr/bin/env bash
# Codesign a built .app with a stable local/self-signed Code Signing identity.
#
# Required env (set as GitHub secrets in the release workflow):
#   LOCAL_CODE_SIGN_CERT_P12_BASE64   base64 of the exported .p12
#   LOCAL_CODE_SIGN_CERT_PASSWORD     password used when exporting the .p12
#
# Optional env:
#   LOCAL_CODE_SIGN_IDENTITY          certificate common name to prefer
#
# Usage:  scripts/sign-local.sh path/to/Glint.app

set -euo pipefail

APP="${1:?usage: sign-local.sh <App.app>}"
: "${LOCAL_CODE_SIGN_CERT_P12_BASE64:?missing}"
: "${LOCAL_CODE_SIGN_CERT_PASSWORD:?missing}"
LOCAL_CODE_SIGN_IDENTITY="${LOCAL_CODE_SIGN_IDENTITY:-Glint Local Code Signing}"

KEYCHAIN="$RUNNER_TEMP/glint-local-sign.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"

umask 077
mkdir -p "$RUNNER_TEMP"
CERT_PATH="$RUNNER_TEMP/local-code-sign.p12"
printf '%s' "$LOCAL_CODE_SIGN_CERT_P12_BASE64" | base64 --decode > "$CERT_PATH"

cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$CERT_PATH"
}
trap cleanup EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT_PATH" -k "$KEYCHAIN" -P "$LOCAL_CODE_SIGN_CERT_PASSWORD" \
  -A -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$KEYCHAIN" "$(security list-keychains -d user | tr -d '\"' | xargs)"

IDENTITY="$LOCAL_CODE_SIGN_IDENTITY"
echo "Signing with: $IDENTITY"

if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -type d -name '*.framework' -depth | while read -r fw; do
    /usr/bin/codesign --force --options runtime --sign "$IDENTITY" "$fw"
  done
fi
/usr/bin/codesign --force --options runtime --deep --sign "$IDENTITY" "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "Locally signed: $APP"
