# AgentRouter macOS Build Shell

This repository is a public CI carrier. It contains no AgentRouter Client product source and no runtime artifacts.

The manually dispatched workflow checks out one immutable commit from the private AgentRouter Client repository with a read-only deploy key, builds a universal macOS application on a GitHub-hosted runner, creates a DMG, and uploads only an encrypted evidence archive.

Required repository secrets:

- `PRIVATE_SOURCE_SSH_KEY`: read-only deploy key for `Maybank01/agentrouter-client-packaging`.
- `ARTIFACT_ENCRYPTION_KEY`: one-time high-entropy key used to encrypt the private build output before upload.

The shell intentionally has no license. Public visibility is used only to host the runner definition; it does not grant reuse rights to AgentRouter product code.
