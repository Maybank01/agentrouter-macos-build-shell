#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 10 ]]; then
  echo "usage: encrypt_v2_artifact.sh <private-root> <public-root> <source-sha> <client-version> <mode> <build-status> <run-id> <carrier-sha> <platform> <arch>" >&2
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
PLATFORM="$9"
ARCH="${10}"

if [[ -z "${ARTIFACT_ENCRYPTION_KEY:-}" ]]; then
  echo "ARTIFACT_ENCRYPTION_KEY is required" >&2
  exit 65
fi
if [[ "$PACKAGING_MODE" != "unsigned-probe" && "$PACKAGING_MODE" != "production-release" ]]; then
  echo "unsupported packaging mode" >&2
  exit 66
fi

mkdir -p "$PRIVATE_ROOT" "$PUBLIC_ROOT"
PYTHON_BIN="$(command -v python3 || command -v python)"
ARCHIVE_PATH="${RUNNER_TEMP:-/tmp}/agentrouter-v2-${PLATFORM}-${ARCH}-${RUN_ID}.tar.gz"
ENCRYPTED_NAME="AgentRouterV2_${CLIENT_VERSION}_${PLATFORM}_${ARCH}_${PACKAGING_MODE}_${SOURCE_SHA:0:12}_${RUN_ID}.tar.gz.enc"
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

"$PYTHON_BIN" - \
  "$PUBLIC_ROOT/encrypted-artifact-receipt.json" \
  "$SOURCE_SHA" \
  "$CLIENT_VERSION" \
  "$PACKAGING_MODE" \
  "$BUILD_STATUS" \
  "$ENCRYPTED_NAME" \
  "$ENCRYPTED_PATH" \
  "$RUN_ID" \
  "$CARRIER_SHA" \
  "$PLATFORM" \
  "$ARCH" <<'PY'
import hashlib
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
    encrypted_path,
    run_id,
    carrier_sha,
    platform,
    arch,
) = sys.argv[1:]
path = Path(encrypted_path)
digest = hashlib.sha256(path.read_bytes()).hexdigest()
receipt = {
    "schemaVersion": 1,
    "carrierSha": carrier_sha,
    "sourceSha": source_sha,
    "clientVersion": client_version,
    "mode": mode,
    "platform": platform,
    "arch": arch,
    "buildStatus": int(build_status),
    "runId": int(run_id),
    "encryption": "openssl-aes-256-cbc-pbkdf2-sha256-iter200000",
    "artifact": {"name": artifact_name, "sha256": digest, "size": path.stat().st_size},
}
Path(output_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
PY
