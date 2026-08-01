#!/usr/bin/env python3
"""Export only public AgentRouter V0.2 release artifacts from a carrier build.

The private build directory may contain logs and intermediate evidence.  This
script never archives that directory.  It validates the machine-readable build
receipt, copies an explicit allow-list of customer release files, and writes a
non-sensitive carrier receipt for the 10G publisher.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_PHASE_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object: {path.name}")
    return value


def last_build_phase(private_root: Path) -> str | None:
    path = private_root / "build-phase.json"
    if not path.is_file():
        return None
    try:
        phase = read_json(path).get("phase")
    except (OSError, json.JSONDecodeError, RuntimeError):
        return None
    return phase if isinstance(phase, str) and SAFE_PHASE_RE.fullmatch(phase) else None


def failure_diagnostic(private_root: Path) -> dict[str, object] | None:
    path = private_root / "build.log"
    if not path.is_file():
        return None
    payload = path.read_bytes()
    text = payload.decode("utf-8", errors="replace")
    patterns = {
        "apple-signing": r"(?i)(codesign|code signing|Developer ID Application|errSecInternalComponent)",
        "apple-notarization": r"(?i)(notari[sz]|notarytool|stapler)",
        "apple-credentials": r"(?i)(API key|issuer|authentication credentials).*(invalid|missing|failed|not found)",
        "certificate-chain": r"(?i)(unable to build chain|certificate chain|CSSMERR_TP_NOT_TRUSTED)",
        "secure-timestamp": r"(?i)(timestamp service|secure timestamp).*(failed|unavailable|error)",
        "entitlements": r"(?i)entitlements?.*(invalid|failed|error|malformed)",
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
    return {
        "schemaVersion": 1,
        "progress": next(
            (name for name, pattern in progress_patterns if re.search(pattern, text)),
            "unknown",
        ),
        "signals": sorted(name for name, pattern in patterns.items() if re.search(pattern, text)),
        "logSha256": hashlib.sha256(payload).hexdigest(),
    }


def expected_names(platform: str, arch: str, version: str) -> tuple[set[str], re.Pattern[str] | None]:
    if platform == "windows":
        installer = f"agentrouter-desktop-{version}-windows-x64.exe"
        return {installer, f"{installer}.blockmap", "latest.yml"}, None
    manifest = "latest-x64-mac.yml" if arch == "x64" else "latest-mac.yml"
    stem = f"agentrouter-desktop-{version}-mac-{arch}"
    optional = re.compile(rf"^{re.escape(stem)}\.(?:dmg|zip)\.blockmap$")
    return {f"{stem}.dmg", f"{stem}.zip", manifest}, optional


def validate_and_export(
    private_root: Path,
    public_root: Path,
    *,
    source_sha: str,
    client_version: str,
    mode: str,
    run_id: int,
    carrier_sha: str,
    platform: str,
    arch: str,
) -> dict[str, object]:
    receipt_path = private_root / "build-receipt.json"
    receipt = read_json(receipt_path)
    identity = {
        "sourceSha": source_sha,
        "clientVersion": client_version,
        "platform": platform,
        "arch": arch,
        "mode": mode,
    }
    for key, expected in identity.items():
        if receipt.get(key) != expected:
            raise RuntimeError(f"build receipt {key} mismatch")
    carrier = receipt.get("carrier")
    if not isinstance(carrier, dict) or carrier.get("sha") != carrier_sha:
        raise RuntimeError("build receipt carrier SHA mismatch")
    receipt_run = carrier.get("runId")
    if receipt_run not in (None, "", str(run_id), run_id):
        raise RuntimeError("build receipt run ID mismatch")
    if last_build_phase(private_root) != "completed":
        raise RuntimeError("build phase is not completed")

    gates = receipt.get("gates")
    if not isinstance(gates, dict):
        raise RuntimeError("build receipt gates are missing")
    common_gates = ("sourceShaExact", "desktopVersionExact", "gateProxyRegression")
    if any(gates.get(name) is not True for name in common_gates):
        raise RuntimeError("common carrier gates are incomplete")
    if platform == "windows":
        if gates.get("artifactGuard") is not True or gates.get("differentialBlockmap") is not True:
            raise RuntimeError("Windows artifact gates are incomplete")
    elif mode == "production-release":
        required = (
            "developerIdSigned",
            "notarized",
            "gatekeeper",
            "stapled",
            "dmgContainsVerifiedApp",
            "dmgIntegrity",
        )
        if any(gates.get(name) is not True for name in required):
            raise RuntimeError("production macOS trust gates are incomplete")
    elif gates.get("internalOnly") is not True:
        raise RuntimeError("unsigned macOS probe is not marked internal-only")

    required_names, optional_pattern = expected_names(platform, arch, client_version)
    raw_artifacts = receipt.get("artifacts")
    if not isinstance(raw_artifacts, list):
        raise RuntimeError("build receipt artifact list is missing")
    exported: list[dict[str, object]] = []
    sources: list[tuple[Path, str]] = []
    seen: set[str] = set()
    for item in raw_artifacts:
        if not isinstance(item, dict):
            raise RuntimeError("invalid build receipt artifact entry")
        name = item.get("name")
        if not isinstance(name, str) or Path(name).name != name or name in seen:
            raise RuntimeError("unsafe or duplicate artifact name")
        if name not in required_names and not (optional_pattern and optional_pattern.fullmatch(name)):
            raise RuntimeError(f"artifact is outside the public allow-list: {name}")
        source = private_root / name
        if source.is_symlink() or not source.is_file() or source.stat().st_size <= 0:
            raise RuntimeError(f"release artifact is missing or unsafe: {name}")
        digest = sha256(source)
        size = source.stat().st_size
        if item.get("sha256") != digest or item.get("size") != size:
            raise RuntimeError(f"release artifact hash/size mismatch: {name}")
        exported.append({"name": name, "size": size, "sha256": digest})
        sources.append((source, name))
        seen.add(name)
    missing = sorted(required_names - seen)
    if missing:
        raise RuntimeError(f"required public artifacts are missing: {', '.join(missing)}")

    for source, name in sources:
        shutil.copy2(source, public_root / name)
    shutil.copy2(receipt_path, public_root / "build-receipt.json")
    return {
        "schemaVersion": 2,
        "publicationBoundary": "public-release-artifacts-only",
        "carrierSha": carrier_sha,
        "sourceSha": source_sha,
        "clientVersion": client_version,
        "mode": mode,
        "platform": platform,
        "arch": arch,
        "buildStatus": 0,
        "runId": run_id,
        "releasable": platform == "macos" and mode == "production-release",
        "artifacts": exported,
        "buildReceipt": {
            "name": "build-receipt.json",
            "size": (public_root / "build-receipt.json").stat().st_size,
            "sha256": sha256(public_root / "build-receipt.json"),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("private_root", type=Path)
    parser.add_argument("public_root", type=Path)
    parser.add_argument("source_sha")
    parser.add_argument("client_version")
    parser.add_argument("mode", choices=("unsigned-probe", "production-release"))
    parser.add_argument("build_status", type=int)
    parser.add_argument("run_id", type=int)
    parser.add_argument("carrier_sha")
    parser.add_argument("platform", choices=("windows", "macos"))
    parser.add_argument("arch", choices=("x64", "arm64"))
    args = parser.parse_args()

    if not SHA_RE.fullmatch(args.source_sha) or not SHA_RE.fullmatch(args.carrier_sha):
        raise SystemExit("source and carrier SHA must be exactly 40 lowercase hex characters")
    if not VERSION_RE.fullmatch(args.client_version):
        raise SystemExit("client version must be major.minor.patch")
    if args.platform == "windows" and args.arch != "x64":
        raise SystemExit("Windows public carrier supports x64 only")

    private_root = args.private_root.resolve()
    public_root = args.public_root.resolve()
    public_root.mkdir(parents=True, exist_ok=True)
    if any(public_root.iterdir()):
        raise SystemExit("public output root must be empty")
    base = {
        "schemaVersion": 2,
        "publicationBoundary": "diagnostic-only",
        "carrierSha": args.carrier_sha,
        "sourceSha": args.source_sha,
        "clientVersion": args.client_version,
        "mode": args.mode,
        "platform": args.platform,
        "arch": args.arch,
        "buildStatus": args.build_status,
        "runId": args.run_id,
        "releasable": False,
    }
    phase = last_build_phase(private_root)
    if phase:
        base["lastBuildPhase"] = phase
    diagnostic = failure_diagnostic(private_root)
    if diagnostic:
        base["failureDiagnostic"] = diagnostic

    output_path = public_root / "carrier-artifact-receipt.json"
    if args.build_status != 0:
        output_path.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
        return 0

    try:
        result = validate_and_export(
            private_root,
            public_root,
            source_sha=args.source_sha,
            client_version=args.client_version,
            mode=args.mode,
            run_id=args.run_id,
            carrier_sha=args.carrier_sha,
            platform=args.platform,
            arch=args.arch,
        )
    except Exception as exc:
        base["exportError"] = str(exc)[:500]
        output_path.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")
        print(f"public artifact export rejected: {exc}", file=sys.stderr)
        return 1
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
