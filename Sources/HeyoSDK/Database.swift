import Foundation

// MARK: - SQL values

/// A scalar SQLite value. Matches the untyped JSON the backend exchanges:
/// `null`, booleans, integers, floats, and text.
public enum SqlValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = .text(try c.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .text(s): try c.encode(s)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case let .bool(b): return .bool(b)
        case let .int(i): return .int(Int(i))
        case let .double(d): return .double(d)
        case let .text(s): return .string(s)
        }
    }
}

public struct SqlStatement: Sendable {
    public var sql: String
    public var args: [SqlValue]
    public init(_ sql: String, args: [SqlValue] = []) {
        self.sql = sql
        self.args = args
    }
}

public enum SqlTransactionMode: String, Sendable {
    case deferred, immediate, exclusive
}

public struct ExecOptions: Sendable {
    /// When set, all statements run inside a single BEGIN/COMMIT.
    public var transaction: SqlTransactionMode?
    /// Cap on rows returned per statement. Server clamps to 10_000.
    public var maxRows: Int?
    public init(transaction: SqlTransactionMode? = nil, maxRows: Int? = nil) {
        self.transaction = transaction
        self.maxRows = maxRows
    }
}

public struct ExecResult: Sendable {
    public let columns: [String]
    public let rows: [[SqlValue]]
    public let rowsAffected: Int64
    public let lastInsertRowId: Int64?
    public let truncated: Bool
}

public struct BatchResult: Sendable {
    public let results: [ExecResult]
    public let elapsedMs: Int64
}

private struct RawStatementResult: Decodable {
    let columns: [String]?
    let rows: [[SqlValue]]?
    let rowsAffected: Int64?
    let lastInsertRowId: Int64?
    let truncated: Bool?
    enum CodingKeys: String, CodingKey {
        case columns, rows, truncated
        case rowsAffected = "rows_affected"
        case lastInsertRowId = "last_insert_rowid"
    }
    var resolved: ExecResult {
        ExecResult(
            columns: columns ?? [],
            rows: rows ?? [],
            rowsAffected: rowsAffected ?? 0,
            lastInsertRowId: lastInsertRowId,
            truncated: truncated ?? false)
    }
}

private struct RawExecResponse: Decodable {
    let results: [RawStatementResult]?
    let elapsedMs: Int64?
    enum CodingKeys: String, CodingKey {
        case results
        case elapsedMs = "elapsed_ms"
    }
}

// MARK: - Connection tokens

public enum ConnectionScope: String, Codable, Sendable {
    case read, write
}

public struct ConnectionTokenOptions: Sendable {
    public var ttlSeconds: Int?
    public var scopes: [ConnectionScope]?
    public init(ttlSeconds: Int? = nil, scopes: [ConnectionScope]? = nil) {
        self.ttlSeconds = ttlSeconds
        self.scopes = scopes
    }
}

public struct ConnectionToken: Sendable {
    public let id: String
    public let databaseId: String
    /// Base URL for libsql HTTP clients (appends `/v1/execute`, `/v2/pipeline`).
    public let url: String
    /// Plaintext bearer; only returned at mint time.
    public let authToken: String
    public let scopes: [ConnectionScope]
    public let expiresAt: String
}

private struct RawConnectionToken: Decodable {
    let id: String
    let databaseId: String
    let url: String
    let authToken: String
    let scopes: [ConnectionScope]?
    let expiresAt: String
    enum CodingKeys: String, CodingKey {
        case id, url, scopes
        case databaseId = "database_id"
        case authToken = "auth_token"
        case expiresAt = "expires_at"
    }
    var resolved: ConnectionToken {
        ConnectionToken(
            id: id, databaseId: databaseId, url: url, authToken: authToken,
            scopes: scopes ?? [], expiresAt: expiresAt)
    }
}

public struct ConnectionTokenInfo: Sendable {
    public let id: String
    public let databaseId: String
    public let scopes: [ConnectionScope]
    public let revoked: Bool
    public let expiresAt: String
    public let createdAt: String
    public let lastUsedAt: String?
}

private struct RawConnectionTokenInfo: Decodable {
    let id: String
    let databaseId: String
    let scopes: [ConnectionScope]?
    let revoked: Bool
    let expiresAt: String
    let createdAt: String
    let lastUsedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, scopes, revoked
        case databaseId = "database_id"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
    var resolved: ConnectionTokenInfo {
        ConnectionTokenInfo(
            id: id, databaseId: databaseId, scopes: scopes ?? [], revoked: revoked,
            expiresAt: expiresAt, createdAt: createdAt, lastUsedAt: lastUsedAt)
    }
}

// MARK: - Offline editing

public struct CheckoutResult: Sendable {
    public let databaseId: String
    /// Monotonic write counter at snapshot time. Carry this through to checkin.
    public let dataVersion: Int64
    /// Gzipped SQLite database file. `gunzip` to get the raw `.db`.
    public let bytes: Data
}

public struct CheckinOptions: Sendable {
    /// Expected `data_version`. Required unless `force` is set.
    public var expectedVersion: Int64?
    /// Skip the optimistic concurrency check and overwrite (data-loss risk).
    public var force: Bool
    public init(expectedVersion: Int64? = nil, force: Bool = false) {
        self.expectedVersion = expectedVersion
        self.force = force
    }
}

public struct CheckinResult: Sendable {
    public let databaseId: String
    public let dataVersion: Int64
    public let s3Key: String
    public let forced: Bool
}

// MARK: - Database info

public struct DatabaseInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let userId: String
    public let accountId: String?
    public let backendServerId: String?
    public let backendDatabaseId: String?
    public let region: String?
    public let status: String
    public let sizeClass: String?
    public let s3Key: String?
    public let walS3Prefix: String?
    public let errorMessage: String?
    public let createdAt: String
    public let updatedAt: String
    public let statusChangedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, region, status
        case userId = "user_id"
        case accountId = "account_id"
        case backendServerId = "backend_server_id"
        case backendDatabaseId = "backend_database_id"
        case sizeClass = "size_class"
        case s3Key = "s3_key"
        case walS3Prefix = "wal_s3_prefix"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case statusChangedAt = "status_changed_at"
    }
}

public struct DatabaseCreateOptions: Sendable {
    public var name: String
    public var region: String
    public var sizeClass: String?
    public var envVars: [String: String]?
    public init(name: String, region: String, sizeClass: String? = nil, envVars: [String: String]? = nil) {
        self.name = name
        self.region = region
        self.sizeClass = sizeClass
        self.envVars = envVars
    }
}

/// Cloud sqlite database. Mirrors ``Sandbox``: static factories plus instance
/// operations over a shared ``HeyoClient``.
public final class Database: @unchecked Sendable {
    public let id: String
    private let client: HeyoClient
    private var cached: DatabaseInfo

    private init(client: HeyoClient, info: DatabaseInfo) {
        self.client = client
        self.id = info.id
        self.cached = info
    }

    public static func create(
        _ options: DatabaseCreateOptions,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Database {
        let client = HeyoClient(clientOptions)
        let body = JSONValue.object(droppingNil: [
            "name": .string(options.name),
            "region": .string(options.region),
            "size_class": options.sizeClass.map(JSONValue.string),
            "env_vars": options.envVars.map { .object($0.mapValues(JSONValue.string)) },
        ])
        let info: DatabaseInfo = try await client.request("/sqlite-databases", method: "POST", body: body)
        return Database(client: client, info: info)
    }

    private struct ListResponse: Decodable { let databases: [DatabaseInfo]? }

    public static func list(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [DatabaseInfo] {
        let client = HeyoClient(clientOptions)
        let resp: ListResponse = try await client.request("/sqlite-databases")
        return resp.databases ?? []
    }

    public static func get(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Database {
        let client = HeyoClient(clientOptions)
        let info: DatabaseInfo = try await client.request("/sqlite-databases/\(pathEscape(id))")
        return Database(client: client, info: info)
    }

    private struct RegionsResponse: Decodable { let regions: [String]? }

    public static func regions(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [String] {
        let client = HeyoClient(clientOptions)
        let resp: RegionsResponse = try await client.request("/sqlite-regions")
        return resp.regions ?? []
    }

    /// Most recent info this client received. Refresh with ``refresh()``.
    public func info() -> DatabaseInfo { cached }

    @discardableResult
    public func refresh() async throws -> DatabaseInfo {
        let info: DatabaseInfo = try await client.request("/sqlite-databases/\(pathEscape(id))")
        cached = info
        return info
    }

    public func delete() async throws {
        try await client.send("/sqlite-databases/\(pathEscape(id))", method: "DELETE")
    }

    /// Run a single SQL statement. Bind positional parameters via `?`.
    @discardableResult
    public func exec(
        _ sql: String,
        args: [SqlValue] = [],
        options: ExecOptions = ExecOptions()
    ) async throws -> ExecResult {
        let batch = try await batch([SqlStatement(sql, args: args)], options: options)
        guard let first = batch.results.first else {
            throw HeyoError.api(status: 200, message: "exec returned no results", body: nil)
        }
        return first
    }

    /// Run multiple statements, optionally in a single transaction.
    public func batch(
        _ statements: [SqlStatement],
        options: ExecOptions = ExecOptions()
    ) async throws -> BatchResult {
        let body = JSONValue.object(droppingNil: [
            "statements": .array(statements.map { stmt in
                .object(["sql": .string(stmt.sql), "args": .array(stmt.args.map(\.jsonValue))])
            }),
            "transaction": options.transaction.map { .string($0.rawValue) },
            "max_rows": options.maxRows.map(JSONValue.int),
        ])
        let raw: RawExecResponse = try await client.request(
            "/sqlite-databases/\(pathEscape(id))/exec", method: "POST", body: body)
        return BatchResult(
            results: (raw.results ?? []).map(\.resolved),
            elapsedMs: raw.elapsedMs ?? 0)
    }

    /// Mint a libsql-compatible connection token. The plaintext token is only
    /// returned here; persist it immediately.
    public func connect(_ options: ConnectionTokenOptions = ConnectionTokenOptions()) async throws -> ConnectionToken {
        let body = JSONValue.object(droppingNil: [
            "ttl_seconds": options.ttlSeconds.map(JSONValue.int),
            "scopes": options.scopes.map { .array($0.map { .string($0.rawValue) }) },
        ])
        let raw: RawConnectionToken = try await client.request(
            "/sqlite-databases/\(pathEscape(id))/connection", method: "POST", body: body)
        return raw.resolved
    }

    private struct ConnectionInfoResponse: Decodable {
        let databaseId: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case url
            case databaseId = "database_id"
        }
    }

    /// URL for the libsql HTTP transport, no token.
    public func connectionInfo() async throws -> (databaseId: String, url: String) {
        let resp: ConnectionInfoResponse = try await client.request(
            "/sqlite-databases/\(pathEscape(id))/connection-info")
        return (resp.databaseId, resp.url)
    }

    private struct ConnectionTokensResponse: Decodable { let tokens: [RawConnectionTokenInfo]? }

    /// Active + revoked tokens for this database. Plaintext is never returned.
    public func listConnections() async throws -> [ConnectionTokenInfo] {
        let resp: ConnectionTokensResponse = try await client.request(
            "/sqlite-databases/\(pathEscape(id))/connection-tokens")
        return (resp.tokens ?? []).map(\.resolved)
    }

    public func revokeConnection(_ tokenId: String) async throws {
        try await client.send(
            "/sqlite-databases/\(pathEscape(id))/connection-tokens/\(pathEscape(tokenId))",
            method: "DELETE")
    }

    /// Download the canonical sqlite file (gzipped) for offline editing. Carry
    /// `dataVersion` through to ``checkin(_:options:)`` for optimistic
    /// concurrency.
    public func checkout() async throws -> CheckoutResult {
        let (data, http) = try await client.rawRequest("/sqlite-databases/\(pathEscape(id))/file")
        guard let header = http.value(forHTTPHeaderField: "X-Heyo-Data-Version") else {
            throw HeyoError.api(status: http.statusCode, message: "Response missing X-Heyo-Data-Version header", body: data)
        }
        guard let version = Int64(header) else {
            throw HeyoError.api(status: http.statusCode, message: "Non-numeric X-Heyo-Data-Version: \(header)", body: data)
        }
        return CheckoutResult(databaseId: id, dataVersion: version, bytes: data)
    }

    /// Upload an edited (gzipped) sqlite file. The server applies optimistic
    /// concurrency on `expectedVersion`; a race throws
    /// ``HeyoError/checkinConflict(expected:current:)``. Pass `force: true` to
    /// override.
    public func checkin(_ bytes: Data, options: CheckinOptions = CheckinOptions()) async throws -> CheckinResult {
        if !options.force && options.expectedVersion == nil {
            throw HeyoError.invalidArgument("checkin requires expectedVersion unless force is set")
        }
        var query: [String: String?] = [:]
        if let v = options.expectedVersion { query["expected_version"] = String(v) }
        if options.force { query["force"] = "true" }

        let (data, http) = try await client.putBytes(
            "/sqlite-databases/\(pathEscape(id))/file",
            body: bytes,
            contentType: "application/gzip",
            query: query,
            validateStatus: false)

        if http.statusCode == 409 {
            var current: Int64 = -1
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cv = obj["current_version"] as? Int {
                current = Int64(cv)
            }
            throw HeyoError.checkinConflict(expected: options.expectedVersion, current: current)
        }
        try HeyoClient.validate(http, data: data, path: "/sqlite-databases/\(id)/file")

        struct RawCheckin: Decodable {
            let databaseId: String
            let dataVersion: Int64
            let s3Key: String
            let forced: Bool
            enum CodingKeys: String, CodingKey {
                case forced
                case databaseId = "database_id"
                case dataVersion = "data_version"
                case s3Key = "s3_key"
            }
        }
        let parsed = try JSONDecoder().decode(RawCheckin.self, from: data)
        return CheckinResult(
            databaseId: parsed.databaseId, dataVersion: parsed.dataVersion,
            s3Key: parsed.s3Key, forced: parsed.forced)
    }
}
