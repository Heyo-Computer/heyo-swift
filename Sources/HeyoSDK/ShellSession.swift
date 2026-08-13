import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Options & events

/// Reconnect tuning for ``Sandbox/shell(_:)``. The SDK starts at `baseDelay`
/// and doubles each retry until it hits `maxDelay`, giving up after
/// `maxRetries` consecutive failures.
public struct ShellReconnectOptions: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(
        maxRetries: Int = 5,
        baseDelay: TimeInterval = 0.1,
        maxDelay: TimeInterval = 30
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
}

/// Options for ``Sandbox/shell(_:)``.
public struct ShellOptions: Sendable {
    public var cwd: String?
    public var env: [String: String]?
    public var cols: Int
    public var rows: Int
    /// Reconnect tuning; pass `nil` to disable auto-reconnect.
    public var reconnect: ShellReconnectOptions?

    public init(
        cwd: String? = nil,
        env: [String: String]? = nil,
        cols: Int = 80,
        rows: Int = 24,
        reconnect: ShellReconnectOptions? = ShellReconnectOptions()
    ) {
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows
        self.reconnect = reconnect
    }
}

/// Lifecycle events emitted on ``ShellSession/events``.
public enum ShellEvent: Sendable {
    case reconnecting(attempt: Int, delay: TimeInterval)
    case reconnected
    case closed(exitCode: Int?)
    case error(HeyoError)
}

private let ackInterval: TimeInterval = 0.1
private let heartbeatTimeout: TimeInterval = 60

/// A persistent interactive shell over a WebSocket. The cloud (and mvm-ctrl
/// behind it) terminates the WS, holds a real PTY-attached `bash`, and replays
/// buffered output on reconnect, so `cd`, env mutations, and TTY programs all
/// behave normally.
///
/// Wire protocol (matches `mvm-ctrl/src/api.rs::shell_stream_ws`):
/// - C→S init (text): `{type:"init", cols, rows, env?, cwd?, sessionId?}`
/// - S→C ready (text): `{type:"ready", sessionId, lastSeq?}`
/// - stdin (binary): `[0x01, ...bytes]`
/// - stdout (binary): `[0x02, seq:u64-be, ...bytes]`
/// - resize/ack/close/exit/error (text JSON)
///
/// Created via ``Sandbox/shell(_:)``; do not construct directly.
public actor ShellSession {
    /// PTY output stream. Iteration ends when the session closes.
    public nonisolated let output: AsyncStream<Data>
    /// Lifecycle event stream. Iteration ends when the session closes.
    public nonisolated let events: AsyncStream<ShellEvent>

    private nonisolated let outputCont: AsyncStream<Data>.Continuation
    private nonisolated let eventsCont: AsyncStream<ShellEvent>.Continuation

    private let url: URL
    /// `Authorization` header value sent on the WebSocket upgrade, or nil when
    /// the client is unauthenticated (e.g. a local daemon).
    private let authorization: String?
    private let options: ShellOptions
    private let reconnect: ShellReconnectOptions?
    private let urlSession: URLSession

    private var wsTask: URLSessionWebSocketTask?
    private var connected = false

    /// Server-assigned session id, available after `open` resolves.
    public private(set) var sessionId: String?
    public private(set) var isClosed = false
    private var closedExitCode: Int?

    private var lastSeqReceived: UInt64 = 0
    private var lastSeqAcked: UInt64 = 0
    private var lastActivity = Date()
    private var reconnectAttempt = 0

    /// Pending stdin buffered while disconnected; flushed on the next `ready`.
    private var outboundQueue: [Data] = []

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResolved = false

    private var loopTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private init(client: HeyoClient, path: String, options: ShellOptions) {
        self.url = client.wsURL(path)
        // The cloud authenticates the WS upgrade via the `Authorization` header
        // (matching the Rust SDK). URLSession sends URLRequest headers on the
        // handshake, so set it there rather than passing the token in the query
        // string — the cloud rejects `?token=…` on this route.
        self.authorization = client.wsAuthorization()
        self.options = options
        self.reconnect = options.reconnect
        self.urlSession = URLSession(configuration: .default)

        var oc: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { oc = $0 }
        self.outputCont = oc
        var ec: AsyncStream<ShellEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { ec = $0 }
        self.eventsCont = ec
    }

    /// Open a shell on a deployed sandbox and wait for the first `ready` frame.
    static func open(
        client: HeyoClient,
        sandboxId: String,
        options: ShellOptions
    ) async throws -> ShellSession {
        try await open(
            client: client,
            path: "/deployed-sandboxes/\(pathEscape(sandboxId))/shell-stream",
            options: options)
    }

    /// Open a shell against an arbitrary `shell-stream` route and wait for the
    /// first `ready` frame. Used by ``Daemons/hostShell(_:shell:clientOptions:)``
    /// to target a daemon's host machine instead of a sandbox; the wire protocol
    /// is identical either way.
    static func open(
        client: HeyoClient,
        path: String,
        options: ShellOptions
    ) async throws -> ShellSession {
        let session = ShellSession(client: client, path: path, options: options)
        try await session.start()
        return session
    }

    private func start() async throws {
        startTimers()
        loopTask = Task { await self.runConnectionLoop() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if readyResolved {
                cont.resume()
            } else {
                self.readyContinuation = cont
            }
        }
    }

    // MARK: - Public control

    /// Send keystrokes / bytes to the shell's stdin.
    public func write(_ data: Data) async throws {
        if isClosed { throw HeyoError.connection("Cannot write to a closed shell session") }
        if connected, let task = wsTask {
            try await sendStdin(task, data)
        } else {
            outboundQueue.append(data)
        }
    }

    /// Send a UTF-8 string to the shell's stdin.
    public func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }

    /// Resize the PTY.
    public func resize(cols: Int, rows: Int) async throws {
        if isClosed { throw HeyoError.connection("Cannot resize a closed shell session") }
        if connected, let task = wsTask {
            try? await sendText(task, jsonString(["type": .string("resize"), "cols": .int(cols), "rows": .int(rows)]))
        }
    }

    /// Send a graceful close (EOF) and wait briefly for the shell to exit.
    public func close() async throws {
        if isClosed { return }
        if connected, let task = wsTask {
            try? await sendText(task, jsonString(["type": .string("close")]))
            // Give the server up to 2s to send `exit`.
            let deadline = Date().addingTimeInterval(2)
            while !isClosed && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        teardown(exitCode: closedExitCode, error: nil)
    }

    /// Force-kill: close the socket immediately, no exit wait.
    public func kill() {
        teardown(exitCode: nil, error: nil)
    }

    /// The shell's exit code, once known.
    public func exitCode() -> Int? { closedExitCode }

    // MARK: - Connection loop

    private func runConnectionLoop() async {
        outer: while !isClosed {
            let reconnecting = sessionId != nil

            var request = URLRequest(url: url)
            if let authorization {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            let task = urlSession.webSocketTask(with: request)
            wsTask = task
            task.resume()

            do {
                try await sendText(task, buildInit())
            } catch {
                connected = false
                if await handleDisconnect(reconnecting: reconnecting, error: error) { continue outer }
                break outer
            }
            connected = true
            lastActivity = Date()

            let outcome = await receiveLoop(task)
            connected = false

            switch outcome {
            case .exited:
                teardown(exitCode: closedExitCode, error: nil)
                break outer
            case .sessionExpired:
                teardown(exitCode: nil, error: .sessionExpired(sessionId: sessionId))
                break outer
            case let .disconnected(error):
                if await handleDisconnect(reconnecting: sessionId != nil, error: error) {
                    continue outer
                }
                break outer
            }
        }
    }

    private enum ReceiveOutcome {
        case exited
        case sessionExpired
        case disconnected(Error?)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async -> ReceiveOutcome {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return .disconnected(error)
            }
            lastActivity = Date()

            switch message {
            case let .data(data):
                handleBinary(data)
            case let .string(text):
                if let outcome = handleControl(text) {
                    return outcome
                }
            @unknown default:
                break
            }
        }
    }

    /// Returns `true` if a reconnect was scheduled (caller should `continue`),
    /// `false` if the loop should terminate.
    private func handleDisconnect(reconnecting: Bool, error: Error?) async -> Bool {
        if isClosed { return false }

        // First-connect failure (never got `ready`): no session to resume.
        if sessionId == nil {
            let err = HeyoError.connection(
                "shell-stream socket closed before ready: \(error.map { "\($0)" } ?? "unknown")")
            teardown(exitCode: nil, error: err)
            return false
        }

        guard let reconnect else {
            teardown(exitCode: nil, error: .connection("shell-stream socket closed; reconnect disabled"))
            return false
        }

        reconnectAttempt += 1
        if reconnectAttempt > reconnect.maxRetries {
            teardown(
                exitCode: nil,
                error: .connection("shell-stream gave up after \(reconnect.maxRetries) reconnect attempts"))
            return false
        }
        let delay = backoff(reconnect, attempt: reconnectAttempt)
        emit(.reconnecting(attempt: reconnectAttempt, delay: delay))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return !isClosed
    }

    // MARK: - Frame handling

    private func handleBinary(_ data: Data) {
        guard let frame = ShellFrame.decodeStdout(data) else { return }
        if frame.seq <= lastSeqReceived { return }  // replay duplicate
        lastSeqReceived = frame.seq
        outputCont.yield(frame.payload)
    }

    /// Returns a terminal ``ReceiveOutcome`` when the frame ends the connection,
    /// `nil` otherwise.
    private func handleControl(_ text: String) -> ReceiveOutcome? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "ready":
            let wasReconnect = sessionId != nil
            if let sid = obj["sessionId"] as? String { sessionId = sid }
            if wasReconnect {
                reconnectAttempt = 0
                emit(.reconnected)
            } else {
                resolveReady(.success(()))
            }
            flushOutbound()
            return nil
        case "exit":
            let code = (obj["code"] as? Int) ?? Int((obj["code"] as? Double) ?? 0)
            closedExitCode = code
            if code != 0 && !isClosed {
                emit(.error(.shellExit(code)))
            }
            return .exited
        case "error":
            let codeStr = obj["code"] as? String
            let message = (obj["message"] as? String) ?? "shell-stream server error"
            if codeStr == "session_expired" {
                emit(.error(.sessionExpired(sessionId: sessionId)))
                return .sessionExpired
            } else {
                emit(.error(.connection(message)))
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Sending

    private func buildInit() -> String {
        var fields: [String: JSONValue] = [
            "type": .string("init"),
            "cols": .int(options.cols),
            "rows": .int(options.rows),
        ]
        if let env = options.env { fields["env"] = .object(env.mapValues(JSONValue.string)) }
        if let cwd = options.cwd { fields["cwd"] = .string(cwd) }
        if let sid = sessionId { fields["sessionId"] = .string(sid) }
        return jsonString(fields)
    }

    private func flushOutbound() {
        guard connected, let task = wsTask else { return }
        let queued = outboundQueue
        outboundQueue.removeAll()
        for data in queued {
            Task { try? await self.sendStdin(task, data) }
        }
    }

    private func sendStdin(_ task: URLSessionWebSocketTask, _ data: Data) async throws {
        do {
            try await task.send(.data(ShellFrame.encodeStdin(data)))
        } catch {
            throw HeyoError.connection("failed to send stdin: \(error)")
        }
    }

    private func sendText(_ task: URLSessionWebSocketTask, _ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw HeyoError.connection("failed to send frame: \(error)")
        }
    }

    // MARK: - Timers

    private func startTimers() {
        ackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ackInterval * 1_000_000_000))
                guard let self else { return }
                if await self.tickAck() { return }
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if await self.tickHeartbeat() { return }
            }
        }
    }

    /// Sends an ack if there's new output. Returns `true` when the timer should
    /// stop (session closed).
    private func tickAck() async -> Bool {
        if isClosed { return true }
        guard lastSeqReceived > lastSeqAcked, connected, let task = wsTask else { return false }
        lastSeqAcked = lastSeqReceived
        try? await sendText(task, jsonString(["type": .string("ack"), "seq": .int(Int(lastSeqAcked))]))
        return false
    }

    /// Closes the socket if it's gone quiet past the heartbeat timeout. Returns
    /// `true` when the timer should stop.
    private func tickHeartbeat() async -> Bool {
        if isClosed { return true }
        if connected, Date().timeIntervalSince(lastActivity) > heartbeatTimeout {
            // Force the receive loop to fail → reconnect path.
            wsTask?.cancel(with: .goingAway, reason: nil)
        }
        return false
    }

    // MARK: - Teardown

    private func teardown(exitCode: Int?, error: HeyoError?) {
        if isClosed { return }
        isClosed = true
        if let exitCode { closedExitCode = exitCode }
        connected = false

        ackTask?.cancel()
        heartbeatTask?.cancel()
        loopTask?.cancel()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil

        outputCont.finish()
        emit(.closed(exitCode: closedExitCode))
        eventsCont.finish()

        if let error {
            resolveReady(.failure(error))
        } else {
            // Resolve a never-readied open() (e.g. kill() before ready) so the
            // caller isn't left awaiting forever.
            resolveReady(.failure(HeyoError.connection("shell session closed before ready")))
        }
    }

    private func resolveReady(_ result: Result<Void, Error>) {
        guard !readyResolved else { return }
        readyResolved = true
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(with: result)
        }
    }

    private func emit(_ event: ShellEvent) {
        eventsCont.yield(event)
    }
}

// MARK: - Helpers

private func backoff(_ r: ShellReconnectOptions, attempt: Int) -> TimeInterval {
    let pow = min(max(attempt - 1, 0), 30)
    let factor = Double(1 << pow)
    return min(r.baseDelay * factor, r.maxDelay)
}

/// Serialize a flat `[String: JSONValue]` to a compact JSON string.
private func jsonString(_ object: [String: JSONValue]) -> String {
    let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
