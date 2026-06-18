import Foundation

/// Every error thrown by the SDK. Mirrors the TS SDK's `HeyoError` hierarchy
/// and the Rust SDK's `HeyoError` enum: a small, closed set of cases callers
/// can `switch` over to drive recovery (retry, re-auth, recreate, …).
public enum HeyoError: Error, CustomStringConvertible {
    /// The SDK was asked to act without (or with an invalid) API key — 401/403.
    case authentication(String)
    /// The request was rejected as malformed — 400/422.
    case invalidArgument(String)
    /// The referenced sandbox / archive / image / database does not exist — 404.
    case notFound(String)
    /// Server returned 5xx, or the network request failed (status 0). Carries
    /// the raw response body when one was readable.
    case api(status: Int, message: String, body: Data?)
    /// A `waitFor*` call exceeded its budget.
    case timeout(String)
    /// A deploy ended in `failed` (or was reaped after a stuck `provisioning`).
    case sandboxFailed(sandboxId: String, reason: String?)
    /// The shell WebSocket could not be established or all reconnects exhausted.
    case connection(String)
    /// The server could not resume a dropped shell session (grace window
    /// elapsed, sandbox restarted, or the session was reaped). Open a new shell.
    case sessionExpired(sessionId: String?)
    /// The remote shell process exited unexpectedly with a non-zero code.
    case shellExit(Int)
    /// `Database.checkin` was called with an `expectedVersion` that no longer
    /// matches the row's `data_version` — another writer raced you. Re-checkout
    /// and merge, or `checkin(force: true)`.
    case checkinConflict(expected: Int64?, current: Int64)

    public var description: String {
        switch self {
        case let .authentication(m): return "AuthenticationError: \(m)"
        case let .invalidArgument(m): return "InvalidArgumentError: \(m)"
        case let .notFound(m): return "NotFoundError: \(m)"
        case let .api(status, message, _): return "ApiError(\(status)): \(message)"
        case let .timeout(m): return "TimeoutError: \(m)"
        case let .sandboxFailed(id, reason):
            return reason.map { "SandboxFailedError: sandbox \(id) failed: \($0)" }
                ?? "SandboxFailedError: sandbox \(id) failed (no reason reported)"
        case let .connection(m): return "ConnectionError: \(m)"
        case let .sessionExpired(id):
            return id.map { "SessionExpiredError: shell session \($0) expired" }
                ?? "SessionExpiredError: shell session expired"
        case let .shellExit(code): return "ShellExitError: shell exited with code \(code)"
        case let .checkinConflict(expected, current):
            return "CheckinConflictError: remote data_version is \(current) (expected \(expected.map(String.init) ?? "<unset>"))"
        }
    }
}
