# macOS Release Runbook

## Scope

This carrier compiles one exact private source commit. It does not choose a release commit, publish to storage, update `latest.json`, or promote a release channel. Those remain separate, auditable actions after this build is downloaded and verified.

The production sequence is fixed as follows:

1. Validate the carrier branch, immutable source SHA, expected version, and protected secret contract.
2. Check out the private source using a read-only deploy key and remove its remote URL.
3. Install Node 22, stable Rust, and both macOS Rust targets.
4. Build `universal-apple-darwin` with Tauri.
5. Sign the app and its nested binaries with `Developer ID Application`, then let Tauri submit and staple the app.
6. Generate the Tauri v2 `.app.tar.gz` updater archive and its `.sig` from that final app.
7. Extract the updater archive and re-run universal-architecture, code-signing, Gatekeeper, and stapler gates against the contained app.
8. Create a DMG from the stapled app, sign the DMG, submit it with `notarytool`, staple it, and run DMG/Gatekeeper gates.
9. Write a machine-readable receipt, encrypt every private output and log, upload only ciphertext, and remove temporary signing material.

Apple requires a Developer ID-signed app, hardened runtime, secure timestamp, and notarization for direct distribution. Tauri uses a separate Minisign-compatible key pair for updater authenticity. The two signing systems are intentionally independent.

Primary references:

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Tauri v2: macOS code signing](https://v2.tauri.app/distribute/sign/macos/)
- [Tauri v2: updater signing and artifacts](https://v2.tauri.app/plugin/updater/)

## GitHub environments

The workflow maps its modes to environments:

- `unsigned-probe`: no Apple or updater signing secrets and no approval gate.
- `production-signing`: restricted to `main` and protected by a required reviewer. Apple and updater private keys live only here.

Production dispatches from any branch other than `main` are rejected both by the script and by the GitHub Environment branch policy.

## Secret contract

Repository-level secrets:

| Name | Contract |
| --- | --- |
| `PRIVATE_SOURCE_SSH_KEY` | Read-only deploy private key for the private Client repository. |
| `ARTIFACT_ENCRYPTION_KEY` | High-entropy passphrase used with AES-256-CBC, PBKDF2-SHA256, 200,000 iterations. |

`production-signing` environment secrets:

| Name | Contract |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64 of a PKCS#12 archive containing a `Developer ID Application` certificate and its private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Password of that PKCS#12 archive. |
| `APPLE_API_KEY` | Base64 of the App Store Connect API `.p8` private-key file. |
| `APPLE_API_KEY_ID` | Ten-character App Store Connect API key ID. |
| `APPLE_API_ISSUER` | App Store Connect API issuer UUID. |
| `APPLE_TEAM_ID` | Ten-character Apple Developer team ID; it must match the imported certificate. |
| `TAURI_SIGNING_PRIVATE_KEY` | Original Tauri updater private key matching `plugins.updater.pubkey` in the Client config. Do not rotate it casually. |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Optional password for the updater private key. Omit it only if the key was created without a password. |

Never put these values in a workflow input, repository file, issue, public artifact, command-line argument, or pasted log. Add them through GitHub's Environment secrets UI or `gh secret set --env production-signing`, providing the value through standard input.

## Dispatch

Unsigned compilation check:

```powershell
gh workflow run build-private-client.yml `
  --repo Maybank01/agentrouter-macos-build-shell `
  --ref main `
  -f mode=unsigned-probe `
  -f source_sha=<40-character-private-source-sha> `
  -f client_version=<version>
```

Signed production candidate:

```powershell
gh workflow run build-private-client.yml `
  --repo Maybank01/agentrouter-macos-build-shell `
  --ref main `
  -f mode=production-release `
  -f source_sha=<40-character-private-source-sha> `
  -f client_version=<version>
```

Approve the `production-signing` deployment in GitHub only after confirming the carrier SHA, source SHA, and version shown by the pending deployment.

## Download and decrypt

Download the named artifact into a dedicated directory. Set `ARTIFACT_ENCRYPTION_KEY` locally without echoing it, then decrypt:

```powershell
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 `
  -pass env:ARTIFACT_ENCRYPTION_KEY `
  -in <downloaded-file>.tar.gz.enc `
  -out private-output.tar.gz
tar -xzf private-output.tar.gz
```

Delete the public GitHub artifact after the encrypted hash and decrypted evidence have been retained in the private release evidence store.

## Acceptance gates

`build-receipt.json` is the authoritative machine-readable result. A production candidate is releasable only when all of the following are true:

- `mode` is `production-release` and `productionReady` is `true`.
- Main executable and `agentrouterctl` contain both `arm64` and `x86_64`.
- App signature, Gatekeeper assessment, and stapler validation pass.
- The updater archive contains a universal, Developer ID-signed, Gatekeeper-accepted, stapled app.
- The updater signature exists and its key ID matches the public key embedded in the selected Client source.
- The signed DMG passes `hdiutil`, code-signing, Gatekeeper, notarization, and stapler gates.
- App and DMG notarization statuses are `Accepted`.
- Artifact hashes in the receipt match the downloaded DMG, updater archive, and updater signature.

The updater key-ID gate prevents accidental signing with the wrong release key. A real old-version-to-new-version updater installation remains the final end-to-end cryptographic and behavioral acceptance test before channel promotion.

## Failure and cleanup

Compiler and signing logs are never printed publicly. On failure, decrypt `build.log`, `dmg-notarization.json` when present, and the receipts. The build script restores the runner's original keychain selection and deletes the temporary keychain, PKCS#12 file, and API `.p8` file in an exit trap; the workflow repeats deletion in an `always()` step as a second boundary.

Unsigned artifacts always have `internalOnly: true`. A successful unsigned probe is compilation evidence, never a production release.
