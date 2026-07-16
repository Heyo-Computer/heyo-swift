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

### Fixed
- `ShellSession` now authenticates the WebSocket upgrade with the
  `Authorization` header (matching the Rust SDK) instead of a `?token=` query
  parameter, which the cloud rejects on the `shell-stream` route.
