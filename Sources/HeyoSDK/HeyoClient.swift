import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Default cloud base URL.
public let defaultBaseURL = "https://server.heyo.computer"

/// Default base URL for a local heyvm API (the `heyvmd` daemon's `--api-port`).
/// Used by ``HeyoClient/local(baseURL:timeout:)`` so desktop apps can drive a
/// same-machine sandbox without the cloud in the data path.
public let defaultLocalBaseURL = "http://127.0.0.1:34099"

/// Configuration for a ``HeyoClient``.
public struct HeyoClientOptions: Sendable {
    /// API key. Falls back to the `HEYO_API_KEY` environment variable. Anything
    /// the cloud accepts in `Authorization: Bearer <…>` works — a `heyo_api_*`
    /// key or a JWT. When neither is present the client is unauthenticated and
    /// the `Authorization` header is omitted (a local daemon needs none).
    public var apiKey: String?
    /// Cloud base URL. Default: `https://server.heyo.computer`.
    public var baseURL: String
    /// Default per-request timeout in seconds. Default: 60.
    public var timeout: TimeInterval

    public init(
        apiKey: String? = nil,
        baseURL: String = defaultBaseURL,
        timeout: TimeInterval = 60
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.timeout = timeout
    }
}

/// HTTP transport shared by every public type in the SDK. Centralizes auth
/// header injection, timeout handling, and translation of HTTP failures into
/// typed ``HeyoError`` values so the public API never surfaces a raw
/// `URLResponse`.
public final class HeyoClient: @unchecked Sendable {
    let apiKey: String?
    /// Base URL with any trailing slashes removed.
    public let baseURL: String
    let defaultTimeout: TimeInterval
    private let session: URLSession

    private static let jsonDecoder: JSONDecoder = {
        // No global key strategy: the wire mixes snake_case (most endpoints)
        // and camelCase (daemon rows, shell frames). Each Codable type declares
        // explicit CodingKeys instead.
        JSONDecoder()
    }()

    private static let jsonEncoder = JSONEncoder()

    public init(_ options: HeyoClientOptions = HeyoClientOptions()) {
        self.apiKey = options.apiKey
            ?? ProcessInfo.processInfo.environment["HEYO_API_KEY"]
        self.baseURL = HeyoClient.trimTrailingSlashes(options.baseURL)
        self.defaultTimeout = options.timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = options.timeout
        self.session = URLSession(configuration: config)
    }

    /// Build a client targeting a local heyvm API. Sends no auth by default — a
    /// same-machine daemon runs without `JWT_SECRET` and skips authentication.
    public static func local(
        baseURL: String = defaultLocalBaseURL,
        timeout: TimeInterval = 60
    ) -> HeyoClient {
        HeyoClient(HeyoClientOptions(apiKey: nil, baseURL: baseURL, timeout: timeout))
    }

    private static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    // MARK: - URL building

    private func buildURL(_ path: String, query: [String: String?]) -> URL {
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(string: baseURL + cleanPath)!
        let items = query.compactMap { key, value -> URLQueryItem? in
            guard let value else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !items.isEmpty {
            components.queryItems = (components.queryItems ?? []) + items
        }
        return components.url!
    }

    private func authHeader() -> String? {
        apiKey.map { "Bearer \($0)" }
    }

    // MARK: - WebSocket helpers

    /// Build a `ws://` / `wss://` URL for `path`, using the same host as the
    /// REST base URL.
    public func wsURL(_ path: String) -> URL {
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(string: baseURL + cleanPath)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// Bearer token value for authenticating a WebSocket upgrade, or `nil` when
    /// the client is unauthenticated.
    public func wsAuthorization() -> String? {
        authHeader()
    }

    // MARK: - Requests

    /// Issue a request and decode its JSON response into `T`.
    func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: JSONValue? = nil,
        query: [String: String?] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let (data, _) = try await perform(
            path, method: method, body: body, query: query, timeout: timeout)
        if data.isEmpty {
            throw HeyoError.api(
                status: 200, message: "Empty response body from \(path)", body: nil)
        }
        do {
            return try HeyoClient.jsonDecoder.decode(T.self, from: data)
        } catch {
            throw HeyoError.api(
                status: 200,
                message: "Failed to decode response from \(path): \(error)",
                body: data)
        }
    }

    /// Issue a request and discard the response body. Used for endpoints that
    /// return 204 / an ignored payload.
    @discardableResult
    func send(
        _ path: String,
        method: String = "POST",
        body: JSONValue? = nil,
        query: [String: String?] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let (data, _) = try await perform(
            path, method: method, body: body, query: query, timeout: timeout)
        return data
    }

    /// Low-level request that injects auth + timeout, validates the status, and
    /// returns the raw bytes plus the `HTTPURLResponse` (for reading headers
    /// such as `X-Heyo-Data-Version`). Throws ``HeyoError`` on non-2xx.
    func rawRequest(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        query: [String: String?] = [:],
        timeout: TimeInterval? = nil,
        validateStatus: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let url = buildURL(path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout ?? defaultTimeout
        if let auth = authHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            req.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw HeyoError.api(
                    status: 0, message: "Request to \(path) timed out", body: nil)
            }
            throw HeyoError.api(
                status: 0,
                message: "Network error calling \(path): \(error.localizedDescription)",
                body: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HeyoError.api(status: 0, message: "Non-HTTP response from \(path)", body: data)
        }
        if validateStatus {
            try HeyoClient.validate(http, data: data, path: path)
        }
        return (data, http)
    }

    /// PUT raw bytes (DB checkin, presigned S3 upload). Set `includeAuth` to
    /// `false` for presigned S3 URLs, which reject an extra `Authorization`
    /// header.
    func putBytes(
        _ path: String,
        body: Data,
        contentType: String,
        query: [String: String?] = [:],
        validateStatus: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        try await rawRequest(
            path, method: "PUT", body: body, contentType: contentType,
            query: query, validateStatus: validateStatus)
    }

    private func perform(
        _ path: String,
        method: String,
        body: JSONValue?,
        query: [String: String?],
        timeout: TimeInterval?
    ) async throws -> (Data, HTTPURLResponse) {
        var bodyData: Data?
        var contentType: String?
        if let body {
            bodyData = try HeyoClient.jsonEncoder.encode(body)
            contentType = "application/json"
        }
        return try await rawRequest(
            path, method: method, body: bodyData, contentType: contentType,
            query: query, timeout: timeout)
    }

    // MARK: - Status mapping

    static func validate(_ http: HTTPURLResponse, data: Data, path: String) throws {
        let status = http.statusCode
        guard !(200...299).contains(status) else { return }

        var message = "\(status)"
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let m = obj["message"] as? String {
                    message = m
                } else if let e = obj["error"] as? String {
                    message = e
                } else {
                    message = text
                }
            } else {
                message = text
            }
        }

        switch status {
        case 401, 403:
            throw HeyoError.authentication("\(message) (calling \(path))")
        case 404:
            throw HeyoError.notFound("\(message) (calling \(path))")
        case 400, 422:
            throw HeyoError.invalidArgument("\(message) (calling \(path))")
        default:
            throw HeyoError.api(status: status, message: message, body: data)
        }
    }

    /// `GET /health` — liveness probe served by both cloud and local API.
    public func health() async throws -> HealthStatus {
        try await request("/health")
    }

    /// `GET /capabilities` — drivers the host supports. Local heyvm API only;
    /// the cloud returns 404.
    public func capabilities() async throws -> HostCapabilities {
        try await request("/capabilities")
    }
}

public struct HealthStatus: Codable, Sendable {
    public let status: String
}
