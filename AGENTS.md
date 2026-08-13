# AGENTS.md — `heyo-swift`

Guidance for agents working in this repository.

## Read this first: `Sources/` and `Tests/` are generated

This repo is the public distribution of `HeyoSDK`, mirrored out of the Heyo
monorepo. The code's source of truth is the monorepo's `sdk-swift/` directory
(checked out next to this repo as `../heyo/sdk-swift`).

**Do not hand-edit `Sources/`, `Tests/`, `Package.swift`, or `.gitignore` here.**
`scripts/sync-from-monorepo.sh` `rsync --delete`s over them, so local edits are
lost on the next sync. Make the change in the monorepo, then:

```bash
scripts/sync-from-monorepo.sh            # review the diff
scripts/sync-from-monorepo.sh --commit   # or auto-commit as "Sync HeyoSDK from heyo@<sha>"
HEYO_MONOREPO=/path/to/heyo scripts/sync-from-monorepo.sh   # non-sibling checkout
```

If you do not have the monorepo checked out, say so rather than editing
`Sources/` directly — a fix applied only here silently reverts.

Repo-local files are **not** synced and are edited here: `README.md`,
`CHANGELOG.md`, `LICENSE`, `.github/`, `scripts/`, and this file.

## What the SDK is

A zero-dependency Swift client for the Heyo platform (Foundation + `URLSession`
+ `Compression` only), macOS 13+, targeting feature parity with the TypeScript
(`@heyocomputer/sdk`) and Rust (`heyo-sdk`) SDKs. Covers cloud sandboxes,
persistent PTY shells, cloud SQLite databases, networks, daemons, archives, and
VM transfer receive.

There is no P2P/iroh transport in Swift and adding one is out of scope. Reach a
remote daemon through the cloud broker (`daemonId` on `Sandbox.create`), or hand
a `heyo://` ticket to a native component and point a `HeyoClient` at the local
port it binds.

## Changelog

`CHANGELOG.md` follows Keep a Changelog and the package follows SemVer. Every
synced API change gets an `[Unreleased]` entry describing the *behavior*, not
just the symbol: the route it calls, any client-side validation, and any
deliberate divergence from the TS/Rust shape (Swift does not always transliterate
the TS API). Released versions are tagged; CI runs on tags.

## Testing

```bash
swift build
swift test                            # unit tests only
HEYO_API_KEY=heyo_api_… swift test    # also runs live integration tests
```

- Integration tests self-skip when `HEYO_API_KEY` is unset. **They create and
  destroy real sandboxes and databases and cost real money.** Do not run them
  without being asked. Point at a non-default backend with `HEYO_BASE_URL`.
- `swift test` needs an XCTest-capable toolchain. Command Line Tools alone ship
  neither XCTest nor swift-testing, so on a machine without full Xcode the test
  target cannot build at all — a "no such module 'XCTest'" failure there is an
  environment gap, not a regression. `swift build` still works and is a real
  signal. CI (`.github/workflows/ci.yml`, macos-15 + latest-stable Xcode) runs
  the full suite on push and PR.

## Conventions worth knowing before you edit upstream

- No global key-decoding strategy: the cloud mixes snake_case with camelCase, so
  each `Codable` declares explicit `CodingKeys`.
- Decode defensively (`decodeIfPresent` + defaults); server-side enums decode
  unknown values to an `unknown` case instead of throwing.
- Everything thrown is `HeyoError` — a closed enum callers switch over. No raw
  `URLResponse` or `URLError` escapes the public API.
