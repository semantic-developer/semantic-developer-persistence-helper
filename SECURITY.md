# Security Policy

## Reporting Security Issues

Please report security issues privately by email:

```text
john@semanticdeveloper.com
```

Do not open a public issue for vulnerabilities involving command execution,
session attachment, PTY handling, replay data, or install/update behavior.

## Scope

This repository contains the remote helper that can run on a user's SSH host.
Security-sensitive areas include:

- PTY process launch and cleanup
- persisted session attach/reconnect behavior
- replay buffering
- helper install/update assumptions
- wire protocol parsing
- filesystem paths under `~/.semantic-developer`

## Non-Goals

The helper should not store:

- SSH passwords
- private keys
- private-key passphrases
- App Store purchase state
- analytics or tracking identifiers

If a future change requires storing new sensitive data, update this policy and
the public README before release.
