#!/usr/bin/env bash
set -Eeuo pipefail

KEYCHAIN_PATH="$RUNNER_TEMP/agentrouter-v2-electron.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP/agentrouter-v2-developer-id.p12"
API_KEY_PATH="$RUNNER_TEMP/agentrouter-v2-api-key.p8"
ORIGINAL_DEFAULT="$RUNNER_TEMP/agentrouter-v2-original-default-keychain.txt"
ORIGINAL_LIST="$RUNNER_TEMP/agentrouter-v2-original-keychains.txt"

if [[ -s "$ORIGINAL_DEFAULT" ]]; then
  ORIGINAL="$(sed -e 's/^[[:space:]]*\"//' -e 's/\"[[:space:]]*$//' "$ORIGINAL_DEFAULT")"
  [[ -z "$ORIGINAL" ]] || security default-keychain -d user -s "$ORIGINAL" 2>/dev/null || true
fi
if [[ -s "$ORIGINAL_LIST" ]]; then
  KEYCHAINS=()
  while IFS= read -r KEYCHAIN; do
    [[ -z "$KEYCHAIN" ]] || KEYCHAINS+=("$KEYCHAIN")
  done < <(sed -n 's/^[[:space:]]*\"\([^\"]*\)\".*$/\1/p' "$ORIGINAL_LIST")
  [[ "${#KEYCHAINS[@]}" -eq 0 ]] || security list-keychains -d user -s "${KEYCHAINS[@]}" 2>/dev/null || true
fi
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
rm -f "$CERTIFICATE_PATH" "$API_KEY_PATH" "$ORIGINAL_DEFAULT" "$ORIGINAL_LIST"
