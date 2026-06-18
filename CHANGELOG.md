# Changelog

All notable changes to HeyoSDK (Swift) are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `Sandbox.requestShellSession(sshPublicKeys:)` — request an SSH-over-P2P shell
  session, returning a `heyo://` iroh connection ticket (`ShellSessionTicket`).

### Fixed
- `ShellSession` now authenticates the WebSocket upgrade with the
  `Authorization` header (matching the Rust SDK) instead of a `?token=` query
  parameter, which the cloud rejects on the `shell-stream` route.
