#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 8 ]]; then
  echo "usage: encrypt_private_artifact.sh <private-root> <public-root> <source-sha> <client-version> <mode> <build-status> <run-id> <carrier-sha>" >&2
  exit 64
fi

PRIVATE_ROOT="$1"
PUBLIC_ROOT="$2"
SOURCE_SHA="$3"
CLIENT_VERSION="$4"
PACKAGING_MODE="$5"
BUILD_STATUS="$6"
RUN_ID="$7"
CARRIER_SHA="$8"

if [[ -z "${ARTIFACT_ENCRYPTION_KEY:-}" ]]; then
  echo "ARTIFACT_ENCRYPTION_KEY is required" >&2
  exit 65
fi
if [[ "$PACKAGING_MODE" != "unsigned-probe" && "$PACKAGING_MODE" != "production-release" ]]; then
  echo "unsupported packaging mode" >&2
  exit 66
fi

mkdir -p "$PRIVATE_ROOT" "$PUBLIC_ROOT"

ARCHIVE_PATH="${RUNNER_TEMP:-/tmp}/agentrouter-macos-private-${RUN_ID}.tar.gz"
ENCRYPTED_NAME="AgentRouterClient_${CLIENT_VERSION}_${PACKAGING_MODE}_${SOURCE_SHA:0:12}_${RUN_ID}.tar.gz.enc"
ENCRYPTED_PATH="$PUBLIC_ROOT/$ENCRYPTED_NAME"

tar -C "$PRIVATE_ROOT" -czf "$ARCHIVE_PATH" .
openssl enc \
  -aes-256-cbc \
  -salt \
  -pbkdf2 \
  -iter 200000 \
  -md sha256 \
  -pass env:ARTIFACT_ENCRYPTION_KEY \
  -in "$ARCHIVE_PATH" \
  -out "$ENCRYPTED_PATH"
rm -f "$ARCHIVE_PATH"

ENCRYPTED_SHA256="$(shasum -a 256 "$ENCRYPTED_PATH" | awk '{print $1}')"
ENCRYPTED_SIZE="$(stat -f '%z' "$ENCRYPTED_PATH")"

python3 - \
  "$PUBLIC_ROOT/encrypted-artifact-receipt.json" \
  "$SOURCE_SHA" \
  "$CLIENT_VERSION" \
  "$PACKAGING_MODE" \
  "$BUILD_STATUS" \
  "$ENCRYPTED_NAME" \
  "$ENCRYPTED_SHA256" \
  "$ENCRYPTED_SIZE" \
  "$RUN_ID" \
  "$CARRIER_SHA" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    source_sha,
    client_version,
    mode,
    build_status,
    artifact_name,
    artifact_sha256,
    artifact_size,
    run_id,
    carrier_sha,
) = sys.argv[1:]

receipt = {
    "schemaVersion": 2,
    "carrierSha": carrier_sha,
    "sourceSha": source_sha,
    "clientVersion": client_version,
    "mode": mode,
    "buildStatus": int(build_status),
    "runId": int(run_id),
    "encryption": "openssl-aes-256-cbc-pbkdf2-sha256-iter200000",
    "artifact": {
        "name": artifact_name,
        "sha256": artifact_sha256,
        "size": int(artifact_size),
    },
}
Path(output_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
PY
