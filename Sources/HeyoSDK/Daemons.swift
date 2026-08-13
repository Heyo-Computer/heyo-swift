import Foundation

/// Status the cloud reports for a registered daemon.
public enum DaemonStatus: String, Codable, Sendable {
    case online, stale, offline
}

public struct DaemonInfo: Codable, Sendable {
    /// Stable id assigned when the daemon first registered (`hd-…`).
    public let id: String
    /// Human-readable label set by the daemon (defaults to hostname).
    public let name: String?
    public let status: DaemonStatus
    /// RFC 3339 timestamp of the most recent heartbeat.
    public let lastSeenAt: String
    /// RFC 3339 timestamp from initial registration.
    public let createdAt: String
}

public struct DaemonSandboxInfo: Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let image: String
    public let backendType: String?
    public let isDeployed: Bool?
}

public struct DaemonSandboxList: Sendable {
    public let daemonId: String
    public let daemonName: String?
    public let sandboxes: [DaemonSandboxInfo]
}

/// User-owned heyvmd daemons registered with the cloud. Note: the daemon rows
/// use camelCase wire fields (`lastSeenAt`, `createdAt`), unlike most cloud
/// endpoints — the `Codable` keys reflect that.
public enum Daemons {
    private struct ListResponse: Decodable { let daemons: [DaemonInfo] }

    /// List every daemon the authenticated user has registered.
    public static func list(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [DaemonInfo] {
        let client = HeyoClient(clientOptions)
        let resp: ListResponse = try await client.request("/me/daemons")
        return resp.daemons
    }

    /// Fetch a single daemon.
    public static func get(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> DaemonInfo {
        let client = HeyoClient(clientOptions)
        return try await client.request("/me/daemons/\(pathEscape(id))")
    }

    private struct TicketResponse: Decodable { let connectionUrl: String }

    /// The daemon's iroh `heyo://` ticket. This SDK cannot dial it natively (no
    /// P2P) — hand the ticket to a native component (`heyvm connect <ticket>`),
    /// then point a ``HeyoClient`` `baseURL` at the bound local port. Throws a
    /// 409 ``HeyoError/api(status:message:body:)`` when no ticket is registered.
    public static func connectionTicket(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> String {
        let client = HeyoClient(clientOptions)
        let resp: TicketResponse = try await client.request(
            "/me/daemons/\(pathEscape(id))/connection-ticket")
        return resp.connectionUrl
    }

    /// Open an interactive shell on the daemon's **host machine** (not a
    /// sandbox) — the terminal equivalent of SSHing into the box that runs
    /// `heyvmd`.
    ///
    /// Unlike ``connectionTicket(_:clientOptions:)`` (a free, direct path onto a
    /// sandbox), a host shell is a paid, gated resource routed through the cloud
    /// so the gates and metering apply:
    /// - the daemon must be started with `--allow-host-shell`;
    /// - the host must be assigned to one of your networks (see
    ///   ``Network/addHost(daemonId:deviceName:)``) — otherwise the cloud
    ///   returns 403;
    /// - your account must have a positive credit balance — otherwise 402;
    /// - while the session is live it burns `host_shell_second` credits.
    ///
    /// Returns an open ``ShellSession`` with the same API as
    /// ``Sandbox/shell(_:)``.
    ///
    /// - Parameters:
    ///   - daemonId: The daemon whose host to open a shell on (`hd-…`).
    ///   - options: PTY sizing / env / cwd / reconnect tuning.
    public static func hostShell(
        _ daemonId: String,
        shell options: ShellOptions = ShellOptions(),
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> ShellSession {
        let client = HeyoClient(clientOptions)
        return try await ShellSession.open(
            client: client,
            path: "/me/daemons/\(pathEscape(daemonId))/host/shell-stream",
            options: options)
    }

    private struct SandboxesResponse: Decodable {
        let daemonId: String
        let daemonName: String?
        let sandboxes: [RawSandbox]
        struct RawSandbox: Decodable {
            let id: String
            let name: String
            let status: String
            let image: String
            let backendType: String?
            let isDeployed: Bool?
            enum CodingKeys: String, CodingKey {
                case id, name, status, image
                case backendType = "backend_type"
                case isDeployed = "is_deployed"
            }
        }
    }

    /// Sandboxes the daemon currently exposes, fetched through the cloud→daemon
    /// channel.
    public static func listSandboxes(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> DaemonSandboxList {
        let client = HeyoClient(clientOptions)
        let resp: SandboxesResponse = try await client.request(
            "/me/daemons/\(pathEscape(id))/sandboxes")
        return DaemonSandboxList(
            daemonId: resp.daemonId,
            daemonName: resp.daemonName,
            sandboxes: resp.sandboxes.map {
                DaemonSandboxInfo(
                    id: $0.id, name: $0.name, status: $0.status, image: $0.image,
                    backendType: $0.backendType, isDeployed: $0.isDeployed)
            })
    }

    /// Unregister a daemon. Idempotent on 404.
    public static func delete(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws {
        let client = HeyoClient(clientOptions)
        do {
            try await client.send("/me/daemons/\(pathEscape(id))", method: "DELETE")
        } catch HeyoError.notFound {
            return
        }
    }
}
