import Foundation

/// Options for ``Transfer/receive(ticket:options:clientOptions:)``. Defaults
/// mirror the daemon: start the restored sandbox, degrade to disk-only if the
/// memory snapshot cannot be loaded.
public struct ReceiveOptions: Sendable {
    /// Name override for the restored sandbox. Defaults to the bundle's name.
    public var name: String?
    /// Backend override (`firecracker`, `kvm`, `applevirt`, …). Defaults to the
    /// bundle's source backend.
    public var backend: String?
    /// Start the sandbox once it is restored. Default: `true`.
    public var startAfter: Bool
    /// Fail the receive (and destroy the restored sandbox) if the bundle's
    /// memory snapshot could not be loaded, instead of silently degrading to a
    /// disk-only restore. Default: `false`.
    public var requireMemory: Bool
    /// Iroh relay override for resolving a short-code ticket. Defaults to the
    /// daemon's configured relay.
    public var relay: String?

    public init(
        name: String? = nil,
        backend: String? = nil,
        startAfter: Bool = true,
        requireMemory: Bool = false,
        relay: String? = nil
    ) {
        self.name = name
        self.backend = backend
        self.startAfter = startAfter
        self.requireMemory = requireMemory
        self.relay = relay
    }
}

/// Lifecycle phase of an inbound transfer, from `GET /sync/receives/:id`.
public enum TransferStatus: String, Sendable {
    /// Pulling blobs from the sender's iroh sync server.
    case pulling
    /// Bundle received; materializing disks and (optionally) memory state.
    case restoring
    /// Restore finished; `restoredId` names the new sandbox.
    case done
    /// The receive failed; `error` carries the reason.
    case error
    /// A phase this SDK build does not recognize (forward-compatible).
    case unknown

    /// Whether the transfer has reached a terminal phase (`done` or `error`).
    public var isTerminal: Bool { self == .done || self == .error }
}

/// Progress of an inbound transfer (`GET /sync/receives/:id`).
public struct TransferReceiveStatus: Sendable {
    /// Receive id (`rcv-…`) this status belongs to.
    public let receiveId: String
    /// Staging bundle id (`bnd-…`) on the destination.
    public let bundleId: String
    /// Current phase.
    public let status: TransferStatus
    /// Id of the restored sandbox, once `status` is `.done`.
    public let restoredId: String?
    /// Whether the memory snapshot was restored (vs. a disk-only cold boot).
    /// `nil` until the restore resolves.
    public let memoryRestored: Bool?
    /// Failure reason, set when `status` is `.error`.
    public let error: String?
    /// Bytes pulled from the sender so far.
    public let bytesReceived: Int64
}

extension TransferReceiveStatus: Decodable {
    enum CodingKeys: String, CodingKey {
        case receiveId = "receive_id"
        case bundleId = "bundle_id"
        case status
        case restoredId = "restored_id"
        case memoryRestored = "memory_restored"
        case error
        case bytesReceived = "bytes_received"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiveId = try c.decode(String.self, forKey: .receiveId)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        // Tolerate phases newer than this SDK build knows about.
        let raw = try c.decode(String.self, forKey: .status)
        status = TransferStatus(rawValue: raw) ?? .unknown
        restoredId = try c.decodeIfPresent(String.self, forKey: .restoredId)
        memoryRestored = try c.decodeIfPresent(Bool.self, forKey: .memoryRestored)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        bytesReceived = try c.decodeIfPresent(Int64.self, forKey: .bytesReceived) ?? 0
    }
}

/// Receiving a transferred VM. The *receive* half of `heyvm transfer` — the
/// only part of the P2P VM move reachable over the daemon's HTTP API (the
/// source half packages a live sandbox and serves it over iroh, which needs
/// in-process access to the local host and stays inside the CLI).
///
/// A sender runs `heyvm transfer <vm> --serve` (or the full
/// `heyvm transfer <vm> --to <daemon>`) and produces a `heyo://` ticket for its
/// iroh sync server. Handing that ticket to ``Transfer/receive(ticket:options:clientOptions:)``
/// asks the daemon behind the ``HeyoClient`` to pull the bundle and restore it
/// as a new sandbox — the destination side of the move.
///
/// These routes live on the heyvm daemon, not the cloud, so point the client at
/// a daemon (`HeyoClient.local()` or a ``HeyoClientOptions`` `baseURL` on a
/// daemon port). A default cloud client will 404.
///
/// ```swift
/// let opts = HeyoClientOptions(baseURL: defaultLocalBaseURL)
/// let status = try await Transfer.receiveAndWait(
///     ticket: ticket, options: ReceiveOptions(), timeout: 600, clientOptions: opts)
/// print("restored as \(status.restoredId ?? "?") memory=\(status.memoryRestored ?? false)")
/// ```
public enum Transfer {
    /// How long ``receiveAndWait(ticket:options:timeout:clientOptions:)`` waits
    /// between progress polls.
    private static let pollInterval: TimeInterval = 2

    private struct Accepted: Decodable {
        let receiveId: String
        enum CodingKeys: String, CodingKey { case receiveId = "receive_id" }
    }

    /// Ask the daemon behind `clientOptions` to pull and restore a VM from a
    /// `heyo://` transfer `ticket`. The pull + restore run in the background on
    /// the daemon; this returns the `receiveId` immediately — poll
    /// ``status(receiveId:clientOptions:)`` (or use
    /// ``receiveAndWait(ticket:options:timeout:clientOptions:)``) to follow it.
    public static func receive(
        ticket: String,
        options: ReceiveOptions = ReceiveOptions(),
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> String {
        try await receive(ticket: ticket, options: options, client: HeyoClient(clientOptions))
    }

    /// Progress of a previously started receive. Throws ``HeyoError/notFound(_:)``
    /// if the daemon has no such receive id (they are in-memory and do not
    /// survive a daemon restart).
    public static func status(
        receiveId: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> TransferReceiveStatus {
        try await status(receiveId: receiveId, client: HeyoClient(clientOptions))
    }

    /// Start a receive and poll until it finishes. On success returns the final
    /// status (inspect `restoredId` / `memoryRestored`); a receive that ends in
    /// the `.error` phase is surfaced as ``HeyoError/api(status:message:body:)``,
    /// and exceeding `timeout` as ``HeyoError/timeout(_:)`` (the daemon-side
    /// receive keeps running — re-attach with ``status(receiveId:clientOptions:)``).
    public static func receiveAndWait(
        ticket: String,
        options: ReceiveOptions = ReceiveOptions(),
        timeout: TimeInterval = 600,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> TransferReceiveStatus {
        let client = HeyoClient(clientOptions)
        let receiveId = try await receive(ticket: ticket, options: options, client: client)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = try await status(receiveId: receiveId, client: client)
            switch status.status {
            case .done:
                return status
            case .error:
                throw HeyoError.api(
                    status: 0,
                    message: "transfer receive \(receiveId) failed: "
                        + (status.error ?? "no reason reported"),
                    body: nil)
            default:
                break
            }
            if Date() >= deadline {
                throw HeyoError.timeout(
                    "transfer receive \(receiveId) did not finish within \(Int(timeout))s")
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private static func receive(
        ticket: String, options: ReceiveOptions, client: HeyoClient
    ) async throws -> String {
        let body = JSONValue.object(droppingNil: [
            "ticket": .string(ticket),
            "name": options.name.map(JSONValue.string),
            "backend": options.backend.map(JSONValue.string),
            "start_after": .bool(options.startAfter),
            "require_memory": .bool(options.requireMemory),
            "relay": options.relay.map(JSONValue.string),
        ])
        let accepted: Accepted = try await client.request(
            "/sync/receive", method: "POST", body: body)
        return accepted.receiveId
    }

    private static func status(
        receiveId: String, client: HeyoClient
    ) async throws -> TransferReceiveStatus {
        try await client.request("/sync/receives/\(pathEscape(receiveId))")
    }
}
