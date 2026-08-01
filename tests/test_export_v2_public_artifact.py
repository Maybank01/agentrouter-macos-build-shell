from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "export_v2_public_artifact.py"
SOURCE_SHA = "a" * 40
CARRIER_SHA = "b" * 40
VERSION = "0.2.4"
RUN_ID = "42"


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class PublicArtifactExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.private = self.root / "private"
        self.public = self.root / "public"
        self.private.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_export(self, *, build_status: int = 0) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(self.private),
                str(self.public),
                SOURCE_SHA,
                VERSION,
                "production-release",
                str(build_status),
                RUN_ID,
                CARRIER_SHA,
                "macos",
                "arm64",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def write_success_receipt(self, *, extra_artifact: str | None = None) -> set[str]:
        names = {
            f"agentrouter-desktop-{VERSION}-mac-arm64.dmg",
            f"agentrouter-desktop-{VERSION}-mac-arm64.zip",
            "latest-mac.yml",
        }
        if extra_artifact:
            names.add(extra_artifact)
        artifacts = []
        for index, name in enumerate(sorted(names), start=1):
            payload = f"artifact-{index}".encode()
            (self.private / name).write_bytes(payload)
            artifacts.append({"name": name, "size": len(payload), "sha256": digest(payload)})
        receipt = {
            "schemaVersion": 1,
            "carrier": {"repository": "test", "sha": CARRIER_SHA, "runId": RUN_ID},
            "sourceSha": SOURCE_SHA,
            "clientVersion": VERSION,
            "platform": "macos",
            "arch": "arm64",
            "mode": "production-release",
            "artifacts": artifacts,
            "gates": {
                "sourceShaExact": True,
                "desktopVersionExact": True,
                "gateProxyRegression": True,
                "developerIdSigned": True,
                "notarized": True,
                "gatekeeper": True,
                "stapled": True,
                "dmgContainsVerifiedApp": True,
                "dmgIntegrity": True,
            },
        }
        (self.private / "build-receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        (self.private / "build-phase.json").write_text('{"phase":"completed"}\n', encoding="utf-8")
        return names

    def test_exports_only_allowlisted_release_files_and_receipts(self) -> None:
        names = self.write_success_receipt()
        (self.private / "build.log").write_text("private compiler log", encoding="utf-8")

        completed = self.run_export()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            {path.name for path in self.public.iterdir()},
            names | {"build-receipt.json", "carrier-artifact-receipt.json"},
        )
        carrier = json.loads((self.public / "carrier-artifact-receipt.json").read_text())
        self.assertEqual(carrier["publicationBoundary"], "public-release-artifacts-only")
        self.assertTrue(carrier["releasable"])
        self.assertNotIn("encryption", carrier)
        self.assertNotIn("private compiler log", json.dumps(carrier))

    def test_rejects_artifact_outside_public_allowlist(self) -> None:
        self.write_success_receipt(extra_artifact="build.log")

        completed = self.run_export()

        self.assertEqual(completed.returncode, 1)
        self.assertEqual({path.name for path in self.public.iterdir()}, {"carrier-artifact-receipt.json"})
        carrier = json.loads((self.public / "carrier-artifact-receipt.json").read_text())
        self.assertFalse(carrier["releasable"])
        self.assertIn("outside the public allow-list", carrier["exportError"])

    def test_failed_build_exports_diagnostic_receipt_without_raw_log(self) -> None:
        secret_line = "APPLE_API_KEY=should-never-be-public ETIMEDOUT"
        (self.private / "build.log").write_text(secret_line, encoding="utf-8")
        (self.private / "build-phase.json").write_text('{"phase":"desktop-package"}\n', encoding="utf-8")

        completed = self.run_export(build_status=1)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual({path.name for path in self.public.iterdir()}, {"carrier-artifact-receipt.json"})
        payload = (self.public / "carrier-artifact-receipt.json").read_text()
        carrier = json.loads(payload)
        self.assertEqual(carrier["publicationBoundary"], "diagnostic-only")
        self.assertFalse(carrier["releasable"])
        self.assertEqual(carrier["lastBuildPhase"], "desktop-package")
        self.assertNotIn(secret_line, payload)
        self.assertIn("network", carrier["failureDiagnostic"]["signals"])


if __name__ == "__main__":
    unittest.main()
