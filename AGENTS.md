# Maintainer invariants

- This is a public, standalone builder—not an XMRig fork and not a mining
  supervisor. Never add wallets, pool credentials, private keys, or secrets.
- Treat `locks/build.lock.json` as a reviewed trust decision. A source key,
  commit/tree, dependency tree, patch, workflow, toolchain, or security-policy
  change requires review; a patch/workflow/policy change also increments the
  global recipe.
- The donation patch may change only `src/donate.h` and exactly the two compiled
  constants. Source commit/tree and the complete patched header hash must match.
- Every reused action is pinned by a full commit SHA. Builds use only a
  GitHub-hosted `windows-2022` runner, no repository secrets, and least-privilege
  job permissions.
- Publish a draft first, attach and download-verify every allowlisted asset, and
  only then publish. Never replace an existing tag or asset. Repository release
  immutability must be enabled before the first publication.
- Release contents must include the runtime, exact patched corresponding source,
  canonical manifest, checksums, licences/notices, SPDX document, and offline
  provenance bundle for the runtime ZIP.
- Unit tests are offline. A hosted build is the only test permitted to fetch and
  compile XMRig or contact GitHub release APIs.

