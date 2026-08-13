import Foundation

/// Default budget `Sandbox.create` / `waitForReady` allow for provisioning.
public let defaultWaitForReady: TimeInterval = 5 * 60
private let readyPollInterval: TimeInterval = 2

/// Primary entry point for sandbox lifecycle and operations.
///
/// ```swift
/// let sandbox = try await Sandbox.create(.init(image: "ubuntu:24.04"))
/// let result = try await sandbox.commands.run("echo hi")
/// print(result.stdout)
/// try await sandbox.kill()
/// ```
public final class Sandbox: @unchecked Sendable {
    /// Cloud sandbox ID (format: `dep-...`).
    public let sandboxId: String
    public let commands: Commands
    public let files: Files
    private let client: HeyoClient
    private var cachedInfo: SandboxInfo?

    private init(client: HeyoClient, sandboxId: String, initialInfo: SandboxInfo?) {
        self.client = client
        self.sandboxId = sandboxId
        self.commands = Commands(client: client, sandboxId: sandboxId)
        self.files = Files(client: client, sandboxId: sandboxId)
        self.cachedInfo = initialInfo
    }

    private struct CreateResponse: Decodable {
        let id: String
    }

    /// Create a new sandbox and (by default) wait for it to leave the
    /// `provisioning` state. Pass `waitForReady: 0` to return immediately.
    public static func create(
        _ options: SandboxCreateOptions = SandboxCreateOptions(),
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Sandbox {
        let client = HeyoClient(clientOptions)
        let created: CreateResponse = try await client.request(
            "/sandbox-deploy", method: "POST", body: buildDeployRequest(options))
        let sandbox = Sandbox(client: client, sandboxId: created.id, initialInfo: nil)
        let wait = options.waitForReady ?? defaultWaitForReady
        if wait > 0 {
            _ = try await sandbox.waitForReady(timeout: wait)
        }
        return sandbox
    }

    /// Reattach to an existing sandbox by ID. Issues no network call by itself.
    public static func connect(
        _ sandboxId: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) -> Sandbox {
        Sandbox(client: HeyoClient(clientOptions), sandboxId: sandboxId, initialInfo: nil)
    }

    /// Tar+gzip a local directory and upload it as a sandbox archive. Returns
    /// the new `ar-…` id, suitable for `Sandbox.create(.init(archiveId:))`.
    public static func archiveDir(
        _ localPath: String,
        options: ArchiveDirOptions = ArchiveDirOptions(),
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> ArchiveResult {
        try await archiveDirImpl(localPath, options: options, clientOptions: clientOptions)
    }

    /// Create a sandbox via the local heyvm API's native
    /// `POST /sandboxes/from-archive` path. **Local heyvm API only** — pass
    /// `HeyoClient.local()`-style `clientOptions`; the cloud does not serve this
    /// route. When `s3ArchiveKey` is omitted the workspace starts empty.
    ///
    /// The returned instance works like any other ``Sandbox``: its instance
    /// methods use the cloud-dialect compatibility routes, which the local
    /// daemon also serves.
    public static func createFromArchive(
        _ options: SandboxFromArchiveOptions,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Sandbox {
        let client = HeyoClient(clientOptions)
        let body = JSONValue.object(droppingNil: [
            "name": .string(options.name),
            "image": .string(options.image),
            "s3_archive_key": options.s3ArchiveKey.map(JSONValue.string),
            "sandbox_path": options.sandboxPath.map(JSONValue.string),
            "backend_type": options.driver.map(JSONValue.string),
            "start_command": options.startCommand.map(JSONValue.string),
            "working_directory": options.workingDirectory.map(JSONValue.string),
            "env_vars": options.envVars.map { .object($0.mapValues(JSONValue.string)) },
            "setup_hooks": options.setupHooks.map { .array($0.map(JSONValue.string)) },
            "open_ports": options.openPorts.map { .array($0.map(JSONValue.int)) },
            "ttl_seconds": options.ttlSeconds.map(JSONValue.int),
            "size_class": options.sizeClass.map { .string($0.rawValue) },
        ])
        let created: CreateResponse = try await client.request(
            "/sandboxes/from-archive", method: "POST", body: body)
        let sandbox = Sandbox(client: client, sandboxId: created.id, initialInfo: nil)
        let wait = options.waitForReady ?? defaultWaitForReady
        if wait > 0 {
            _ = try await sandbox.waitForReady(timeout: wait)
        }
        return sandbox
    }

    /// List all deployed sandboxes the caller can see.
    public static func list(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [SandboxInfo] {
        let client = HeyoClient(clientOptions)
        return try await client.request("/deployed-sandboxes")
    }

    private struct PublicImagesResponse: Decodable {
        let images: [PublicImage]?
    }

    /// List public images available to deploy. Pass the returned `id` or `name`
    /// as the `image` option to ``create(_:clientOptions:)``.
    public static func listPublicImages(
        backend: SandboxDriver? = nil,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [PublicImage] {
        let client = HeyoClient(clientOptions)
        let resp: PublicImagesResponse = try await client.request(
            "/public-images", query: ["backend": backend?.rawValue])
        return resp.images ?? []
    }

    /// Most recent cached info, or `nil` if none has been fetched.
    public var info: SandboxInfo? { cachedInfo }

    /// Fetch the latest server-side info for this sandbox. The cloud has no
    /// per-sandbox detail endpoint; the list endpoint is authoritative.
    @discardableResult
    public func getInfo() async throws -> SandboxInfo {
        let all: [SandboxInfo] = try await client.request("/deployed-sandboxes")
        guard let row = all.first(where: { $0.id == sandboxId }) else {
            throw HeyoError.notFound("Sandbox \(sandboxId) not found")
        }
        cachedInfo = row
        return row
    }

    /// Block until the sandbox transitions out of `provisioning`. Resolves on
    /// `running`, throws ``HeyoError/sandboxFailed(sandboxId:reason:)`` on
    /// `failed`, throws ``HeyoError/timeout(_:)`` after `timeout`.
    @discardableResult
    public func waitForReady(
        timeout: TimeInterval = defaultWaitForReady
    ) async throws -> SandboxInfo {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let info: SandboxInfo
            do {
                info = try await getInfo()
            } catch let HeyoError.notFound(msg) {
                // Right after create the row may not yet be visible. Keep
                // polling until the deadline.
                if Date() < deadline {
                    try await sleep(readyPollInterval)
                    continue
                }
                throw HeyoError.notFound(msg)
            }

            switch info.status {
            case .running:
                return info
            case .failed:
                throw HeyoError.sandboxFailed(sandboxId: sandboxId, reason: info.errorMessage)
            case .provisioning, .unknown:
                break
            default:
                // stopped / paused / cold-stored: valid but not actively
                // running. Return so the caller can start/restore it.
                return info
            }

            if Date() >= deadline {
                throw HeyoError.timeout(
                    "Sandbox \(sandboxId) did not become ready within \(Int(timeout))s (status=\(info.status.rawValue))")
            }
            try await sleep(readyPollInterval)
        }
    }

    /// Permanently delete this sandbox. Idempotent — a 404 is treated as success.
    public func kill() async throws {
        do {
            try await client.send(
                "/deployed-sandboxes/\(pathEscape(sandboxId))", method: "DELETE")
        } catch HeyoError.notFound {
            return
        }
    }

    /// Stop the sandbox without deleting it.
    public func stop() async throws {
        try await client.send("/sandbox/\(pathEscape(sandboxId))/stop")
    }

    /// Start a previously stopped sandbox.
    public func start() async throws {
        try await client.send("/sandbox/\(pathEscape(sandboxId))/start")
    }

    /// Restart the sandbox (stop + start).
    public func restart() async throws {
        try await client.send("/deployed-sandboxes/\(pathEscape(sandboxId))/restart")
    }

    /// Update the sandbox's TTL in seconds. Pass `0` for unlimited (if allowed).
    public func setTimeout(ttlSeconds: Int) async throws {
        try await client.send(
            "/deployed-sandboxes/\(pathEscape(sandboxId))/ttl",
            body: .object(["ttl_seconds": .int(ttlSeconds)]))
    }

    /// Resize to a different size class. The sandbox is restarted server-side.
    public func resize(_ sizeClass: SandboxSize) async throws {
        try await client.send(
            "/deployed-sandboxes/\(pathEscape(sandboxId))/resize",
            body: .object(["size_class": .string(sizeClass.rawValue)]))
    }

    /// Grow the persistent workspace disk to `diskSizeGb` GiB.
    ///
    /// Grow-only — the cloud rejects a size at or below the current one — and
    /// supported on Firecracker and KVM backends only. The sandbox is resized
    /// offline, which invalidates any existing snapshot.
    ///
    /// Throws ``HeyoError/invalidArgument(_:)`` when `diskSizeGb` is outside the
    /// server's accepted 1...250 GiB range.
    public func resizeDisk(_ diskSizeGb: Int) async throws {
        guard (1...250).contains(diskSizeGb) else {
            throw HeyoError.invalidArgument("diskSizeGb must be an integer between 1 and 250 GiB")
        }
        try await client.send(
            "/deployed-sandboxes/\(pathEscape(sandboxId))/resize",
            body: .object(["disk_size_gb": .int(diskSizeGb)]))
    }

    /// Cold-store the sandbox (frees compute, keeps state in S3).
    public func checkpoint() async throws {
        try await client.send("/deployed-sandboxes/\(pathEscape(sandboxId))/checkpoint")
    }

    /// Restore a cold-stored sandbox back to a running backend.
    public func restore() async throws {
        try await client.send("/deployed-sandboxes/\(pathEscape(sandboxId))/restore")
    }

    /// Replace the contents of a mount with the contents of an archive.
    public func replaceMount(archiveId: String, sandboxPath: String = "/workspace") async throws {
        try await client.send(
            "/deployed-sandboxes/\(pathEscape(sandboxId))/replace-mount",
            body: .object([
                "archive_id": .string(archiveId),
                "sandbox_path": .string(sandboxPath),
            ]))
    }

    /// Public URL for a bound port, or `nil` if the port isn't exposed.
    public func getHost(port: Int) async throws -> String? {
        let info = try await getInfo()
        return info.urls.first(where: { $0.port == port })?.url
    }

    private struct RawBoundUrl: Decodable {
        let subdomain: String
        let hostname: String?
        let url: String?
        let port: Int
        let isPublic: Bool?
        enum CodingKeys: String, CodingKey {
            case subdomain, hostname, url, port
            case isPublic = "is_public"
        }
    }

    /// Bind a port and return its public URL.
    public func bindPort(_ port: Int, isPublic: Bool? = nil) async throws -> BoundUrl {
        let body = JSONValue.object(droppingNil: [
            "sandbox_id": .string(sandboxId),
            "port": .int(port),
            "is_public": isPublic.map(JSONValue.bool),
        ])
        let raw: RawBoundUrl = try await client.request(
            "/proxy-endpoints/for-deployed", method: "POST", body: body)
        let hostname = raw.hostname
            ?? raw.url.flatMap { URLComponents(string: $0)?.host }
            ?? raw.subdomain
        return BoundUrl(
            subdomain: raw.subdomain,
            hostname: hostname,
            url: raw.url ?? "https://\(hostname)",
            port: raw.port,
            isPublic: raw.isPublic ?? true)
    }

    /// Fetch the sandbox's stdout/stderr log buffer. **Local heyvm API only** —
    /// the cloud does not serve this route and returns
    /// ``HeyoError/notFound(_:)``.
    public func logs(_ options: SandboxLogsOptions = SandboxLogsOptions()) async throws -> SandboxLogs {
        try await client.request(
            "/sandboxes/\(pathEscape(sandboxId))/logs",
            query: [
                "limit": options.limit.map(String.init),
                "offset": options.offset.map(String.init),
                "source": options.source?.rawValue,
                "level": options.level?.rawValue,
            ])
    }

    /// Snapshot the sandbox's disk into a reusable image — bake an environment
    /// once, then pass the returned `name` as the `image` of future creates.
    ///
    /// **Local heyvm API only.** The cloud's nearest equivalent is
    /// ``checkpoint()``, which cold-stores rather than producing an image.
    public func snapshotToImage(name: String) async throws -> SnapshotImageInfo {
        try await client.request(
            "/sandboxes/\(pathEscape(sandboxId))/snapshot-image",
            method: "POST",
            body: .object(["name": .string(name)]))
    }

    /// Open a persistent interactive shell. The returned ``ShellSession`` holds
    /// a real PTY-attached `bash` server-side, so `cd`, env mutations, and
    /// TTY-only programs (vim, top) work normally. The session reconnects
    /// automatically on transient drops within a ~60s grace window.
    public func shell(_ options: ShellOptions = ShellOptions()) async throws -> ShellSession {
        try await ShellSession.open(client: client, sandboxId: sandboxId, options: options)
    }

    /// Request an SSH-over-P2P shell session for this sandbox. The cloud starts
    /// an iroh proxy in front of the sandbox's SSH port and returns a `heyo://`
    /// connection ticket. Dial it (P2P) to a local TCP port, then SSH to that
    /// port to get an interactive shell.
    ///
    /// This is the path the `heyvm` CLI uses for deployed sandboxes; it does not
    /// rely on the cloud's WebSocket `shell-stream` proxy. Optionally pass SSH
    /// public keys to authorize for key-based auth.
    public func requestShellSession(
        sshPublicKeys: [String] = []
    ) async throws -> ShellSessionTicket {
        let raw: RawShellSession = try await client.request(
            "/deployed-sandboxes/\(pathEscape(sandboxId))/shell-session",
            method: "POST",
            body: .object(["ssh_public_keys": .array(sshPublicKeys.map(JSONValue.string))]))
        return ShellSessionTicket(
            connectionUrl: raw.connectionUrl, sshHost: raw.sshHost, sshPort: raw.sshPort)
    }

    private struct RawShellSession: Decodable {
        let connectionUrl: String
        let sshHost: String?
        let sshPort: Int?
        enum CodingKeys: String, CodingKey {
            case connectionUrl = "connection_url"
            case sshHost = "ssh_host"
            case sshPort = "ssh_port"
        }
    }
}

/// Result of ``Sandbox/requestShellSession(sshPublicKeys:)``: a `heyo://` iroh
/// ticket fronting the sandbox's SSH port, plus the backend SSH target (for
/// diagnostics).
public struct ShellSessionTicket: Sendable {
    /// `heyo://…` iroh ticket to dial over P2P.
    public let connectionUrl: String
    /// Backend SSH host (informational; the client reaches SSH via the tunnel).
    public let sshHost: String?
    /// Backend SSH port (informational).
    public let sshPort: Int?
}

// MARK: - Helpers

private func sleep(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Map `SandboxCreateOptions` onto the cloud `/sandbox-deploy` request body.
private func buildDeployRequest(_ options: SandboxCreateOptions) -> JSONValue {
    var body: [String: JSONValue] = [
        "region": .string(options.region?.rawValue ?? "US"),
        "image": .string(options.image ?? "ubuntu:24.04"),
        "size_class": .string(options.sizeClass?.rawValue ?? "small"),
        "open_ports": .array((options.openPorts ?? []).map(JSONValue.int)),
    ]
    // Driver omitted when unset: the cloud infers it from the resolved image.
    if let driver = options.driver { body["driver"] = .string(driver.rawValue) }
    if let name = options.name { body["name"] = .string(name) }
    if let archiveId = options.archiveId { body["archive_id"] = .string(archiveId) }
    if let startCommand = options.startCommand { body["start_command"] = .string(startCommand) }
    if let ttl = options.ttlSeconds { body["ttl_seconds"] = .int(ttl) }
    if let disk = options.diskSizeGb { body["disk_size_gb"] = .int(disk) }
    if let wd = options.workingDirectory { body["working_directory"] = .string(wd) }
    if let env = options.envVars { body["env_vars"] = .object(env.mapValues(JSONValue.string)) }
    if let hooks = options.setupHooks { body["setup_hooks"] = .array(hooks.map(JSONValue.string)) }
    // `daemonId` is camelCase on the wire (matches the cloud handler's rename).
    if let daemonId = options.daemonId { body["daemonId"] = .string(daemonId) }
    return .object(body)
}
