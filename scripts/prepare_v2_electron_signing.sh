#!/usr/bin/env bash
set -Eeuo pipefail

for name in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_API_PRIVATE_KEY_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_TEAM_ID; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required for production-release" >&2
    exit 65
  fi
done

KEYCHAIN_PATH="$RUNNER_TEMP/agentrouter-v2-electron.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP/agentrouter-v2-developer-id.p12"
API_KEY_PATH="$RUNNER_TEMP/agentrouter-v2-api-key.p8"
ORIGINAL_DEFAULT="$RUNNER_TEMP/agentrouter-v2-original-default-keychain.txt"
ORIGINAL_LIST="$RUNNER_TEMP/agentrouter-v2-original-keychains.txt"
PYTHON_BIN="$(command -v python3 || command -v python)"

security default-keychain -d user > "$ORIGINAL_DEFAULT"
security list-keychains -d user > "$ORIGINAL_LIST"
printf '%s' "$APPLE_CERTIFICATE_BASE64" | "$PYTHON_BIN" -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode("".join(sys.stdin.read().split()),validate=True))' "$CERTIFICATE_PATH"
printf '%s' "$APPLE_API_PRIVATE_KEY_BASE64" | "$PYTHON_BIN" -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode("".join(sys.stdin.read().split()),validate=True))' "$API_KEY_PATH"
chmod 600 "$CERTIFICATE_PATH" "$API_KEY_PATH"
grep -q 'BEGIN PRIVATE KEY' "$API_KEY_PATH"

KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -k "$KEYCHAIN_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"

IDENTITY_LINE="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep 'Developer ID Application:' | head -n 1 || true)"
if [[ -z "$IDENTITY_LINE" || "$IDENTITY_LINE" != *"($APPLE_TEAM_ID)"* ]]; then
  echo "Developer ID Application identity does not match APPLE_TEAM_ID" >&2
  exit 66
fi
CSC_NAME="$(sed -E 's/^[^\"]*\"([^\"]+)\".*$/\1/' <<< "$IDENTITY_LINE")"

# Fail in a classified preflight before the private build log is encrypted.
# These probes never print credentials, certificate subjects, or Apple's
# response body; they only prove that the imported identity can sign with a
# secure timestamp and that the App Store Connect key can authenticate.
SIGNING_PROBE="$RUNNER_TEMP/agentrouter-v2-signing-probe"
cp /usr/bin/true "$SIGNING_PROBE"
if ! codesign --force --options runtime --timestamp --sign "$CSC_NAME" "$SIGNING_PROBE" >/dev/null 2>&1; then
  rm -f "$SIGNING_PROBE"
  echo "Developer ID signing probe failed" >&2
  exit 67
fi
if ! codesign --verify --strict "$SIGNING_PROBE" >/dev/null 2>&1; then
  rm -f "$SIGNING_PROBE"
  echo "Developer ID verification probe failed" >&2
  exit 68
fi
rm -f "$SIGNING_PROBE"

if ! xcrun notarytool history \
  --key "$API_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --output-format json >/dev/null 2>&1; then
  echo "Apple notarization credential probe failed" >&2
  exit 69
fi

{
  echo "CSC_NAME=$CSC_NAME"
  echo "APPLE_API_KEY=$API_KEY_PATH"
  echo "APPLE_API_KEY_ID=$APPLE_API_KEY_ID"
  echo "APPLE_API_ISSUER=$APPLE_API_ISSUER"
  echo "APPLE_TEAM_ID=$APPLE_TEAM_ID"
} >> "$GITHUB_ENV"
