# xmrig-nodonate-builder

This repository produces a narrowly scoped Windows x64 XMRig build whose two
compiled donation constants are zero. It is not affiliated with XMRig and does
not weaken XMRig's GPL obligations or the value of supporting upstream.

The trust model is fail-closed: a reviewed signed upstream commit/tree, pinned
XMRig signing key, pinned `xmrig-deps` tree, exact two-line patch, constrained
hosted toolchain, runtime tests, deterministic package inventory, and GitHub
artifact provenance. A version label by itself is never trusted.

Each published immutable release contains:

- `xmrig-<version>-windows-x64-nodonate-r<recipe>.zip`
- the exact patched corresponding source archive
- a canonical build manifest and SPDX file
- `SHA256SUMS`, XMRig's GPL licence, and third-party notices
- an offline Sigstore bundle bound to the runtime ZIP

The daily workflow checks the highest stable official release at minute 17. A
new upstream version pauses publication until its signed identity and build lock
are reviewed. Workflow dispatch uses the same gates. A heartbeat changes only
`upstream-state.json` when the observed release changes or the prior heartbeat
is 40 days old.

Before the first release, an administrator must create this repository as
public, enable GitHub Actions, grant workflow write permission, and enable
immutable releases. Those settings are security gates and are not guessed or
silently changed by the workflow.

See [the verified build procedure](docs/BUILDING.md) for exact mechanics.
