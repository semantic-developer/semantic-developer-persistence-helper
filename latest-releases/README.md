# Latest Releases

Stage release binaries here before attaching them to GitHub Releases.

Use one directory per helper version:

```text
latest-releases/
  v0.1.1/
    semantic-developer-helper-macos-arm64
    semantic-developer-helper-linux-x86_64
    semantic-developer-helper-linux-arm64
    SHA256SUMS
    RELEASE_NOTES.md
```

Recommended rules:

- Only place binaries here that correspond to a tagged source release.
- Include SHA-256 checksums for every binary.
- Keep release notes with protocol version, helper version, build date, and
  supported platforms.
- The Semantic Developer app should reference a pinned version and checksum.

Example checksum command:

```bash
shasum -a 256 semantic-developer-helper-* > SHA256SUMS
```
