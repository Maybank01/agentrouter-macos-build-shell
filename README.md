# AgentRouter macOS Build Shell

## V0.2 Electron carrier

`build-v2-electron-client.yml` is the current manual carrier for exact-SHA
Windows x64 and macOS arm64/x64 Electron package probes.  It never publishes a
release. Successful jobs upload only an explicit allow-list of customer-facing
release files plus machine-readable receipts; private source, compiler logs,
intermediate output, signing material and diagnostics never enter the release
artifact. See
`docs/v2-electron-carrier-contract.md`.

The older `build-private-client.yml` workflow remains a V0.1 Tauri historical
carrier and must not be used for a V0.2 build.

This repository is a public CI carrier. It contains no AgentRouter Client product source, signing material, Codex Runtime, or decrypted release artifacts.

The manually dispatched workflow checks out one immutable commit from the private Client repository with a read-only deploy key and offers two explicit channels:

- `unsigned-probe`: builds a universal Apple Silicon + Intel app and an unsigned DMG for internal compilation checks.
- `production-release`: builds a universal app, signs it with Developer ID Application, notarizes and staples it, generates a Tauri-signed updater archive, then signs, notarizes, staples, and Gatekeeper-checks the DMG.

The current V0.2 workflow exports only final public release files after exact
receipt, hash and trust-gate validation. Failed jobs upload one sanitized
diagnostic receipt with no raw log. GitHub artifact retention is one day.
Nothing in this repository publishes a Client release or changes an
update-channel pointer.

Repository secrets:

- `PRIVATE_SOURCE_SSH_KEY`: read-only deploy key for `Maybank01/agentrouter-client-packaging`.

The V0.2 workflow does not use an artifact-encryption secret. The historical
V0.1 Tauri workflow retains its separate encrypted-evidence contract and must
not be used for a V0.2 release.

V0.2 Apple signing/notarization secrets belong only to the protected
`production-signing` GitHub Environment. Tauri signing and artifact encryption
belong only to the historical V0.1 workflow. See [the legacy release
runbook](docs/macos-release-runbook.md) for that archived contract.

The shell intentionally has no license. Public visibility is used only to host the runner definition; it does not grant reuse rights to AgentRouter product code.
