# Third-party notices

XMRig is copyright its contributors and licensed under GPL-3.0-or-later. Every
release carries XMRig's `LICENSE` and the exact patched corresponding source.

`xmrig-deps` supplies pinned binary builds of libuv, OpenSSL, and hwloc. Their
upstream licences and notices remain in the pinned dependency tree. The build
manifest records the exact dependency commit and tree.

`WinRing0x64.sys` is copied unchanged from the verified XMRig source tree. Its
Authenticode signer subject and certificate thumbprint are enforced by the
build lock.

GitHub Actions and GitHub CLI are used only in the build/publishing service;
they are not included in the XMRig runtime archive.

