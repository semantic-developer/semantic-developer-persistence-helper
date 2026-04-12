# Remote Persistence Helper

`semantic-developer-helper` is the remote-side persistence subsystem used when
persisted session is enabled for a remote connection.

It is a user-space helper, not a system service. The app installs it into the
remote user's home directory and talks to it over SSH.

## What It Does

The helper owns:

- PTY allocation
- shell process launch
- session detach and reconnect behavior
- bounded replay for recent output after reattach
- a user-space daemon and Unix socket on the remote host

The app still owns:

- SSH authentication
- terminal emulation
- local scrollback and rendering
- saved connection policy and UI

## Remote Layout

Default remote install paths:

- binary: `~/.semantic-developer/bin/semantic-developer-helper`
- daemon socket: `~/.semantic-developer/persistence-helper.sock`

The helper daemon is started on demand. It is not registered in `systemd` or
`launchd`.

## CLI Entry Points

On the remote host, the helper supports:

```bash
~/.semantic-developer/bin/semantic-developer-helper --hello
```

Print protocol version, helper version, and supported capabilities.

```bash
~/.semantic-developer/bin/semantic-developer-helper --stdio
```

Open the protocol bridge used by the app. This also auto-starts the daemon if
it is not already running.

```bash
~/.semantic-developer/bin/semantic-developer-helper --daemon
```

Run the background daemon directly.

## Operational Checks

Check that the helper is installed:

```bash
ls -l ~/.semantic-developer/bin/semantic-developer-helper
file ~/.semantic-developer/bin/semantic-developer-helper
```

Check whether the daemon socket exists:

```bash
ls -l ~/.semantic-developer/persistence-helper.sock
```

Check running helper processes:

```bash
pgrep -af semantic-developer-helper
ps -ef | grep semantic-developer-helper
```

Typical process shapes:

- a long-lived `semantic-developer-helper --daemon`
- a short-lived `semantic-developer-helper --stdio` while a client is attached

Check helper responsiveness:

```bash
~/.semantic-developer/bin/semantic-developer-helper --hello
printf '{\"id\":\"1\",\"method\":\"hello\"}\n' | ~/.semantic-developer/bin/semantic-developer-helper --stdio
```

## Session Semantics

Persisted sessions are helper-managed remote PTY/shell processes.

In the app:

- `Detach` disconnects the client but leaves the remote session alive
- `End Session/Detach` closes the remote persisted session and disconnects the
  client

Because of that, the helper daemon or its managed shell process may still be
running after the app disconnects.

## Packaging

The app bundles target-specific helper artifacts and uploads the correct one
for the remote host when available.

Expected bundled artifact names:

- `semantic-developer-helper-linux-x86_64`
- `semantic-developer-helper-linux-arm64`
- `semantic-developer-helper-macos-x86_64`
- `semantic-developer-helper-macos-arm64`

Artifacts staged in this repo now:

- `semantic-developer-helper-linux-x86_64`
- `semantic-developer-helper-linux-arm64`
- `semantic-developer-helper-macos-arm64`

That means persisted-session flows can install directly from a bundled binary on:

- typical x86_64 Linux hosts
- ARM64 Linux hosts such as a Raspberry Pi running a 64-bit distro
- Apple Silicon macOS hosts

Hosts without a staged bundled binary still fall back to the packaged helper
source archive when the remote machine has a working Swift toolchain.

Packaging details live in:

- [HelperArtifacts README](../Sources/RemotePersistenceBootstrap/Resources/HelperArtifacts/README.md)

## Debugging Notes

If persisted connect fails, useful checks are:

1. Confirm the helper binary exists on the remote host.
2. Run `--hello` directly on the remote host.
3. Confirm the socket exists after `--stdio` or `--daemon`.
4. Check for a running daemon PID with `pgrep -af semantic-developer-helper`.
5. Check the app-side debug log in the simulator or app container at:
   `Library/Application Support/SemanticDeveloper/debug.log`
