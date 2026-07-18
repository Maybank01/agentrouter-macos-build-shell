#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_assignment(value: str, label: str) -> tuple[str, str]:
    name, separator, assigned = value.partition("=")
    if not separator or not name or not assigned:
        raise argparse.ArgumentTypeError(f"{label} must use name=value")
    return name, assigned


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--carrier-sha", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--mode", choices=("unsigned-probe", "production-release"), required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--main-architectures", required=True)
    parser.add_argument("--sidecar-architectures", required=True)
    parser.add_argument("--macos-version", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--node-version", required=True)
    parser.add_argument("--npm-version", required=True)
    parser.add_argument("--rustc-version", required=True)
    parser.add_argument("--cargo-version", required=True)
    parser.add_argument("--signing-authority", default="")
    parser.add_argument("--team-id", default="")
    parser.add_argument("--updater-key-id", default="")
    parser.add_argument("--app-notary-status", default="not-submitted")
    parser.add_argument("--dmg-notary-status", default="not-submitted")
    parser.add_argument("--dmg-notary-id", default="")
    parser.add_argument("--artifact", action="append", default=[])
    parser.add_argument("--gate", action="append", default=[])
    args = parser.parse_args()

    artifacts: dict[str, dict[str, object]] = {}
    for assignment in args.artifact:
        role, raw_path = parse_assignment(assignment, "artifact")
        path = Path(raw_path)
        if not path.is_file():
            raise SystemExit(f"artifact does not exist: {path}")
        artifacts[role] = {
            "name": path.name,
            "sha256": sha256(path),
            "size": path.stat().st_size,
        }

    gates: dict[str, bool] = {}
    for assignment in args.gate:
        name, raw_value = parse_assignment(assignment, "gate")
        if raw_value not in {"true", "false"}:
            raise SystemExit(f"gate {name} must be true or false")
        gates[name] = raw_value == "true"

    production_required_gates = {
        "appUniversal",
        "sidecarUniversal",
        "appCodeSignature",
        "appNotarizedRequirement",
        "appGatekeeper",
        "appStapled",
        "updaterUniversal",
        "updaterAppCodeSignature",
        "updaterAppNotarizedRequirement",
        "updaterAppGatekeeper",
        "updaterAppStapled",
        "updaterSignaturePresent",
        "updaterKeyIdMatchesConfig",
        "teamIdentifierMatches",
        "dmgIntegrity",
        "dmgCodeSignature",
        "dmgGatekeeper",
        "dmgStapled",
    }
    production_ready = (
        args.mode == "production-release"
        and production_required_gates.issubset(gates)
        and all(gates[name] for name in production_required_gates)
        and args.app_notary_status == "Accepted"
        and args.dmg_notary_status == "Accepted"
        and {"dmg", "updaterArchive", "updaterSignature"}.issubset(artifacts)
    )

    receipt = {
        "schemaVersion": 2,
        "createdAtUtc": datetime.now(timezone.utc).isoformat(),
        "carrier": {
            "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
            "sha": args.carrier_sha,
            "runId": int(os.environ["GITHUB_RUN_ID"]) if os.environ.get("GITHUB_RUN_ID") else None,
        },
        "sourceSha": args.source_sha,
        "clientVersion": args.version,
        "mode": args.mode,
        "target": "universal-apple-darwin",
        "appBundle": args.app_name,
        "mainArchitectures": args.main_architectures.split(),
        "sidecarArchitectures": args.sidecar_architectures.split(),
        "runner": {
            "name": os.environ.get("RUNNER_NAME", "local"),
            "architecture": os.environ.get("RUNNER_ARCH", "unknown"),
            "imageOS": os.environ.get("ImageOS", "unknown"),
            "imageVersion": os.environ.get("ImageVersion", "unknown"),
            "macOSVersion": args.macos_version,
            "xcodeVersion": args.xcode_version,
        },
        "toolchain": {
            "node": args.node_version,
            "npm": args.npm_version,
            "rustc": args.rustc_version,
            "cargo": args.cargo_version,
        },
        "signing": {
            "state": "developer-id-signed-and-notarized" if args.mode == "production-release" else "unsigned",
            "authority": args.signing_authority or None,
            "teamIdentifier": args.team_id or None,
            "updaterKeyId": args.updater_key_id or None,
        },
        "notarization": {
            "app": {
                "status": args.app_notary_status,
                "submission": "tauri-bundler" if args.mode == "production-release" else None,
            },
            "dmg": {
                "status": args.dmg_notary_status,
                "submissionId": args.dmg_notary_id or None,
            },
        },
        "gates": gates,
        "artifacts": artifacts,
        "productionReady": production_ready,
        "internalOnly": not production_ready,
    }
    args.output.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
