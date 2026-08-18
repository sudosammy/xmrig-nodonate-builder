# Verified build procedure

The release workflow resolves the highest semantic, stable official XMRig
release. If that release differs from the reviewed lock, the workflow stops and
requires a lock review; it never guesses a new source identity.

For the locked release it imports the bundled XMRig signing key into an isolated
keyring, fetches the lightweight upstream tag, and runs `git verify-commit` on
the tag's exact commit. The tag, commit, tree, signer fingerprint, dependency
commit/tree, patch hash, and complete patched header hash must all match.

The two-line patch is applied with zero context only after the complete upstream
tree has matched its pin. The build then verifies that `src/donate.h` is the sole
modified file and that both compiled donation constants are exactly zero.

The hosted build uses `windows-2022`, Visual Studio 2022, the pinned v143 tools,
Windows SDK, CMake, and `xmrig-deps`, without `BUILD_STATIC`. The hosted image is
mutable, so the manifest records its exact image version; this project claims
reviewed inputs and verifiable provenance, not bit-for-bit reproducibility.

Before packaging, the workflow checks the executable version/architecture,
the pinned WinRing driver signature, a loopback-only `--dry-run`, `DONATE 0%`,
and the four-file runtime allowlist. ZIP entry times are fixed for deterministic
packaging. The source archive contains the patched Git tree plus this build
procedure, the exact patch, and lock.

Local tests are intentionally offline:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Repository.ps1
```

The full build requires GitHub Actions identity variables and a matching hosted
runner; `Invoke-VerifiedBuild.ps1` refuses an ordinary workstation.

