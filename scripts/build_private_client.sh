#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 6 ]]; then
  echo "usage: build_private_client.sh <source-root> <private-output-root> <source-sha> <client-version> <mode> <carrier-sha>" >&2
  exit 64
fi

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$1" && pwd)"
mkdir -p "$2"
PRIVATE_OUTPUT_ROOT="$(cd "$2" && pwd)"
EXPECTED_SOURCE_SHA="$3"
EXPECTED_CLIENT_VERSION="$4"
PACKAGING_MODE="$5"
CARRIER_SHA="$6"
RUNNER_TEMP_ROOT="${RUNNER_TEMP:-/tmp}"

if [[ "$PACKAGING_MODE" != "unsigned-probe" && "$PACKAGING_MODE" != "production-release" ]]; then
  echo "unsupported packaging mode: $PACKAGING_MODE" >&2
  exit 65
fi

KEYCHAIN_PATH="$RUNNER_TEMP_ROOT/agentrouter-client-build.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP_ROOT/developer-id.p12"
API_KEY_PATH="$RUNNER_TEMP_ROOT/AuthKey_${APPLE_API_KEY_ID:-missing}.p8"
ORIGINAL_KEYCHAINS_FILE="$RUNNER_TEMP_ROOT/agentrouter-original-keychains.txt"
ORIGINAL_DEFAULT_KEYCHAIN=""
SIGNING_MATERIAL_PREPARED=0

cleanup_signing_material() {
  local status=$?
  if [[ "$SIGNING_MATERIAL_PREPARED" -eq 1 ]]; then
    if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
      security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" 2>/dev/null || true
    fi
    if [[ -f "$ORIGINAL_KEYCHAINS_FILE" ]]; then
      local original_keychains=()
      local line
      local keychain
      while IFS= read -r line; do
        keychain="${line#*\"}"
        keychain="${keychain%%\"*}"
        if [[ -n "$keychain" ]]; then
          original_keychains+=("$keychain")
        fi
      done < "$ORIGINAL_KEYCHAINS_FILE"
      if [[ "${#original_keychains[@]}" -gt 0 ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" 2>/dev/null || true
      fi
    fi
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  fi
  rm -f "$CERTIFICATE_PATH" "$API_KEY_PATH" "$ORIGINAL_KEYCHAINS_FILE"
  exit "$status"
}
trap cleanup_signing_material EXIT

require_environment() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "$name is required for production-release" >&2
      exit 66
    fi
  done
}

decode_base64_to_file() {
  local destination="$1"
  python3 -c '
import base64
import sys
from pathlib import Path
encoded = "".join(sys.stdin.read().split())
Path(sys.argv[1]).write_bytes(base64.b64decode(encoded, validate=True))
' "$destination"
}

find_exactly_one() {
  local root="$1"
  local kind="$2"
  local pattern="$3"
  local matches=()
  local match
  if [[ ! -d "$root" ]]; then
    echo "expected bundle directory does not exist: $root" >&2
    return 1
  fi
  while IFS= read -r match; do
    matches+=("$match")
  done < <(find "$root" -maxdepth 1 -type "$kind" -name "$pattern" -print)
  if [[ "${#matches[@]}" -ne 1 ]]; then
    echo "expected exactly one $pattern under $root, found ${#matches[@]}" >&2
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

universal_architectures() {
  local binary="$1"
  local label="$2"
  local architectures
  architectures="$(lipo -archs "$binary")"
  if ! grep -qw arm64 <<< "$architectures" || ! grep -qw x86_64 <<< "$architectures"; then
    echo "$label is not universal: $architectures" >&2
    return 1
  fi
  printf '%s\n' "$architectures"
}

cd "$SOURCE_ROOT"

ACTUAL_SOURCE_SHA="$(git rev-parse HEAD)"
if [[ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA" ]]; then
  echo "source checkout mismatch" >&2
  exit 67
fi

ACTUAL_CLIENT_VERSION="$(node -p "require('./package.json').version")"
ACTUAL_TAURI_VERSION="$(node -p "require('./src-tauri/tauri.conf.json').version")"
ACTUAL_LOCK_VERSION="$(node -p "require('./package-lock.json').version")"
if [[ "$ACTUAL_CLIENT_VERSION" != "$EXPECTED_CLIENT_VERSION" ]]; then
  echo "package.json version mismatch: expected $EXPECTED_CLIENT_VERSION, got $ACTUAL_CLIENT_VERSION" >&2
  exit 68
fi
if [[ "$ACTUAL_TAURI_VERSION" != "$EXPECTED_CLIENT_VERSION" ]]; then
  echo "tauri.conf.json version mismatch: expected $EXPECTED_CLIENT_VERSION, got $ACTUAL_TAURI_VERSION" >&2
  exit 69
fi
if [[ "$ACTUAL_LOCK_VERSION" != "$EXPECTED_CLIENT_VERSION" ]]; then
  echo "package-lock.json version mismatch: expected $EXPECTED_CLIENT_VERSION, got $ACTUAL_LOCK_VERSION" >&2
  exit 70
fi

NODE_VERSION="$(node --version)"
NPM_VERSION="$(npm --version)"
RUSTC_VERSION="$(rustc --version)"
CARGO_VERSION="$(cargo --version)"
MACOS_VERSION="$(sw_vers -productVersion)"
XCODE_VERSION="$(xcodebuild -version | paste -sd ' ' -)"

echo "mode=$PACKAGING_MODE"
echo "carrier_sha=$CARRIER_SHA"
echo "source_sha=$ACTUAL_SOURCE_SHA"
echo "client_version=$ACTUAL_CLIENT_VERSION"
echo "node=$NODE_VERSION"
echo "npm=$NPM_VERSION"
echo "rustc=$RUSTC_VERSION"
echo "cargo=$CARGO_VERSION"
echo "macos=$MACOS_VERSION"
echo "xcode=$XCODE_VERSION"

CERTIFICATE_BASE64_VALUE=""
CERTIFICATE_PASSWORD_VALUE=""
API_PRIVATE_KEY_BASE64_VALUE=""
API_KEY_ID_VALUE=""
API_ISSUER_VALUE=""
TEAM_ID_VALUE=""
UPDATER_PRIVATE_KEY_VALUE=""
UPDATER_PRIVATE_KEY_PASSWORD_VALUE=""

if [[ "$PACKAGING_MODE" == "production-release" ]]; then
  require_environment \
    APPLE_CERTIFICATE_BASE64 \
    APPLE_CERTIFICATE_PASSWORD \
    APPLE_API_PRIVATE_KEY_BASE64 \
    APPLE_API_KEY_ID \
    APPLE_API_ISSUER \
    APPLE_TEAM_ID \
    TAURI_SIGNING_PRIVATE_KEY
  CERTIFICATE_BASE64_VALUE="$APPLE_CERTIFICATE_BASE64"
  CERTIFICATE_PASSWORD_VALUE="$APPLE_CERTIFICATE_PASSWORD"
  API_PRIVATE_KEY_BASE64_VALUE="$APPLE_API_PRIVATE_KEY_BASE64"
  API_KEY_ID_VALUE="$APPLE_API_KEY_ID"
  API_ISSUER_VALUE="$APPLE_API_ISSUER"
  TEAM_ID_VALUE="$APPLE_TEAM_ID"
  UPDATER_PRIVATE_KEY_VALUE="$TAURI_SIGNING_PRIVATE_KEY"
  UPDATER_PRIVATE_KEY_PASSWORD_VALUE="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
fi

# Repository dependency lifecycle scripts do not receive raw signing material.
# The values retained above are unexported shell variables.
unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_API_PRIVATE_KEY_BASE64
unset APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_TEAM_ID
unset TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

npm ci

# The private project's Tauri hooks invoke `python`. GitHub's macOS image
# guarantees python3, but not an unversioned alias.
PYTHON_SHIM_ROOT="$RUNNER_TEMP_ROOT/agentrouter-python-shim"
mkdir -p "$PYTHON_SHIM_ROOT"
ln -sf "$(command -v python3)" "$PYTHON_SHIM_ROOT/python"
export PATH="$PYTHON_SHIM_ROOT:$PATH"

TAURI_OVERRIDE="$RUNNER_TEMP_ROOT/agentrouter-tauri-$PACKAGING_MODE.json"
SIGNING_AUTHORITY=""
TEAM_IDENTIFIER=""
UPDATER_KEY_ID=""
APP_NOTARY_STATUS="not-submitted"
DMG_NOTARY_STATUS="not-submitted"
DMG_NOTARY_ID=""

if [[ "$PACKAGING_MODE" == "production-release" ]]; then
  umask 077
  security list-keychains -d user > "$ORIGINAL_KEYCHAINS_FILE"
  ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*\"//' -e 's/\"[[:space:]]*$//')"

  printf '%s' "$CERTIFICATE_BASE64_VALUE" | decode_base64_to_file "$CERTIFICATE_PATH"
  printf '%s' "$API_PRIVATE_KEY_BASE64_VALUE" | decode_base64_to_file "$API_KEY_PATH"
  chmod 600 "$CERTIFICATE_PATH" "$API_KEY_PATH"
  grep -q 'BEGIN PRIVATE KEY' "$API_KEY_PATH"

  KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  SIGNING_MATERIAL_PREPARED=1
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERTIFICATE_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$CERTIFICATE_PASSWORD_VALUE" \
    -T /usr/bin/codesign
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH"

  current_keychains=("$KEYCHAIN_PATH")
  while IFS= read -r line; do
    keychain="${line#*\"}"
    keychain="${keychain%%\"*}"
    if [[ -n "$keychain" ]]; then
      current_keychains+=("$keychain")
    fi
  done < "$ORIGINAL_KEYCHAINS_FILE"
  security list-keychains -d user -s "${current_keychains[@]}"
  security default-keychain -d user -s "$KEYCHAIN_PATH"

  IDENTITY_LINE="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep 'Developer ID Application:' | head -n 1 || true)"
  if [[ -z "$IDENTITY_LINE" || "$IDENTITY_LINE" != *"($TEAM_ID_VALUE)"* ]]; then
    echo "the imported Developer ID Application identity does not match APPLE_TEAM_ID" >&2
    exit 71
  fi
  APPLE_SIGNING_IDENTITY="$(sed -E 's/^[^\"]*\"([^\"]+)\".*$/\1/' <<< "$IDENTITY_LINE")"
  if [[ "$APPLE_SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "unable to resolve the Developer ID Application identity name" >&2
    exit 71
  fi
  export APPLE_SIGNING_IDENTITY
  export APPLE_API_KEY="$API_KEY_ID_VALUE"
  export APPLE_API_KEY_PATH="$API_KEY_PATH"
  export APPLE_API_ISSUER="$API_ISSUER_VALUE"
  export APPLE_TEAM_ID="$TEAM_ID_VALUE"
  export TAURI_SIGNING_PRIVATE_KEY="$UPDATER_PRIVATE_KEY_VALUE"
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$UPDATER_PRIVATE_KEY_PASSWORD_VALUE"

  # The decoded certificate and API key stay on disk in the temporary keychain
  # and p8 file. Clear the retained source values before child build processes.
  CERTIFICATE_BASE64_VALUE=""
  CERTIFICATE_PASSWORD_VALUE=""
  API_PRIVATE_KEY_BASE64_VALUE=""
  API_KEY_ID_VALUE=""
  API_ISSUER_VALUE=""
  TEAM_ID_VALUE=""
  UPDATER_PRIVATE_KEY_VALUE=""
  UPDATER_PRIVATE_KEY_PASSWORD_VALUE=""

  printf '%s\n' '{"bundle":{"createUpdaterArtifacts":true}}' > "$TAURI_OVERRIDE"
else
  printf '%s\n' '{"bundle":{"createUpdaterArtifacts":false}}' > "$TAURI_OVERRIDE"
fi

TAURI_ARGS=(
  build
  --target universal-apple-darwin
  --bundles app
  --config "$TAURI_OVERRIDE"
  --ci
  --verbose
)
if [[ "$PACKAGING_MODE" == "unsigned-probe" ]]; then
  TAURI_ARGS+=(--no-sign)
fi
npm run tauri -- "${TAURI_ARGS[@]}"

BUNDLE_ROOT="$SOURCE_ROOT/src-tauri/target/universal-apple-darwin/release/bundle"
APP_PATH="$(find_exactly_one "$BUNDLE_ROOT/macos" d '*.app')"
APP_NAME="$(basename "$APP_PATH")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
MAIN_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -f "$MAIN_EXECUTABLE" ]]; then
  echo "main executable is missing" >&2
  exit 72
fi
MAIN_ARCHS="$(universal_architectures "$MAIN_EXECUTABLE" "main executable")"

SIDECAR_PATH="$(find_exactly_one "$APP_PATH/Contents/MacOS" f 'agentrouterctl*')"
SIDECAR_ARCHS="$(universal_architectures "$SIDECAR_PATH" "agentrouterctl sidecar")"

RECEIPT_GATES=(
  --gate "appUniversal=true"
  --gate "sidecarUniversal=true"
)
RECEIPT_ARTIFACTS=()
UPDATER_OUTPUT_PATH=""
UPDATER_SIGNATURE_OUTPUT_PATH=""

if [[ "$PACKAGING_MODE" == "production-release" ]]; then
  codesign --verify --deep --strict --verbose=4 "$APP_PATH"
  codesign --test-requirement="=notarized" --verify --verbose=4 "$APP_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
  xcrun stapler validate -v "$APP_PATH"
  APP_NOTARY_STATUS="Accepted"

  CODESIGN_DETAILS="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
  printf '%s\n' "$CODESIGN_DETAILS"
  SIGNING_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$CODESIGN_DETAILS" | head -n 1)"
  TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' <<< "$CODESIGN_DETAILS" | head -n 1)"
  if [[ -z "$SIGNING_AUTHORITY" || "$TEAM_IDENTIFIER" != "$APPLE_TEAM_ID" ]]; then
    echo "signed app authority or team identifier is incorrect" >&2
    exit 73
  fi

  UPDATER_ARCHIVE="$(find_exactly_one "$BUNDLE_ROOT/macos" f '*.app.tar.gz')"
  UPDATER_SIGNATURE="$UPDATER_ARCHIVE.sig"
  if [[ ! -s "$UPDATER_SIGNATURE" ]]; then
    echo "Tauri updater signature was not generated" >&2
    exit 74
  fi
  UPDATER_KEY_ID="$(python3 "$SCRIPT_ROOT/verify_tauri_updater_key.py" \
    --config "$SOURCE_ROOT/src-tauri/tauri.conf.json" \
    --signature "$UPDATER_SIGNATURE")"

  UPDATER_EXTRACT_ROOT="$RUNNER_TEMP_ROOT/agentrouter-updater-extract-${GITHUB_RUN_ID:-local}"
  case "$UPDATER_EXTRACT_ROOT" in
    "$RUNNER_TEMP_ROOT"/agentrouter-updater-extract-*) ;;
    *) echo "unsafe updater extraction path" >&2; exit 75 ;;
  esac
  rm -rf "$UPDATER_EXTRACT_ROOT"
  mkdir -p "$UPDATER_EXTRACT_ROOT"
  tar -xzf "$UPDATER_ARCHIVE" -C "$UPDATER_EXTRACT_ROOT"
  UPDATER_APP="$(find_exactly_one "$UPDATER_EXTRACT_ROOT" d '*.app')"
  UPDATER_EXECUTABLE="$UPDATER_APP/Contents/MacOS/$EXECUTABLE_NAME"
  UPDATER_MAIN_ARCHS="$(universal_architectures "$UPDATER_EXECUTABLE" "updater main executable")"
  UPDATER_SIDECAR="$(find_exactly_one "$UPDATER_APP/Contents/MacOS" f 'agentrouterctl*')"
  UPDATER_SIDECAR_ARCHS="$(universal_architectures "$UPDATER_SIDECAR" "updater agentrouterctl sidecar")"
  codesign --verify --deep --strict --verbose=4 "$UPDATER_APP"
  codesign --test-requirement="=notarized" --verify --verbose=4 "$UPDATER_APP"
  spctl --assess --type execute --verbose=4 "$UPDATER_APP"
  xcrun stapler validate -v "$UPDATER_APP"

  UPDATER_OUTPUT_PATH="$PRIVATE_OUTPUT_ROOT/AgentRouterClient_${EXPECTED_CLIENT_VERSION}_universal.app.tar.gz"
  UPDATER_SIGNATURE_OUTPUT_PATH="$UPDATER_OUTPUT_PATH.sig"
  cp "$UPDATER_ARCHIVE" "$UPDATER_OUTPUT_PATH"
  cp "$UPDATER_SIGNATURE" "$UPDATER_SIGNATURE_OUTPUT_PATH"

  RECEIPT_GATES+=(
    --gate "appCodeSignature=true"
    --gate "appNotarizedRequirement=true"
    --gate "appGatekeeper=true"
    --gate "appStapled=true"
    --gate "updaterUniversal=true"
    --gate "updaterAppCodeSignature=true"
    --gate "updaterAppNotarizedRequirement=true"
    --gate "updaterAppGatekeeper=true"
    --gate "updaterAppStapled=true"
    --gate "updaterSignaturePresent=true"
    --gate "updaterKeyIdMatchesConfig=true"
    --gate "teamIdentifierMatches=true"
  )
  RECEIPT_ARTIFACTS+=(
    --artifact "updaterArchive=$UPDATER_OUTPUT_PATH"
    --artifact "updaterSignature=$UPDATER_SIGNATURE_OUTPUT_PATH"
  )
fi

DMG_STAGING="$RUNNER_TEMP_ROOT/agentrouter-dmg-staging-${GITHUB_RUN_ID:-local}"
case "$DMG_STAGING" in
  "$RUNNER_TEMP_ROOT"/agentrouter-dmg-staging-*) ;;
  *) echo "unsafe DMG staging path" >&2; exit 76 ;;
esac
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/AgentRouterClient.app"
ln -s /Applications "$DMG_STAGING/Applications"

if [[ "$PACKAGING_MODE" == "production-release" ]]; then
  DMG_PATH="$PRIVATE_OUTPUT_ROOT/AgentRouterClient_${EXPECTED_CLIENT_VERSION}_universal_signed_notarized.dmg"
else
  DMG_PATH="$PRIVATE_OUTPUT_ROOT/AgentRouterClient_${EXPECTED_CLIENT_VERSION}_universal_unsigned.dmg"
fi
hdiutil create \
  -volname "AgentRouter Client ${EXPECTED_CLIENT_VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ "$PACKAGING_MODE" == "production-release" ]]; then
  codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=4 "$DMG_PATH"

  DMG_NOTARY_JSON="$PRIVATE_OUTPUT_ROOT/dmg-notarization.json"
  xcrun notarytool submit "$DMG_PATH" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" \
    --wait \
    --output-format json \
    > "$DMG_NOTARY_JSON"
  read -r DMG_NOTARY_STATUS DMG_NOTARY_ID < <(
    python3 -c '
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value.get("status", "missing"), value.get("id", "missing"))
' "$DMG_NOTARY_JSON"
  )
  if [[ "$DMG_NOTARY_STATUS" != "Accepted" || "$DMG_NOTARY_ID" == "missing" ]]; then
    echo "DMG notarization was not accepted" >&2
    exit 77
  fi
  xcrun notarytool log "$DMG_NOTARY_ID" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" \
    "$PRIVATE_OUTPUT_ROOT/dmg-notarization-log.json"

  xcrun stapler staple -v "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
  codesign --verify --verbose=4 "$DMG_PATH"
  xcrun stapler validate -v "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  RECEIPT_GATES+=(
    --gate "dmgIntegrity=true"
    --gate "dmgCodeSignature=true"
    --gate "dmgGatekeeper=true"
    --gate "dmgStapled=true"
  )
else
  hdiutil verify "$DMG_PATH"
  RECEIPT_GATES+=(--gate "dmgIntegrity=true")
fi
RECEIPT_ARTIFACTS+=(--artifact "dmg=$DMG_PATH")

python3 "$SCRIPT_ROOT/write_build_receipt.py" \
  --output "$PRIVATE_OUTPUT_ROOT/build-receipt.json" \
  --carrier-sha "$CARRIER_SHA" \
  --source-sha "$ACTUAL_SOURCE_SHA" \
  --version "$ACTUAL_CLIENT_VERSION" \
  --mode "$PACKAGING_MODE" \
  --app-name "$APP_NAME" \
  --main-architectures "$MAIN_ARCHS" \
  --sidecar-architectures "$SIDECAR_ARCHS" \
  --macos-version "$MACOS_VERSION" \
  --xcode-version "$XCODE_VERSION" \
  --node-version "$NODE_VERSION" \
  --npm-version "$NPM_VERSION" \
  --rustc-version "$RUSTC_VERSION" \
  --cargo-version "$CARGO_VERSION" \
  --signing-authority "$SIGNING_AUTHORITY" \
  --team-id "$TEAM_IDENTIFIER" \
  --updater-key-id "$UPDATER_KEY_ID" \
  --app-notary-status "$APP_NOTARY_STATUS" \
  --dmg-notary-status "$DMG_NOTARY_STATUS" \
  --dmg-notary-id "$DMG_NOTARY_ID" \
  "${RECEIPT_ARTIFACTS[@]}" \
  "${RECEIPT_GATES[@]}"

echo "build completed mode=$PACKAGING_MODE"
