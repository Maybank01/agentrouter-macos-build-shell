#!/usr/bin/env python3
"""Build one exact AgentRouter V0.2 Electron Client target.

This script runs inside the public carrier after an exact private-source SHA
has been checked out.  It deliberately copies only release artifacts and a
receipt into the private output root; source and dependency trees never enter
the carrier artifact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def command(name: str) -> str:
    """Resolve npm-installed command shims on Windows without shell=True."""
    candidate = f"{name}.cmd" if os.name == "nt" else name
    resolved = shutil.which(candidate)
    if not resolved:
        raise RuntimeError(f"required command is unavailable: {candidate}")
    return resolved


def run(args: list[str], *, cwd: Path, env: dict[str, str] | None = None, capture: bool = False) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return completed.stdout.strip() if capture else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_artifact(source: Path, output: Path) -> dict[str, object]:
    if not source.is_file() or source.stat().st_size <= 0:
        raise RuntimeError(f"missing release artifact: {source}")
    destination = output / source.name
    shutil.copy2(source, destination)
    return {
        "name": destination.name,
        "size": destination.stat().st_size,
        "sha256": sha256(destination),
    }


def record_phase(output: Path, phase: str) -> None:
    (output / "build-phase.json").write_text(
        json.dumps({"phase": phase}, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def locate_asar_command(workspace: Path) -> Path:
    suffix = ".cmd" if os.name == "nt" else ""
    command = workspace / "node_modules" / ".bin" / f"asar{suffix}"
    if not command.is_file():
        raise RuntimeError(f"asar command missing: {command}")
    return command


def verify_arch(binary: Path, expected: str) -> str:
    arches = run(["lipo", "-archs", str(binary)], cwd=binary.parent, capture=True).split()
    normalized = "x86_64" if expected == "x64" else "arm64"
    if arches != [normalized]:
        raise RuntimeError(f"unexpected architectures for {binary}: {arches}, expected {normalized}")
    return normalized


def find_macos_app(dist: Path) -> Path:
    apps = sorted(
        path
        for path in dist.rglob("*.app")
        if path.is_dir()
        and (path / "Contents" / "Info.plist").is_file()
        and not any(parent.suffix == ".app" for parent in path.parents)
    )
    if len(apps) != 1:
        raise RuntimeError(f"expected one unpacked macOS app, found {len(apps)}")
    return apps[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", choices=("windows", "macos"), required=True)
    parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    parser.add_argument("--mode", choices=("unsigned-probe", "production-release"), required=True)
    parser.add_argument("--carrier-sha", required=True)
    args = parser.parse_args()

    source = args.source_root.resolve()
    output = args.output_root.resolve()
    if not SHA_RE.fullmatch(args.source_sha):
        raise RuntimeError("source SHA must be exactly 40 lowercase hex characters")
    if not VERSION_RE.fullmatch(args.version):
        raise RuntimeError("version must be major.minor.patch")
    if args.platform == "windows" and args.arch != "x64":
        raise RuntimeError("the V0.2 Windows carrier currently supports x64 only")

    actual_sha = run(["git", "rev-parse", "HEAD"], cwd=source, capture=True)
    if actual_sha != args.source_sha:
        raise RuntimeError(f"private source mismatch: expected {args.source_sha}, got {actual_sha}")

    workspace = source / "product" / "agentrouter-v2"
    desktop = workspace / "apps" / "desktop"
    server = workspace / "server"
    package = json.loads((desktop / "package.json").read_text(encoding="utf-8"))
    if package.get("version") != args.version:
        raise RuntimeError(
            f"desktop version mismatch: expected {args.version}, got {package.get('version')}"
        )

    output.mkdir(parents=True, exist_ok=True)
    record_phase(output, "initializing")
    staging = output / ".staging"
    staging.mkdir(parents=True, exist_ok=True)
    cli_name = "multica.exe" if args.platform == "windows" else "multica"
    cli = staging / cli_name
    goos = "windows" if args.platform == "windows" else "darwin"
    goarch = "amd64" if args.arch == "x64" else "arm64"
    built_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    ldflags = f"-X main.version={args.version} -X main.commit={args.source_sha[:12]} -X main.date={built_at}"

    record_phase(output, "gateproxy-test")
    run(["go", "test", "./internal/gateproxy"], cwd=server, env=os.environ.copy())
    env = os.environ.copy()
    env.update({"CGO_ENABLED": "0", "GOOS": goos, "GOARCH": goarch})
    record_phase(output, "daemon-build")
    run(
        [
            "go",
            "build",
            "-mod=readonly",
            "-trimpath",
            "-buildvcs=false",
            "-ldflags",
            ldflags,
            "-o",
            str(cli),
            "./cmd/multica",
        ],
        cwd=server,
        env=env,
    )

    record_phase(output, "dependency-install")
    pnpm = command("pnpm")
    run([pnpm, "install", "--frozen-lockfile"], cwd=workspace)
    package_env = os.environ.copy()
    package_env["AGENTROUTER_BUILD_VERSION"] = args.version
    package_env["AGENTROUTER_MULTICA_CLI_BINARY"] = str(cli)
    if args.platform == "windows" or args.mode == "unsigned-probe":
        package_env["CSC_IDENTITY_AUTO_DISCOVERY"] = "false"
    if args.mode == "unsigned-probe":
        package_env.pop("APPLE_TEAM_ID", None)
    elif args.platform == "macos":
        required = ("APPLE_TEAM_ID", "APPLE_API_KEY", "APPLE_API_KEY_ID", "APPLE_API_ISSUER", "CSC_NAME")
        missing = [name for name in required if not package_env.get(name)]
        if missing:
            raise RuntimeError(f"production macOS signing environment is incomplete: {', '.join(missing)}")

    platform_flag = "--win" if args.platform == "windows" else "--mac"
    record_phase(output, "desktop-package")
    run(
        [
            pnpm,
            "--filter",
            "agentrouter-desktop",
            "package",
            "--",
            platform_flag,
            f"--{args.arch}",
            "--publish",
            "never",
        ],
        cwd=workspace,
        env=package_env,
    )

    dist = desktop / "dist"
    artifacts: list[dict[str, object]] = []
    gates: dict[str, object] = {
        "sourceShaExact": True,
        "desktopVersionExact": True,
        "gateProxyRegression": True,
        "bundledCliVersion": args.version,
    }

    if args.platform == "windows":
        record_phase(output, "windows-artifact-guard")
        installer = dist / f"agentrouter-desktop-{args.version}-windows-x64.exe"
        blockmap = dist / f"{installer.name}.blockmap"
        update_manifest = dist / "latest.yml"
        asar_list = output / "app-asar-list.txt"
        asar_command = locate_asar_command(workspace)
        asar = dist / "win-unpacked" / "resources" / "app.asar"
        asar_entries = run([str(asar_command), "list", str(asar)], cwd=workspace, capture=True)
        asar_list.write_text(asar_entries + "\n", encoding="utf-8")
        guard_receipt = output / "artifact-guard-receipt.json"
        run(
            [
                sys.executable,
                str(source / "scripts" / "v2_desktop_artifact_guard.py"),
                "--dist",
                str(dist),
                "--platform",
                "windows",
                "--version",
                args.version,
                "--source-sha",
                args.source_sha,
                "--asar-list",
                str(asar_list),
                "--receipt",
                str(guard_receipt),
            ],
            cwd=source,
        )
        for path in (installer, blockmap, update_manifest):
            artifacts.append(copy_artifact(path, output))
        gates.update({"artifactGuard": True, "differentialBlockmap": True})
    else:
        record_phase(output, "macos-artifact-discovery")
        normalized_arch = "x86_64" if args.arch == "x64" else "arm64"
        dmg = dist / f"agentrouter-desktop-{args.version}-mac-{args.arch}.dmg"
        zip_path = dist / f"agentrouter-desktop-{args.version}-mac-{args.arch}.zip"
        update_name = "latest-x64-mac.yml" if args.arch == "x64" else "latest-mac.yml"
        update_manifest = dist / update_name
        app = find_macos_app(dist)
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        executable = app / "Contents" / "MacOS" / str(info["CFBundleExecutable"])
        bundled_cli = app / "Contents" / "Resources" / "bin" / "multica"
        record_phase(output, "macos-main-architecture")
        if verify_arch(executable, args.arch) != normalized_arch:
            raise RuntimeError("main executable architecture verification failed")
        record_phase(output, "macos-daemon-architecture")
        if verify_arch(bundled_cli, args.arch) != normalized_arch:
            raise RuntimeError("bundled CLI architecture verification failed")
        record_phase(output, "macos-dmg-integrity")
        run(["hdiutil", "verify", str(dmg)], cwd=dist)
        if args.mode == "production-release":
            record_phase(output, "macos-app-signature")
            run(["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)], cwd=dist)
            record_phase(output, "macos-app-notarized-requirement")
            run(["codesign", "--test-requirement==notarized", "--verify", "--verbose=4", str(app)], cwd=dist)
            record_phase(output, "macos-app-gatekeeper")
            run(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], cwd=dist)
            record_phase(output, "macos-app-staple")
            run(["xcrun", "stapler", "validate", "-v", str(app)], cwd=dist)
            record_phase(output, "macos-dmg-signature")
            run(["codesign", "--verify", "--verbose=4", str(dmg)], cwd=dist)
            record_phase(output, "macos-dmg-staple")
            run(["xcrun", "stapler", "validate", "-v", str(dmg)], cwd=dist)
            record_phase(output, "macos-dmg-gatekeeper")
            run(
                ["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", str(dmg)],
                cwd=dist,
            )
            gates.update({"developerIdSigned": True, "notarized": True, "gatekeeper": True, "stapled": True})
        else:
            gates.update({"developerIdSigned": False, "notarized": False, "internalOnly": True})
        record_phase(output, "macos-artifact-copy")
        for path in (dmg, zip_path, update_manifest):
            artifacts.append(copy_artifact(path, output))
        for optional in sorted(dist.glob(f"agentrouter-desktop-{args.version}-mac-{args.arch}.*.blockmap")):
            artifacts.append(copy_artifact(optional, output))
        gates.update({"mainExecutableArch": normalized_arch, "bundledCliArch": normalized_arch, "dmgIntegrity": True})

    receipt = {
        "schemaVersion": 1,
        "carrier": {
            "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
            "sha": args.carrier_sha,
            "runId": os.environ.get("GITHUB_RUN_ID"),
        },
        "sourceSha": args.source_sha,
        "clientVersion": args.version,
        "platform": args.platform,
        "arch": args.arch,
        "mode": args.mode,
        "builtAt": built_at,
        "artifacts": artifacts,
        "gates": gates,
    }
    (output / "build-receipt.json").write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    shutil.rmtree(staging)
    record_phase(output, "completed")
    print(f"V0.2 Electron build verified: {args.platform}/{args.arch} {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
