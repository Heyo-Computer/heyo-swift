import Foundation
import Compression

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let defaultMountPath = "/workspace"

private let excludedDirs: Set<String> = [
    "node_modules", ".git", "target", "__pycache__", ".cache", ".npm", ".cargo",
    "dist", ".next", ".nuxt", "build", "vendor", ".venv", "venv", ".tox",
]

public struct ArchiveDirOptions: Sendable {
    /// Display name for the archive in the cloud.
    public var name: String?
    /// Mount path prefix for files inside the archive. Default: `/workspace`.
    public var mountPath: String?
    /// Skip the default exclude list and include every file.
    public var noIgnore: Bool
    /// Extra directory names to exclude (matched on the path segment).
    public var extraExcludes: [String]
    public init(
        name: String? = nil,
        mountPath: String? = nil,
        noIgnore: Bool = false,
        extraExcludes: [String] = []
    ) {
        self.name = name
        self.mountPath = mountPath
        self.noIgnore = noIgnore
        self.extraExcludes = extraExcludes
    }
}

public struct ArchiveResult: Sendable {
    /// `ar-…` identifier suitable for `Sandbox.create(.init(archiveId:))`.
    public let id: String
    /// Compressed size of the uploaded archive, in bytes.
    public let sizeBytes: Int
    /// ISO-8601 timestamp the archive was finalized.
    public let createdAt: String
}

/// Tar+gzip a local directory and upload it as a sandbox archive — same flow as
/// the `heyvm archive-dir` CLI. Returns the new `ar-…` id, suitable for
/// `Sandbox.create(.init(archiveId:))`.
public func archiveDir(
    _ localPath: String,
    options: ArchiveDirOptions = ArchiveDirOptions(),
    clientOptions: HeyoClientOptions = HeyoClientOptions()
) async throws -> ArchiveResult {
    try await archiveDirImpl(localPath, options: options, clientOptions: clientOptions)
}

func archiveDirImpl(
    _ localPath: String,
    options: ArchiveDirOptions,
    clientOptions: HeyoClientOptions
) async throws -> ArchiveResult {
    let fm = FileManager.default
    let dir = (localPath as NSString).expandingTildeInPath
    let resolved = URL(fileURLWithPath: dir).standardizedFileURL
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
        throw HeyoError.invalidArgument("Invalid path '\(localPath)': no such file or directory")
    }
    guard isDir.boolValue else {
        throw HeyoError.invalidArgument("'\(resolved.path)' is not a directory")
    }

    let prefix = (options.mountPath ?? defaultMountPath).drop(while: { $0 == "/" })
    let sandboxPathPrefix = String(prefix)
    let excluded: Set<String> = options.noIgnore ? [] : excludedDirs.union(options.extraExcludes)

    let files = try collectDirFiles(root: resolved, prefix: sandboxPathPrefix, excluded: excluded)
    if files.isEmpty {
        throw HeyoError.invalidArgument("No files found in directory to archive")
    }

    let tarGz = gzip(buildTar(files))

    let client = HeyoClient(clientOptions)
    struct Slot: Decodable {
        let archiveId: String
        let uploadUrl: String
        enum CodingKeys: String, CodingKey {
            case archiveId = "archive_id"
            case uploadUrl = "upload_url"
        }
    }
    let slot: Slot = try await client.request("/sandbox-archives/presign", method: "POST")

    try await uploadToPresignedUrl(slot.uploadUrl, body: tarGz)

    var finalizeBody: [String: JSONValue] = ["sandbox_id": .string(resolved.lastPathComponent)]
    if let name = options.name { finalizeBody["name"] = .string(name) }

    struct Finalized: Decodable {
        let id: String
        let sizeBytes: Int
        let createdAt: String
        enum CodingKeys: String, CodingKey {
            case id
            case sizeBytes = "size_bytes"
            case createdAt = "created_at"
        }
    }
    let finalized: Finalized = try await client.request(
        "/sandbox-archives/\(pathEscape(slot.archiveId))/finalize",
        method: "POST", body: .object(finalizeBody))

    return ArchiveResult(id: finalized.id, sizeBytes: finalized.sizeBytes, createdAt: finalized.createdAt)
}

// MARK: - Directory walk

struct TarFileEntry {
    let path: String  // path inside the archive, no leading slash
    let content: Data
}

func collectDirFiles(root: URL, prefix: String, excluded: Set<String>) throws -> [TarFileEntry] {
    let fm = FileManager.default
    var out: [TarFileEntry] = []

    func walk(_ absDir: URL, _ relDir: String) throws {
        let entries = try fm.contentsOfDirectory(
            at: absDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        for entry in entries {
            let name = entry.lastPathComponent
            let childRel = relDir.isEmpty ? name : "\(relDir)/\(name)"
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue  // skip symlinks, matching the CLI
            }
            if values.isDirectory == true {
                if excluded.contains(name) { continue }
                try walk(entry, childRel)
            } else if values.isRegularFile == true {
                let content = try Data(contentsOf: entry)
                let archivePath = prefix.isEmpty ? childRel : "\(prefix)/\(childRel)"
                out.append(TarFileEntry(path: archivePath, content: content))
            }
        }
    }

    try walk(root, "")
    return out.sorted { $0.path < $1.path }
}

// MARK: - Tar builder (POSIX/GNU ustar, mirrors sdk-ts/src/archive.ts)

func buildTar(_ files: [TarFileEntry], mtime: Int? = nil) -> Data {
    let now = mtime ?? Int(Date().timeIntervalSince1970)
    var out = Data()

    var dirSet = Set<String>()
    for f in files {
        var parts = f.path.split(separator: "/").map(String.init)
        parts.removeLast()
        var acc = ""
        for part in parts {
            acc = acc.isEmpty ? part : "\(acc)/\(part)"
            dirSet.insert(acc)
        }
    }
    for dir in dirSet.sorted() {
        appendEntry(&out, name: "\(dir)/", content: Data(), mode: 0o755, mtime: now, typeflag: "5")
    }
    for f in files {
        appendEntry(&out, name: f.path, content: f.content, mode: 0o644, mtime: now, typeflag: "0")
    }
    out.append(Data(count: 1024))  // two zero blocks terminate the archive
    return out
}

private func appendEntry(
    _ out: inout Data, name: String, content: Data, mode: Int, mtime: Int, typeflag: Character
) {
    let nameBytes = Array(name.utf8)

    if nameBytes.count > 100 {
        var longName = nameBytes
        longName.append(0)
        out.append(buildHeader(
            name: Array("././@LongLink".utf8), mode: 0, uid: 0, gid: 0,
            size: longName.count, mtime: 0, typeflag: "L", magic: "ustar ", version: " \0"))
        out.append(contentsOf: longName)
        out.append(pad512(longName.count))
    }

    let truncated = Array(nameBytes.prefix(100))
    out.append(buildHeader(
        name: truncated, mode: mode, uid: 1000, gid: 1000,
        size: content.count, mtime: mtime, typeflag: typeflag, magic: "ustar\0", version: "00"))
    if !content.isEmpty {
        out.append(content)
        out.append(pad512(content.count))
    }
}

private func buildHeader(
    name: [UInt8], mode: Int, uid: Int, gid: Int, size: Int, mtime: Int,
    typeflag: Character, magic: String, version: String
) -> Data {
    var buf = [UInt8](repeating: 0, count: 512)

    for (i, b) in name.prefix(100).enumerated() { buf[i] = b }
    writeOctal(&buf, 100, 8, mode)
    writeOctal(&buf, 108, 8, uid)
    writeOctal(&buf, 116, 8, gid)
    writeOctalSpace(&buf, 124, 12, size)
    writeOctalSpace(&buf, 136, 12, mtime)
    for i in 148..<156 { buf[i] = 0x20 }
    buf[156] = typeflag.asciiValue ?? 0x30
    for (i, b) in Array(magic.utf8).prefix(6).enumerated() { buf[257 + i] = b }
    for (i, b) in Array(version.utf8).prefix(2).enumerated() { buf[263 + i] = b }

    var sum = 0
    for b in buf { sum += Int(b) }
    let sumStr = String(repeating: "0", count: max(0, 6 - String(sum, radix: 8).count)) + String(sum, radix: 8)
    for (i, b) in Array(sumStr.utf8).prefix(6).enumerated() { buf[148 + i] = b }
    buf[154] = 0
    buf[155] = 0x20

    return Data(buf)
}

private func writeOctal(_ buf: inout [UInt8], _ offset: Int, _ width: Int, _ value: Int) {
    let s = String(value, radix: 8)
    let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
    let bytes = Array(padded.utf8.prefix(width - 1))
    for i in 0..<(width - 1) { buf[offset + i] = i < bytes.count ? bytes[i] : 0x30 }
    buf[offset + width - 1] = 0
}

private func writeOctalSpace(_ buf: inout [UInt8], _ offset: Int, _ width: Int, _ value: Int) {
    let s = String(value, radix: 8)
    let padded = String(repeating: "0", count: max(0, width - 1 - s.count)) + s
    let bytes = Array(padded.utf8.prefix(width - 1))
    for i in 0..<(width - 1) { buf[offset + i] = i < bytes.count ? bytes[i] : 0x30 }
    buf[offset + width - 1] = 0x20
}

private func pad512(_ len: Int) -> Data {
    let r = len % 512
    return r == 0 ? Data() : Data(count: 512 - r)
}

// MARK: - gzip

/// Wrap raw DEFLATE output from the Compression framework in a gzip container.
func gzip(_ input: Data) -> Data {
    var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])  // header (mtime=0, OS=unknown)
    out.append(rawDeflate(input))
    var crc = crc32(input).littleEndian
    withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
    var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
    withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
    return out
}

private func rawDeflate(_ input: Data) -> Data {
    if input.isEmpty {
        // DEFLATE empty stream: a single empty stored block.
        return Data([0x03, 0x00])
    }
    let dstCapacity = input.count + (input.count / 2) + 64 * 1024
    var dst = Data(count: dstCapacity)
    let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
        input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(
                dstRaw.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                srcRaw.bindMemory(to: UInt8.self).baseAddress!, input.count,
                nil, COMPRESSION_ZLIB)
        }
    }
    return dst.prefix(written)
}

private let crcTable: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }
}()

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

// MARK: - Upload

private func uploadToPresignedUrl(_ urlString: String, body: Data) async throws {
    guard let url = URL(string: urlString) else {
        throw HeyoError.invalidArgument("Invalid presigned upload URL")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
    req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    req.httpBody = body
    let session = URLSession(configuration: .default)
    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else {
        throw HeyoError.api(status: 0, message: "Non-HTTP response from archive upload", body: data)
    }
    guard (200...299).contains(http.statusCode) else {
        let text = String(data: data, encoding: .utf8) ?? ""
        throw HeyoError.api(
            status: http.statusCode,
            message: "Archive upload failed (\(http.statusCode)): \(text)", body: data)
    }
}
