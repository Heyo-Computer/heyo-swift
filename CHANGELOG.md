# Changelog

All notable changes to HeyoSDK (Swift) are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `Transfer` — receive a VM transferred from another device (the destination
  half of `heyvm transfer`). `Transfer.receive(ticket:options:clientOptions:)`
  asks the daemon to pull a `heyo://` ticket and restore it as a new sandbox,
  `Transfer.status(receiveId:clientOptions:)` reports progress, and
  `Transfer.receiveAndWait(ticket:options:timeout:clientOptions:)` polls to
  completion. Includes `ReceiveOptions`, `TransferReceiveStatus`, and
  `TransferStatus`. These routes live on the heyvm daemon, not the cloud —
  point the client at a daemon base URL.
- `SandboxSize.xlarge` size class.
- `Sandbox.requestShellSession(sshPublicKeys:)` — request an SSH-over-P2P shell
  session, returning a `heyo://` iroh connection ticket (`ShellSessionTicket`).
- `Sandbox.resizeDisk(_:)` — grow the persistent workspace disk in GiB
  (`POST /deployed-sandboxes/{id}/resize` with `disk_size_gb`). Grow-only, and
  supported on Firecracker/KVM backends only. The 1...250 GiB bound is validated
  client-side and throws `HeyoError.invalidArgument`. Compute resizing keeps its
  existing contract via `Sandbox.resize(_:)` — the cloud requires exactly one of
  `size_class` or `disk_size_gb` per request.
- `SandboxInfo.diskSizeGb` — the effective workspace disk size the backend
  reports, decoded from `disk_size_gb`.
- `NetworkMemberKind.host` — a daemon host machine, with `sandboxRef` set to the
  daemon's `hd-…` id.
- `Network.addHost(daemonId:deviceName:)` / `Network.removeHost(daemonId:)` —
  assign a daemon host to a network (and revoke it), which is what unlocks
  host-shell access to that machine.
- `Daemons.hostShell(_:shell:clientOptions:)` — open an interactive
  `ShellSession` on a daemon's **host machine** rather than a sandbox, over
  `/me/daemons/{id}/host/shell-stream`. Gated on the daemon running with
  `--allow-host-shell`, the host being a member of one of your networks (else
  403), and a positive credit balance (else 402); live sessions accrue
  `host_shell_second` usage. The TS SDK exposes this through an internal
  `ShellOptions.pathOverride`; Swift keeps `ShellOptions` free of it and routes
  through an internal `ShellSession.open(client:path:options:)` instead.
- `Network.registerService(_:clientOptions:)`,
  `Network.resolveService(name:port:clientOptions:)`, and
  `Network.removeService(name:port:clientOptions:)` — the rest of the service
  registry the TS SDK already exposed; only `listServices` and `dialService`
  were ported previously. Adds `ServiceRegistration`.
- `Sandbox.logs(_:)`, `Sandbox.snapshotToImage(name:)`, and
  `Sandbox.createFromArchive(_:clientOptions:)` — local heyvm API routes the
  README already documented as supported but which were never implemented.
  Adds `SandboxLogsOptions`, `SandboxLogs`, `SandboxLogEntry`, `LogSource`,
  `LogLevel`, `SnapshotImageInfo`, and `SandboxFromArchiveOptions`. These are
  served only by a local daemon; the cloud returns 404.

### Fixed
- `ShellSession` now authenticates the WebSocket upgrade with the
  `Authorization` header (matching the Rust SDK) instead of a `?token=` query
  parameter, which the cloud rejects on the `shell-stream` route.
