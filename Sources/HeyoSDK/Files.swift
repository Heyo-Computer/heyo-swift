import Foundation

private let defaultMount = "/workspace"

/// File-system surface, accessed via `sandbox.files`.
///
/// The cloud encodes file payloads as base64 in JSON; this type hides that.
public struct Files: Sendable {
    private let client: HeyoClient
    private let sandboxId: String

    init(client: HeyoClient, sandboxId: String) {
        self.client = client
        self.sandboxId = sandboxId
    }

    private struct ReadResponse: Decodable {
        let content: String
    }

    /// Read the file at `filePath` (interpreted relative to `mountPath`) as
    /// raw bytes.
    public func read(
        _ filePath: String,
        options: FileOptions = FileOptions()
    ) async throws -> Data {
        let body = JSONValue.object([
            "file_path": .string(filePath),
            "mount_path": .string(options.mountPath ?? defaultMount),
        ])
        let resp: ReadResponse = try await client.request(
            "/sandbox/\(pathEscape(sandboxId))/read-file",
            method: "POST",
            body: body)
        guard let data = Data(base64Encoded: resp.content) else {
            throw HeyoError.api(
                status: 200, message: "Invalid base64 in read-file response", body: nil)
        }
        return data
    }

    /// Read the file at `filePath` as a UTF-8 string.
    public func readText(
        _ filePath: String,
        options: FileOptions = FileOptions()
    ) async throws -> String {
        let data = try await read(filePath, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    /// Write `content` (UTF-8) to `filePath`.
    public func write(
        _ filePath: String,
        text content: String,
        options: FileOptions = FileOptions()
    ) async throws {
        try await write(filePath, data: Data(content.utf8), options: options)
    }

    /// Write raw `content` bytes to `filePath`.
    public func write(
        _ filePath: String,
        data content: Data,
        options: FileOptions = FileOptions()
    ) async throws {
        let body = JSONValue.object([
            "file_path": .string(filePath),
            "mount_path": .string(options.mountPath ?? defaultMount),
            "content": .string(content.base64EncodedString()),
        ])
        try await client.send(
            "/sandbox/\(pathEscape(sandboxId))/write-file",
            method: "POST",
            body: body)
    }
}
