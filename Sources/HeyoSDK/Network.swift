import Foundation

/// Membership kind for a network member. `local` / `deployed` are
/// iroh-routable; `database_local` / `database_cloud` are discovery-only.
public enum NetworkMemberKind: String, Codable, Sendable {
    case local
    case deployed
    case databaseLocal = "database_local"
    case databaseCloud = "database_cloud"
    /// A daemon host machine (`sandboxRef` = the daemon's `hd-…` id). Assigning
    /// a host to a network is what unlocks ``Daemons/hostShell(_:shell:clientOptions:)``.
    case host
}

public struct NetworkInfo: Sendable {
    public let id: String
    public let accountId: String
    public let name: String
    public let isDefault: Bool
    public let description: String?
    public let createdAt: String
    public let updatedAt: String
}

private struct RawNetwork: Decodable {
    let id: String
    let accountId: String
    let name: String
    let isDefault: Bool
    let description: String?
    let createdAt: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey {
        case id, name, description
        case accountId = "account_id"
        case isDefault = "is_default"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    var resolved: NetworkInfo {
        NetworkInfo(
            id: id, accountId: accountId, name: name, isDefault: isDefault,
            description: description, createdAt: createdAt, updatedAt: updatedAt)
    }
}

public struct NetworkCreateOptions: Sendable {
    public var name: String
    public var description: String?
    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct NetworkUpdateOptions: Sendable {
    public var name: String?
    public var description: String?
    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct NetworkMember: Sendable {
    public let networkId: String
    public let sandboxKind: String
    public let sandboxRef: String
    public let deviceName: String?
    public let registeredAt: String
    public let lastSeenAt: String?
}

private struct RawMember: Decodable {
    let networkId: String
    let sandboxKind: String
    let sandboxRef: String
    let deviceName: String?
    let registeredAt: String
    let lastSeenAt: String?
    enum CodingKeys: String, CodingKey {
        case networkId = "network_id"
        case sandboxKind = "sandbox_kind"
        case sandboxRef = "sandbox_ref"
        case deviceName = "device_name"
        case registeredAt = "registered_at"
        case lastSeenAt = "last_seen_at"
    }
    var resolved: NetworkMember {
        NetworkMember(
            networkId: networkId, sandboxKind: sandboxKind, sandboxRef: sandboxRef,
            deviceName: deviceName, registeredAt: registeredAt, lastSeenAt: lastSeenAt)
    }
}

public struct NetworkMemberRegistration: Sendable {
    public var sandboxKind: NetworkMemberKind
    public var sandboxRef: String
    public var deviceName: String?
    public init(sandboxKind: NetworkMemberKind, sandboxRef: String, deviceName: String? = nil) {
        self.sandboxKind = sandboxKind
        self.sandboxRef = sandboxRef
        self.deviceName = deviceName
    }
}

public struct NetworkService: Sendable {
    public let id: String
    public let networkId: String
    public let name: String
    public let address: String
    public let sandboxKind: String
    public let sandboxRef: String
    public let port: Int
    public let protocolName: String
    public let status: String
    public let connectionUrl: String?
    public let lastSeenAt: String?
    public let transport: String?
}

private struct RawService: Decodable {
    let id: String
    let networkId: String
    let name: String
    let address: String
    let sandboxKind: String
    let sandboxRef: String
    let port: Int
    let proto: String
    let status: String
    let connectionUrl: String?
    let lastSeenAt: String?
    let transport: String?
    enum CodingKeys: String, CodingKey {
        case id, name, address, port, status, transport
        case networkId = "network_id"
        case sandboxKind = "sandbox_kind"
        case sandboxRef = "sandbox_ref"
        case proto = "protocol"
        case connectionUrl = "connection_url"
        case lastSeenAt = "last_seen_at"
    }
    var resolved: NetworkService {
        NetworkService(
            id: id, networkId: networkId, name: name, address: address,
            sandboxKind: sandboxKind, sandboxRef: sandboxRef, port: port,
            protocolName: proto, status: status, connectionUrl: connectionUrl,
            lastSeenAt: lastSeenAt, transport: transport)
    }
}

/// Input to ``Network/registerService(_:clientOptions:)``.
public struct ServiceRegistration: Sendable {
    /// Service name (the `name` in `name:port`).
    public var name: String
    public var sandboxKind: NetworkMemberKind
    /// Sandbox id (local) or deployment id (deployed) backing the service.
    public var sandboxRef: String
    public var port: Int
    /// Defaults server-side to `tcp` when omitted.
    public var protocolName: String?
    /// Existing `heyo://` ticket, when the caller already runs a live route.
    public var connectionUrl: String?

    public init(
        name: String,
        sandboxKind: NetworkMemberKind,
        sandboxRef: String,
        port: Int,
        protocolName: String? = nil,
        connectionUrl: String? = nil
    ) {
        self.name = name
        self.sandboxKind = sandboxKind
        self.sandboxRef = sandboxRef
        self.port = port
        self.protocolName = protocolName
        self.connectionUrl = connectionUrl
    }
}

/// Result of dialing a service: a live route to it.
public struct ServiceRoute: Sendable {
    /// `name:port` address that was dialed.
    public let address: String
    /// Transport — `iroh_tcp_proxy`.
    public let transport: String
    /// `heyo://` ticket for the live route.
    public let connectionUrl: String
}

/// Per-account sandbox networks. Mirrors ``Database``.
public final class Network: @unchecked Sendable {
    public let id: String
    private let client: HeyoClient
    private var cached: NetworkInfo

    private init(client: HeyoClient, info: NetworkInfo) {
        self.client = client
        self.id = info.id
        self.cached = info
    }

    public static func create(
        _ options: NetworkCreateOptions,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Network {
        let client = HeyoClient(clientOptions)
        let body = JSONValue.object(droppingNil: [
            "name": .string(options.name),
            "description": options.description.map(JSONValue.string),
        ])
        let raw: RawNetwork = try await client.request("/networks", method: "POST", body: body)
        return Network(client: client, info: raw.resolved)
    }

    private struct ListResponse: Decodable { let networks: [RawNetwork]? }

    public static func list(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [NetworkInfo] {
        let client = HeyoClient(clientOptions)
        let resp: ListResponse = try await client.request("/networks")
        return (resp.networks ?? []).map(\.resolved)
    }

    public static func get(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Network {
        let client = HeyoClient(clientOptions)
        let raw: RawNetwork = try await client.request("/networks/\(pathEscape(id))")
        return Network(client: client, info: raw.resolved)
    }

    /// The caller's default network, lazily created server-side.
    public static func `default`(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Network {
        let client = HeyoClient(clientOptions)
        let raw: RawNetwork = try await client.request("/networks/me")
        return Network(client: client, info: raw.resolved)
    }

    public func info() -> NetworkInfo { cached }

    @discardableResult
    public func refresh() async throws -> NetworkInfo {
        let raw: RawNetwork = try await client.request("/networks/\(pathEscape(id))")
        cached = raw.resolved
        return cached
    }

    @discardableResult
    public func update(_ options: NetworkUpdateOptions) async throws -> NetworkInfo {
        let body = JSONValue.object(droppingNil: [
            "name": options.name.map(JSONValue.string),
            "description": options.description.map(JSONValue.string),
        ])
        let raw: RawNetwork = try await client.request(
            "/networks/\(pathEscape(id))", method: "PATCH", body: body)
        cached = raw.resolved
        return cached
    }

    public func delete() async throws {
        try await client.send("/networks/\(pathEscape(id))", method: "DELETE")
    }

    private struct MembersResponse: Decodable { let members: [RawMember]? }

    public func listMembers() async throws -> [NetworkMember] {
        let resp: MembersResponse = try await client.request("/networks/\(pathEscape(id))/members")
        return (resp.members ?? []).map(\.resolved)
    }

    @discardableResult
    public func addMember(_ registration: NetworkMemberRegistration) async throws -> NetworkMember {
        let body = JSONValue.object(droppingNil: [
            "sandbox_kind": .string(registration.sandboxKind.rawValue),
            "sandbox_ref": .string(registration.sandboxRef),
            "device_name": registration.deviceName.map(JSONValue.string),
        ])
        let raw: RawMember = try await client.request(
            "/networks/\(pathEscape(id))/members", method: "POST", body: body)
        return raw.resolved
    }

    /// Assign a daemon **host** to this network so its owner can open a host
    /// shell on it (``Daemons/hostShell(_:shell:clientOptions:)``). Convenience
    /// over ``addMember(_:)`` with ``NetworkMemberKind/host``.
    @discardableResult
    public func addHost(daemonId: String, deviceName: String? = nil) async throws -> NetworkMember {
        try await addMember(
            NetworkMemberRegistration(
                sandboxKind: .host, sandboxRef: daemonId, deviceName: deviceName))
    }

    /// Remove a daemon host from this network, revoking host-shell access.
    public func removeHost(daemonId: String) async throws {
        try await removeMember(sandboxKind: .host, sandboxRef: daemonId)
    }

    public func removeMember(sandboxKind: NetworkMemberKind, sandboxRef: String) async throws {
        try await client.send(
            "/networks/\(pathEscape(id))/members/\(pathEscape(sandboxKind.rawValue))/\(pathEscape(sandboxRef))",
            method: "DELETE")
    }

    /// Services registered in the caller's default network.
    public static func listServices(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [NetworkService] {
        let client = HeyoClient(clientOptions)
        let raw: [RawService] = try await client.request("/networks/me/services")
        return raw.map(\.resolved)
    }

    /// `POST /networks/me/services` — register a service in the caller's default
    /// network so peers can resolve it by `name:port`.
    @discardableResult
    public static func registerService(
        _ registration: ServiceRegistration,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> NetworkService {
        let client = HeyoClient(clientOptions)
        let body = JSONValue.object(droppingNil: [
            "name": .string(registration.name),
            "sandbox_kind": .string(registration.sandboxKind.rawValue),
            "sandbox_ref": .string(registration.sandboxRef),
            "port": .int(registration.port),
            "protocol": registration.protocolName.map(JSONValue.string),
            "connection_url": registration.connectionUrl.map(JSONValue.string),
        ])
        let raw: RawService = try await client.request(
            "/networks/me/services", method: "POST", body: body)
        return raw.resolved
    }

    /// `GET /networks/me/services/{name}/{port}` — look up a single registered
    /// service. Unlike ``dialService(name:port:clientOptions:)`` this only reads
    /// the registration; it does not require a live route.
    public static func resolveService(
        name: String,
        port: Int,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> NetworkService {
        let client = HeyoClient(clientOptions)
        let raw: RawService = try await client.request(
            "/networks/me/services/\(pathEscape(name))/\(port)")
        return raw.resolved
    }

    /// `DELETE /networks/me/services/{name}/{port}` — deregister a service.
    public static func removeService(
        name: String,
        port: Int,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws {
        let client = HeyoClient(clientOptions)
        try await client.send(
            "/networks/me/services/\(pathEscape(name))/\(port)", method: "DELETE")
    }

    /// Resolve a service to a live iroh route. Throws a 409 when the service has
    /// no live proxy route yet.
    public static func dialService(
        name: String,
        port: Int,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> ServiceRoute {
        let client = HeyoClient(clientOptions)
        struct RawRoute: Decodable {
            let address: String
            let transport: String
            let connectionUrl: String
            enum CodingKeys: String, CodingKey {
                case address, transport
                case connectionUrl = "connection_url"
            }
        }
        let raw: RawRoute = try await client.request(
            "/networks/me/services/\(pathEscape(name))/\(port)/dial")
        return ServiceRoute(address: raw.address, transport: raw.transport, connectionUrl: raw.connectionUrl)
    }
}
