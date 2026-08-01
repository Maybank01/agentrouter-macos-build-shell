# AgentRouter V0.2 Electron carrier contract

The public carrier builds the private V0.2 Electron Client from one exact
40-character source SHA.  It is a build carrier, not an update or download
origin.

## Targets

- Windows x64 NSIS, blockmap and `latest.yml` on `windows-latest`.
- macOS arm64 DMG, ZIP and `latest-mac.yml` on `macos-14`.
- macOS x64 DMG, ZIP and `latest-x64-mac.yml` on `macos-14`.

Every target builds a matching Multica daemon with the requested Client
version embedded.  The private source checkout uses the read-only deploy key,
disables its origin after exact-SHA verification, and never enters an uploaded
artifact.

The manual `target` input defaults to `all`; `windows` and `macos` exist only
for scoped retries so one failed platform never spends minutes rebuilding a
platform whose public candidate receipt is already accepted.

## Modes

- `unsigned-probe` proves compilation, architecture, package shape, DMG
  integrity and Windows release guard behavior.  It is internal-only.
- `production-release` additionally requires the protected
  `production-signing` environment for both macOS architectures and verifies
  Developer ID signing, notarization, Gatekeeper and stapling.

Windows production publication continues to use the registered Windows
carrier and 10G publisher policy.  A GitHub-hosted Windows probe is not a
replacement for the sealed production build.

## Artifact boundary

On a successful build, the public workflow uploads only the customer-facing
release files named in `build-receipt.json`, the validated build receipt, and a
binding `carrier-artifact-receipt.json`. The exporter rejects path traversal,
symlinks, missing required files, unexpected filenames, hash/size drift,
identity drift and incomplete platform trust gates. The allow-list is:

- Windows: NSIS installer, matching blockmap and `latest.yml`.
- macOS: architecture-specific DMG, ZIP, update manifest and optional matching
  DMG/ZIP blockmaps.

Private source, compiler logs, intermediate output, unpacked apps, credentials,
signing material and raw diagnostics are never uploaded. Failed builds upload
only a sanitized diagnostic receipt containing an allow-listed phase/signal
classification and the private log hash. V0.2 has no artifact-encryption or
downstream decryption dependency. Retention is one day.

No workflow publishes GitHub Releases, Client feeds, Runtime manifests,
Cloudflare objects or production pointers.  Promotion must reuse verified
bytes through the AgentRouter 10G publisher.
