#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${PACKAGING_MODE:-}" != "production-release" ]]; then
  echo "production signing preflight must run only for production-release" >&2
  exit 64
fi

if [[ "${GITHUB_REF:-}" != "refs/heads/main" ]]; then
  echo "::error::production-release is allowed only from the carrier main branch."
  exit 65
fi

required_names=(
  APPLE_CERTIFICATE_BASE64
  APPLE_CERTIFICATE_PASSWORD
  APPLE_API_PRIVATE_KEY_BASE64
  APPLE_API_KEY_ID
  APPLE_API_ISSUER
  APPLE_TEAM_ID
  TAURI_SIGNING_PRIVATE_KEY
)

missing=0
for name in "${required_names[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::$name is required in the production-signing environment."
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  exit 66
fi

python3 - <<'PY'
import base64
import os
import re


def decode_secret(name: str) -> bytes:
    encoded = "".join(os.environ[name].split())
    try:
        return base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise SystemExit(f"::error::{name} is not valid base64: {exc}") from None


certificate = decode_secret("APPLE_CERTIFICATE_BASE64")
if len(certificate) < 512:
    raise SystemExit("::error::APPLE_CERTIFICATE_BASE64 is too short to be a PKCS#12 archive.")

api_key = decode_secret("APPLE_API_PRIVATE_KEY_BASE64")
if b"BEGIN PRIVATE KEY" not in api_key or b"END PRIVATE KEY" not in api_key:
    raise SystemExit("::error::APPLE_API_PRIVATE_KEY_BASE64 is not a PEM private key.")

if not re.fullmatch(r"[A-Za-z0-9]{10}", os.environ["APPLE_API_KEY_ID"]):
    raise SystemExit("::error::APPLE_API_KEY_ID must be a 10-character key identifier.")
if not re.fullmatch(r"[0-9a-fA-F-]{36}", os.environ["APPLE_API_ISSUER"]):
    raise SystemExit("::error::APPLE_API_ISSUER must be an issuer UUID.")
if not re.fullmatch(r"[A-Za-z0-9]{10}", os.environ["APPLE_TEAM_ID"]):
    raise SystemExit("::error::APPLE_TEAM_ID must be a 10-character team identifier.")
if len(os.environ["TAURI_SIGNING_PRIVATE_KEY"].strip()) < 64:
    raise SystemExit("::error::TAURI_SIGNING_PRIVATE_KEY does not look like a Tauri updater private key.")
PY

echo "Protected production credential contract passed."
