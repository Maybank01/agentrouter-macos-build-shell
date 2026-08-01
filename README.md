# AgentRouter macOS Build Shell

## V0.2 Electron carrier

`build-v2-electron-client.yml` is the current manual carrier for exact-SHA
Windows x64 and macOS arm64/x64 Electron package probes.  It never publishes a
release and uploads encrypted evidence only.  See
`docs/v2-electron-carrier-contract.md`.

The older `build-private-client.yml` workflow remains a V0.1 Tauri historical
carrier and must not be used for a V0.2 build.

This repository is a public CI carrier. It contains no AgentRouter Client product source, signing material, Codex Runtime, or decrypted release artifacts.

The manually dispatched workflow checks out one immutable commit from the private Client repository with a read-only deploy key and offers two explicit channels:

- `unsigned-probe`: builds a universal Apple Silicon + Intel app and an unsigned DMG for internal compilation checks.
- `production-release`: builds a universal app, signs it with Developer ID Application, notarizes and staples it, generates a Tauri-signed updater archive, then signs, notarizes, staples, and Gatekeeper-checks the DMG.

All private compiler logs and output files are encrypted before the public workflow uploads them. GitHub artifact retention is one day. Nothing in this repository publishes a Client release or changes an update-channel pointer.

Repository secrets:

- `PRIVATE_SOURCE_SSH_KEY`: read-only deploy key for `Maybank01/agentrouter-client-packaging`.
- `ARTIFACT_ENCRYPTION_KEY`: high-entropy key used to encrypt all private output before upload.

Apple and Tauri signing secrets belong only to the protected `production-signing` GitHub Environment. See [the release runbook](docs/macos-release-runbook.md) for the secret contract, dispatch command, evidence gates, and cleanup procedure.

The shell intentionally has no license. Public visibility is used only to host the runner definition; it does not grant reuse rights to AgentRouter product code.
