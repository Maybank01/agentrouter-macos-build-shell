#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: build_private_client.sh <source-root> <private-output-root> <source-sha> <client-version>" >&2
  exit 64
fi

SOURCE_ROOT="$(cd "$1" && pwd)"
mkdir -p "$2"
PRIVATE_OUTPUT_ROOT="$(cd "$2" && pwd)"
EXPECTED_SOURCE_SHA="$3"
EXPECTED_CLIENT_VERSION="$4"

cd "$SOURCE_ROOT"

ACTUAL_SOURCE_SHA="$(git rev-parse HEAD)"
if [[ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA" ]]; then
  echo "source checkout mismatch" >&2
  exit 65
fi

ACTUAL_CLIENT_VERSION="$(node -p "require('./package.json').version")"
if [[ "$ACTUAL_CLIENT_VERSION" != "$EXPECTED_CLIENT_VERSION" ]]; then
  echo "client version mismatch: expected $EXPECTED_CLIENT_VERSION, got $ACTUAL_CLIENT_VERSION" >&2
  exit 66
fi

echo "node=$(node --version)"
echo "npm=$(npm --version)"
echo "rustc=$(rustc --version)"
echo "cargo=$(cargo --version)"
echo "source_sha=$ACTUAL_SOURCE_SHA"
echo "client_version=$ACTUAL_CLIENT_VERSION"

npm ci
npm run build

# Tauri's project hook invokes `python`; GitHub runners guarantee python3 but
# not every macOS image guarantees the unversioned alias.
PYTHON_SHIM_ROOT="${RUNNER_TEMP:-/tmp}/agentrouter-python-shim"
mkdir -p "$PYTHON_SHIM_ROOT"
ln -sf "$(command -v python3)" "$PYTHON_SHIM_ROOT/python"
export PATH="$PYTHON_SHIM_ROOT:$PATH"

# Build the application bundle only. The DMG is assembled below with hdiutil,
# keeping Tauri's DMG helper out of this carrier proof.
npm run tauri -- build \
  --target universal-apple-darwin \
  --bundles app \
  --no-sign \
  --ci \
  --verbose

BUNDLE_ROOT="$SOURCE_ROOT/src-tauri/target/universal-apple-darwin/release/bundle"
APP_PATH="$(find "$BUNDLE_ROOT/macos" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "universal app bundle was not generated" >&2
  exit 67
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
MAIN_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -f "$MAIN_EXECUTABLE" ]]; then
  echo "main executable is missing" >&2
  exit 68
fi

MAIN_ARCHS="$(lipo -archs "$MAIN_EXECUTABLE")"
grep -qw arm64 <<< "$MAIN_ARCHS"
grep -qw x86_64 <<< "$MAIN_ARCHS"

SIDECAR_PATH="$(find "$APP_PATH/Contents/MacOS" -maxdepth 1 -type f -name 'agentrouterctl*' -print -quit)"
if [[ -z "$SIDECAR_PATH" ]]; then
  echo "agentrouterctl sidecar is missing" >&2
  exit 69
fi

SIDECAR_ARCHS="$(lipo -archs "$SIDECAR_PATH")"
grep -qw arm64 <<< "$SIDECAR_ARCHS"
grep -qw x86_64 <<< "$SIDECAR_ARCHS"

DMG_STAGING="${RUNNER_TEMP:-/tmp}/agentrouter-dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/AgentRouterClient.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_PATH="$PRIVATE_OUTPUT_ROOT/AgentRouterClient_${EXPECTED_CLIENT_VERSION}_universal_unsigned.dmg"
hdiutil create \
  -volname "AgentRouter Client ${EXPECTED_CLIENT_VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"

python3 - \
  "$PRIVATE_OUTPUT_ROOT/build-receipt.json" \
  "$ACTUAL_SOURCE_SHA" \
  "$ACTUAL_CLIENT_VERSION" \
  "$MAIN_ARCHS" \
  "$SIDECAR_ARCHS" \
  "$(basename "$DMG_PATH")" \
  "$DMG_SHA256" \
  "$DMG_SIZE" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    source_sha,
    client_version,
    main_archs,
    sidecar_archs,
    dmg_name,
    dmg_sha256,
    dmg_size,
) = sys.argv[1:]

receipt = {
    "schemaVersion": 1,
    "sourceSha": source_sha,
    "clientVersion": client_version,
    "target": "universal-apple-darwin",
    "signingState": "unsigned",
    "internalOnly": True,
    "mainArchitectures": main_archs.split(),
    "sidecarArchitectures": sidecar_archs.split(),
    "artifact": {
        "name": dmg_name,
        "sha256": dmg_sha256,
        "size": int(dmg_size),
    },
}
Path(output_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
PY

echo "build completed"
