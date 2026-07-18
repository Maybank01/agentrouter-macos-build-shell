#!/usr/bin/env python3
"""Check that a Tauri updater signature carries the configured public-key id.

Tauri creates the signature itself during the build. This check is deliberately
named as a key-id check: it catches signing with a rotated or unrelated key, but
the installed Client remains the final cryptographic verifier of update bytes.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path


def minisign_payload(text: str, label: str) -> bytes:
    payload_lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip()
        and not line.startswith("untrusted comment:")
        and not line.startswith("trusted comment:")
    ]
    if not payload_lines:
        raise ValueError(f"{label} has no minisign payload")
    try:
        return base64.b64decode(payload_lines[0], validate=True)
    except Exception as exc:
        raise ValueError(f"{label} has an invalid minisign payload") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    args = parser.parse_args()

    config = json.loads(args.config.read_text(encoding="utf-8"))
    encoded_public_key = config["plugins"]["updater"]["pubkey"]
    public_key_text = base64.b64decode(encoded_public_key, validate=True).decode("utf-8")
    public_key = minisign_payload(public_key_text, "configured updater public key")
    encoded_signature = "".join(
        args.signature.read_text(encoding="utf-8").split()
    )
    signature_text = base64.b64decode(encoded_signature, validate=True).decode("utf-8")
    signature = minisign_payload(signature_text, "updater signature")

    if len(public_key) < 42 or len(signature) < 74:
        raise SystemExit("updater public key or signature payload is truncated")

    public_key_id = public_key[2:10]
    signature_key_id = signature[2:10]
    if public_key_id != signature_key_id:
        raise SystemExit("updater signature key id does not match the Client configuration")

    print(public_key_id.hex())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
