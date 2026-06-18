import Foundation

public struct ArchiveInfo: Sendable {
    /// `ar-…` identifier suitable for `Sandbox.create(.init(archiveId:))`.
    public let id: String
    /// Sandbox name the archive was finalized under.
    public let sandboxId: String
    /// S3 object key the archive is stored at.
    public let s3Key: String
    /// Compressed size in bytes.
    public let sizeBytes: Int
    /// Display name, or `nil` when none was set.
    public let name: String?
    /// RFC 3339 timestamp.
    public let createdAt: String
}

private struct RawArchive: Decodable {
    let id: String
    let sandboxId: String
    let s3Key: String
    let sizeBytes: Int
    let name: String?
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, name
        case sandboxId = "sandbox_id"
        case s3Key = "s3_key"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }
    var resolved: ArchiveInfo {
        ArchiveInfo(
            id: id, sandboxId: sandboxId, s3Key: s3Key, sizeBytes: sizeBytes,
            name: name, createdAt: createdAt)
    }
}

/// Cloud sandbox archives — the tar.gz bundles created by ``archiveDir(_:options:clientOptions:)``.
/// Cloud-only; the local heyvm API has no listing route.
public enum Archives {
    /// Tar+gzip a local directory and upload it as a new archive. Alias for the
    /// free ``archiveDir(_:options:clientOptions:)`` function.
    public static func fromDir(
        _ localPath: String,
        options: ArchiveDirOptions = ArchiveDirOptions(),
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> ArchiveResult {
        try await archiveDirImpl(localPath, options: options, clientOptions: clientOptions)
    }

    private struct ListResponse: Decodable { let archives: [RawArchive]? }

    /// `GET /sandbox-archives` — list every archive the caller owns.
    public static func list(
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> [ArchiveInfo] {
        let client = HeyoClient(clientOptions)
        let resp: ListResponse = try await client.request("/sandbox-archives")
        return (resp.archives ?? []).map(\.resolved)
    }

    /// `GET /sandbox-archives/{id}` — download the archive's tar.gz bytes.
    public static func download(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws -> Data {
        let client = HeyoClient(clientOptions)
        let (data, _) = try await client.rawRequest("/sandbox-archives/\(pathEscape(id))")
        return data
    }

    /// `DELETE /sandbox-archives/{id}`. Idempotent — a 404 is a no-op.
    public static func delete(
        _ id: String,
        clientOptions: HeyoClientOptions = HeyoClientOptions()
    ) async throws {
        let client = HeyoClient(clientOptions)
        do {
            try await client.send("/sandbox-archives/\(pathEscape(id))", method: "DELETE")
        } catch HeyoError.notFound {
            return
        }
    }
}
