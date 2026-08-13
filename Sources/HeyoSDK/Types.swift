import Foundation

// MARK: - Enums

public enum SandboxRegion: String, Codable, Sendable {
    case us = "US"
    case eu = "EU"
}

public enum SandboxDriver: String, Codable, Sendable {
    case libvirt
    case firecracker
    case kvm
}

public enum SandboxSize: String, Codable, Sendable {
    case micro, mini, small, medium, large, xlarge
}

/// Lifecycle states the cloud reports. `provisioning` covers both queued and
/// actively-creating sandboxes. `failed` is terminal — recreate to retry.
/// Decodes unknown values to ``unknown`` rather than throwing.
public enum SandboxStatus: String, Codable, Sendable {
    case provisioning
    case running
    case stopped
    case paused
    case failed
    case coldStored = "cold-stored"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SandboxStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Bound URLs

public struct BoundUrl: Codable, Sendable, Equatable {
    public let subdomain: String
    public let hostname: String
    public let url: String
    public let port: Int
    public let isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case subdomain, hostname, url, port
        case isPublic = "is_public"
    }
}

// MARK: - Sandbox info

/// Snapshot of a deployed sandbox. Field names mirror the cloud's
/// `DeployedSandboxInfo`.
public struct SandboxInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let status: SandboxStatus
    public let image: String
    public let region: String?
    public let startCommand: String?
    public let workingDirectory: String?
    public let sizeClass: String?
    /// Effective Firecracker/KVM workspace disk size in GiB, when the backend
    /// reports one.
    public let diskSizeGb: Int?
    public let envVars: [String: String]?
    public let setupHooks: [String]?
    public let uptimeSecs: Int
    public let ttlSeconds: Int?
    public let isDeployed: Bool
    public let errorMessage: String?
    public let statusChangedAt: String
    public let urls: [BoundUrl]

    enum CodingKeys: String, CodingKey {
        case id, name, status, image, region, urls
        case startCommand = "start_command"
        case workingDirectory = "working_directory"
        case sizeClass = "size_class"
        case diskSizeGb = "disk_size_gb"
        case envVars = "env_vars"
        case setupHooks = "setup_hooks"
        case uptimeSecs = "uptime_secs"
        case ttlSeconds = "ttl_seconds"
        case isDeployed = "is_deployed"
        case errorMessage = "error_message"
        case statusChangedAt = "status_changed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(SandboxStatus.self, forKey: .status)
        image = try c.decode(String.self, forKey: .image)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        sizeClass = try c.decodeIfPresent(String.self, forKey: .sizeClass)
        diskSizeGb = try c.decodeIfPresent(Int.self, forKey: .diskSizeGb)
        envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars)
        setupHooks = try c.decodeIfPresent([String].self, forKey: .setupHooks)
        uptimeSecs = try c.decodeIfPresent(Int.self, forKey: .uptimeSecs) ?? 0
        ttlSeconds = try c.decodeIfPresent(Int.self, forKey: .ttlSeconds)
        isDeployed = try c.decodeIfPresent(Bool.self, forKey: .isDeployed) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        statusChangedAt = try c.decodeIfPresent(String.self, forKey: .statusChangedAt) ?? ""
        urls = try c.decodeIfPresent([BoundUrl].self, forKey: .urls) ?? []
    }
}

/// A public image available for sandbox creation. Pass `id` or `name` as the
/// `image` option to ``Sandbox/create(_:clientOptions:)``.
public struct PublicImage: Codable, Sendable {
    public let id: String
    public let name: String?
    public let description: String?
    public let backendType: String?
    public let format: String
    public let sizeBytes: Int
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, format
        case backendType = "backend_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        backendType = try c.decodeIfPresent(String.self, forKey: .backendType)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

// MARK: - Commands & files

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    /// Combined stdout+stderr as the backend reports it.
    public let output: String
}

public struct CommandRunOptions: Sendable {
    public var cwd: String?
    public var env: [String: String]?
    public var timeout: TimeInterval?

    public init(cwd: String? = nil, env: [String: String]? = nil, timeout: TimeInterval? = nil) {
        self.cwd = cwd
        self.env = env
        self.timeout = timeout
    }
}

public struct FileOptions: Sendable {
    /// Mount on which the path is rooted. Defaults to `/workspace`.
    public var mountPath: String?
    public init(mountPath: String? = nil) { self.mountPath = mountPath }
}

// MARK: - Sandbox create options

/// Options accepted by ``Sandbox/create(_:clientOptions:)``. All fields except
/// `image`/`region` may be omitted; the server applies defaults.
public struct SandboxCreateOptions: Sendable {
    public var name: String?
    public var archiveId: String?
    public var region: SandboxRegion?
    public var driver: SandboxDriver?
    public var image: String?
    public var startCommand: String?
    public var openPorts: [Int]?
    public var ttlSeconds: Int?
    public var diskSizeGb: Int?
    public var workingDirectory: String?
    public var envVars: [String: String]?
    public var setupHooks: [String]?
    public var sizeClass: SandboxSize?
    /// Pin this sandbox to a specific user-owned daemon (heyvmd). See ``Daemons``.
    public var daemonId: String?
    /// Maximum time `create` waits for the sandbox to leave `provisioning`.
    /// Default 5 minutes. Pass `0` to skip waiting.
    public var waitForReady: TimeInterval?

    public init(
        name: String? = nil,
        archiveId: String? = nil,
        region: SandboxRegion? = nil,
        driver: SandboxDriver? = nil,
        image: String? = nil,
        startCommand: String? = nil,
        openPorts: [Int]? = nil,
        ttlSeconds: Int? = nil,
        diskSizeGb: Int? = nil,
        workingDirectory: String? = nil,
        envVars: [String: String]? = nil,
        setupHooks: [String]? = nil,
        sizeClass: SandboxSize? = nil,
        daemonId: String? = nil,
        waitForReady: TimeInterval? = nil
    ) {
        self.name = name
        self.archiveId = archiveId
        self.region = region
        self.driver = driver
        self.image = image
        self.startCommand = startCommand
        self.openPorts = openPorts
        self.ttlSeconds = ttlSeconds
        self.diskSizeGb = diskSizeGb
        self.workingDirectory = workingDirectory
        self.envVars = envVars
        self.setupHooks = setupHooks
        self.sizeClass = sizeClass
        self.daemonId = daemonId
        self.waitForReady = waitForReady
    }
}

// MARK: - Logs

/// Which PTY stream a log line came from.
public enum LogSource: String, Codable, Sendable {
    case stdout, stderr
}

/// Severity as parsed from the log line, when one was present.
public enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

/// Filters for ``Sandbox/logs(_:)``.
public struct SandboxLogsOptions: Sendable {
    /// Maximum entries returned. Server default applies when omitted.
    public var limit: Int?
    /// Entries to skip (for paging).
    public var offset: Int?
    /// Only one stream. Omit for both.
    public var source: LogSource?
    /// Only entries at this level.
    public var level: LogLevel?

    public init(
        limit: Int? = nil,
        offset: Int? = nil,
        source: LogSource? = nil,
        level: LogLevel? = nil
    ) {
        self.limit = limit
        self.offset = offset
        self.source = source
        self.level = level
    }
}

/// One sandbox log line.
public struct SandboxLogEntry: Codable, Sendable {
    /// Unix timestamp in seconds.
    public let timestamp: Int
    public let source: LogSource
    /// Parsed level, or `nil` when the line carried none.
    public let level: String?
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
        source = try c.decodeIfPresent(LogSource.self, forKey: .source) ?? .stdout
        level = try c.decodeIfPresent(String.self, forKey: .level)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// A page of log entries returned by ``Sandbox/logs(_:)``.
public struct SandboxLogs: Codable, Sendable {
    public let logs: [SandboxLogEntry]
    /// Total entries available, before `limit`/`offset`.
    public let total: Int
    public let limit: Int
    public let offset: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logs = try c.decodeIfPresent([SandboxLogEntry].self, forKey: .logs) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

// MARK: - Snapshot images

/// Result of ``Sandbox/snapshotToImage(name:)``.
public struct SnapshotImageInfo: Codable, Sendable {
    /// Validated image name (also the filename stem in the image directory).
    public let name: String
    /// Absolute host path of the written image file.
    public let path: String
    public let sizeBytes: Int
    /// Backend the snapshot was taken from (`firecracker`, `kvm`, …).
    public let backendType: String

    enum CodingKeys: String, CodingKey {
        case name, path
        case sizeBytes = "size_bytes"
        case backendType = "backend_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        backendType = try c.decodeIfPresent(String.self, forKey: .backendType) ?? ""
    }
}

// MARK: - Local create-from-archive options

/// Options for ``Sandbox/createFromArchive(_:clientOptions:)`` — the local heyvm
/// API's native create path. When `s3ArchiveKey` is omitted the workspace starts
/// empty.
public struct SandboxFromArchiveOptions: Sendable {
    public var name: String
    /// Image name or slug, resolved by the local backend.
    public var image: String
    /// S3 key of an uploaded archive to extract into the workspace.
    public var s3ArchiveKey: String?
    /// Mount path of the workspace inside the VM. Default: `/workspace`.
    public var sandboxPath: String?
    /// Backend to create on (wire field `backend_type`). The local API accepts
    /// more values than the cloud (`firecracker`, `libvirt`, `kvm`,
    /// `apple_virt`, …) — see ``HeyoClient/capabilities()`` for what the host
    /// supports, which is why this is a `String` rather than ``SandboxDriver``.
    public var driver: String?
    public var startCommand: String?
    public var workingDirectory: String?
    public var envVars: [String: String]?
    public var setupHooks: [String]?
    public var openPorts: [Int]?
    /// TTL in seconds. Server default applies when omitted.
    public var ttlSeconds: Int?
    public var sizeClass: SandboxSize?
    /// Maximum time `createFromArchive` waits for the sandbox to leave
    /// `provisioning`. Default 5 minutes. Pass `0` to skip waiting.
    public var waitForReady: TimeInterval?

    public init(
        name: String,
        image: String,
        s3ArchiveKey: String? = nil,
        sandboxPath: String? = nil,
        driver: String? = nil,
        startCommand: String? = nil,
        workingDirectory: String? = nil,
        envVars: [String: String]? = nil,
        setupHooks: [String]? = nil,
        openPorts: [Int]? = nil,
        ttlSeconds: Int? = nil,
        sizeClass: SandboxSize? = nil,
        waitForReady: TimeInterval? = nil
    ) {
        self.name = name
        self.image = image
        self.s3ArchiveKey = s3ArchiveKey
        self.sandboxPath = sandboxPath
        self.driver = driver
        self.startCommand = startCommand
        self.workingDirectory = workingDirectory
        self.envVars = envVars
        self.setupHooks = setupHooks
        self.openPorts = openPorts
        self.ttlSeconds = ttlSeconds
        self.sizeClass = sizeClass
        self.waitForReady = waitForReady
    }
}

// MARK: - Host capabilities

/// Drivers the host supports, as reported by a local heyvm API's
/// `GET /capabilities`. The cloud does not serve this route.
public struct HostCapabilities: Codable, Sendable {
    public let targetOs: String
    public let supportedDrivers: [String]
    public let archiveSupportedDrivers: [String]
    public let defaultDriver: String
}
