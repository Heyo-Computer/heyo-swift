# HeyoSDK (Swift)

Swift client for the Heyo platform — cloud sandboxes, persistent interactive
shells, cloud SQLite databases, networks, daemons, and archives. Feature parity
with the TypeScript (`@heyocomputer/sdk`) and Rust (`heyo-sdk`) SDKs.

- **Platform:** macOS 13+
- **Dependencies:** none (Foundation + `URLSession` + `Compression` only)
- **Transport:** cloud (`https://server.heyo.computer`) or a local `heyvmd` API
  (`http://127.0.0.1:34099`). P2P/iroh tunnels are not supported in Swift — reach
  remote daemons through the cloud broker by passing `daemonId` to
  `Sandbox.create`, exactly like the TS SDK.

## Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/heyo-computer/heyo-swift", from: "1.0.0")
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "HeyoSDK", package: "heyo-swift")])
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

## Quick start

Set `HEYO_API_KEY` in the environment, or pass it explicitly via
`HeyoClientOptions(apiKey:)`.

```swift
import HeyoSDK

let sandbox = try await Sandbox.create(.init(image: "ubuntu:24.04", openPorts: [3000]))

let result = try await sandbox.commands.run("echo hi")
print(result.stdout)  // "hi\n"

try await sandbox.files.write("/workspace/.env", text: "KEY=value")
let env = try await sandbox.files.readText("/workspace/.env")

try await sandbox.kill()
```

### Persistent shell

The shell holds a real PTY-attached `bash` server-side and reconnects
automatically on transient drops (≈60 s grace window with output replay), so
`cd`, env mutations, and TTY programs (vim, top) behave normally.

```swift
let shell = try await sandbox.shell(.init(cols: 120, rows: 40))

Task {
    for await chunk in shell.output {
        FileHandle.standardOutput.write(chunk)
    }
}
Task {
    for await event in shell.events {
        if case let .reconnecting(attempt, _) = event { print("reconnecting #\(attempt)") }
    }
}

try await shell.write("ls -la\n")
try await shell.resize(cols: 100, rows: 30)
await shell.close()   // graceful EOF; or shell.kill() to drop immediately
```

### Databases

```swift
let db = try await Database.create(.init(name: "notes", region: "us-east"))
try await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)")
try await db.exec("INSERT INTO t (k) VALUES (?)", args: [.text("hello")])
let rows = try await db.exec("SELECT * FROM t")
for row in rows.rows { print(row) }

// Offline editing with optimistic concurrency (bytes are gzipped):
let checkout = try await db.checkout()
let result = try await db.checkin(checkout.bytes, options: .init(expectedVersion: checkout.dataVersion))

// Mint a libsql-compatible token for a third-party driver:
let conn = try await db.connect(.init(scopes: [.read, .write]))
// conn.url + conn.authToken
```

### Archives, networks, daemons

```swift
let archive = try await Sandbox.archiveDir("./my-app")
let sandbox = try await Sandbox.create(.init(archiveId: archive.id))

let net = try await Network.default()
_ = try await net.addMember(.init(sandboxKind: .deployed, sandboxRef: sandbox.sandboxId))

let daemons = try await Daemons.list()
```

## Local daemon

```swift
let local = HeyoClientOptions(apiKey: nil, baseURL: defaultLocalBaseURL)
let sandboxes = try await Sandbox.list(clientOptions: local)
```

`HeyoClient.local()` builds an unauthenticated client for a same-machine daemon.
Some routes (`capabilities`, sandbox `logs`, `snapshotToImage`,
`createFromArchive`) are served only by the local API, matching the TS SDK.

## Errors

Everything throws `HeyoError`, a closed enum you can `switch` over:
`authentication`, `invalidArgument`, `notFound`, `api(status:message:body:)`,
`timeout`, `sandboxFailed`, `connection`, `sessionExpired`, `shellExit`,
`checkinConflict(expected:current:)`.

## Tests

```bash
swift test                                   # unit tests only (no network)
HEYO_API_KEY=heyo_api_… swift test           # also runs live integration tests
```

Integration tests skip themselves when `HEYO_API_KEY` is unset (mirroring the
Rust SDK's `#[ignore]` tests). Point at a non-default backend with
`HEYO_BASE_URL`.

> **Note:** running `swift test` requires an XCTest-capable toolchain (full
> Xcode, or a Swift toolchain that bundles XCTest). The Command Line Tools alone
> do not ship XCTest.
