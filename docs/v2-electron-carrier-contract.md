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

The public workflow uploads only an AES-256-CBC encrypted archive and a public
encrypted-artifact receipt.  The encrypted archive contains package artifacts,
the platform build receipt and private build log.  Retention is one day.

No workflow publishes GitHub Releases, Client feeds, Runtime manifests,
Cloudflare objects or production pointers.  Promotion must reuse verified
bytes through the AgentRouter 10G publisher.
