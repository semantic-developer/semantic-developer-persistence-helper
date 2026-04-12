# Semantic Developer Persistence Helper

Open-source remote persistence helper for Semantic Developer.

This helper runs on a user's SSH host and owns the remote PTY used for persisted
sessions. The app talks to it over SSH stdio so a user can disconnect, reconnect,
and resume a long-running shell or AI coding tool without exposing credentials to
the helper.

## Why This Repo Exists

Semantic Developer may offer to install this helper on a remote machine when a
user enables Persisted Sessions. Keeping the helper public makes that remote code
auditable:

- users can inspect the exact process that runs on their host
- App Review can verify the helper's purpose and behavior
- releases can be tied to source, checksums, and versioned protocol changes

## What The Helper Does

- Starts and tracks remote PTY-backed shell sessions.
- Lists, creates, attaches, resizes, replays, and closes persisted sessions.
- Maintains bounded replay output for reconnect.
- Runs under the user's account, normally from:

```text
~/.semantic-developer/bin/semantic-developer-helper
```

- Communicates with the app through newline-delimited JSON over stdio.

## What The Helper Does Not Do

- It does not store SSH passwords, private keys, passphrases, or App Store data.
- It does not require root by design.
- It does not open a public network listener.
- It does not replace SSH authentication.
- It does not collect analytics.

## Repository Layout

```text
Sources/
  RemotePersistenceHelper/      # executable helper
  RemotePersistenceProtocol/    # shared protocol/version models
  SharedModels/                 # minimal shared app/helper models
  HostConfig/                   # host profile models used by protocol requests
Tests/
  RemotePersistenceHelperTests/
docs/
  REMOTE_PERSISTENCE_HELPER.md
latest-releases/
  README.md                     # staging area for release binaries/checksums
scripts/
  build-release.sh
```

## Build

```bash
swift build --product semantic-developer-helper
```

The debug binary will be at:

```text
.build/debug/semantic-developer-helper
```

For a release build:

```bash
swift build -c release --product semantic-developer-helper
```

The release binary will be at:

```text
.build/release/semantic-developer-helper
```

## Test

```bash
swift test
```

## Basic Commands

Print helper protocol information:

```bash
semantic-developer-helper --hello
```

Run the stdio bridge used by Semantic Developer:

```bash
semantic-developer-helper --stdio
```

Run the helper daemon directly:

```bash
semantic-developer-helper --daemon
```

Most users should not need to run `--daemon` manually. The stdio bridge starts
or connects to the per-user daemon as needed.

## Release Artifacts

Use `latest-releases/` to stage binaries that should be attached to GitHub
Releases. Keep each release versioned and checksumed. A typical release should
include:

```text
latest-releases/
  v0.1.0/
    semantic-developer-helper-macos-arm64
    semantic-developer-helper-linux-x86_64
    semantic-developer-helper-linux-arm64
    SHA256SUMS
    RELEASE_NOTES.md
```

The app should consume pinned release artifacts, not the latest branch state.

## Compatibility

The helper protocol version lives in:

```text
Sources/RemotePersistenceProtocol/RemotePersistenceBuildInfo.swift
```

When changing wire behavior, update the helper version, document the change in
`CHANGELOG.md`, and publish fresh checksums.

## Security Notes

- The helper should run as the logged-in SSH user.
- Install paths should remain user-writable and user-owned.
- Do not add credential storage to this repo.
- Do not add background networking unless the app design explicitly changes and
  the security model is updated.
- Keep new capabilities explicit in `RemotePersistenceCapability`.

Report security issues privately to:

```text
john@semanticdeveloper.com
```

## License

Add the license you want to publish under before making this repository public.
