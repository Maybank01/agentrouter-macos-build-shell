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
# Keep the temporary archive under the relative public-output root.  Git Bash
# interprets a raw `D:\\...` RUNNER_TEMP as an rsync-style host path when it is
# handed to tar, so using the workspace-relative path is portable on both
# Windows and macOS runners.
ARCHIVE_PATH="$PUBLIC_ROOT/.agentrouter-v2-${PLATFORM}-${ARCH}-${RUN_ID}.tar.gz"
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
  "$ARCH" \
  "$PRIVATE_ROOT/build-phase.json" \
  "$PRIVATE_ROOT/build.log" <<'PY'
import hashlib
import json
import re
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
    phase_path,
    build_log_path,
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
phase_file = Path(phase_path)
if phase_file.is_file():
    try:
        phase = json.loads(phase_file.read_text(encoding="utf-8")).get("phase")
    except (OSError, json.JSONDecodeError):
        phase = None
    if isinstance(phase, str) and phase.replace("-", "").isalnum() and len(phase) <= 64:
        receipt["lastBuildPhase"] = phase

# Build output is deliberately encrypted with the private evidence archive.
# Expose only allow-listed, non-secret diagnostic signals so maintainers can
# distinguish a packaging failure without publishing source paths, signing
# identities, credentials, or raw logs from the private repository.
build_log_file = Path(build_log_path)
if int(build_status) != 0 and build_log_file.is_file():
    log_bytes = build_log_file.read_bytes()
    log_text = log_bytes.decode("utf-8", errors="replace")
    signal_patterns = {
        "apple-signing": r"(?i)(codesign|code signing|errSecInternalComponent)",
        "apple-notarization": r"(?i)(notari[sz]|notarytool|stapler)",
        "apple-credentials": r"(?i)(API key|issuer|authentication credentials).*(invalid|missing|failed|not found)",
        "certificate-chain": r"(?i)(unable to build chain|certificate chain|CSSMERR_TP_NOT_TRUSTED)",
        "secure-timestamp": r"(?i)(timestamp service|secure timestamp).*(failed|unavailable|error)",
        "entitlements": r"(?i)entitlements?.*(invalid|failed|error|malformed)",
        "invalid-configuration": r"(?i)(InvalidConfigurationError|configuration.*invalid)",
        "missing-file": r"(?i)(no such file or directory|ENOENT|file not found)",
        "native-dependency": r"(?i)(node-gyp|prebuild-install|native module).*(failed|error|unsupported)",
        "disk-space": r"(?i)(no space left|ENOSPC)",
        "process-killed": r"(?i)(SIGKILL|exit code 137|out of memory|ENOMEM)",
        "network": r"(?i)(ECONNRESET|ETIMEDOUT|ENETUNREACH|socket hang up)",
        "electron-builder-exec": r"(?i)(ERR_ELECTRON_BUILDER_CANNOT_EXECUTE|failedTask=build|command failed)",
    }
    progress_patterns = (
        ("dmg", r"(?i)(building\s+target=DMG|target=dmg)"),
        ("zip", r"(?i)(building\s+target=zip|target=zip)"),
        ("notarizing", r"(?i)notari[sz]ing"),
        ("signing", r"(?i)(signing\s+file=|signing.*identity=|codesign)"),
        ("packaging", r"(?i)packaging\s+platform=darwin"),
        ("bundle-cli", r"(?i)bundling CLI"),
        ("renderer-build", r"(?i)(electron-vite|built in)"),
    )
    signals = sorted(
        name for name, pattern in signal_patterns.items() if re.search(pattern, log_text)
    )
    progress = next(
        (name for name, pattern in progress_patterns if re.search(pattern, log_text)),
        "unknown",
    )
    receipt["failureDiagnostic"] = {
        "schemaVersion": 1,
        "progress": progress,
        "signals": signals,
        "logSha256": hashlib.sha256(log_bytes).hexdigest(),
    }
Path(output_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
PY
