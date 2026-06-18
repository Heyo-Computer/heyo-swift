import Foundation

/// Command-execution surface, accessed via `sandbox.commands`.
///
/// The cloud's `/exec` endpoint runs the command with `sh -c`, so quoting and
/// pipelines behave as in a standard POSIX shell.
public struct Commands: Sendable {
    private let client: HeyoClient
    private let sandboxId: String

    init(client: HeyoClient, sandboxId: String) {
        self.client = client
        self.sandboxId = sandboxId
    }

    private struct RawResult: Decodable {
        let stdout: String?
        let stderr: String?
        let output: String?
        let exitCode: Int?
        enum CodingKeys: String, CodingKey {
            case stdout, stderr, output
            case exitCode = "exit_code"
        }
    }

    /// Execute `command` inside the sandbox and wait for it to finish.
    @discardableResult
    public func run(
        _ command: String,
        options: CommandRunOptions = CommandRunOptions()
    ) async throws -> CommandResult {
        let body = JSONValue.object(droppingNil: [
            "command": .string(command),
            "cwd": options.cwd.map(JSONValue.string),
            "env": options.env.map { .object($0.mapValues(JSONValue.string)) },
        ])

        let raw: RawResult = try await client.request(
            "/sandbox/\(pathEscape(sandboxId))/exec",
            method: "POST",
            body: body,
            timeout: options.timeout)

        return CommandResult(
            stdout: raw.stdout ?? "",
            stderr: raw.stderr ?? "",
            exitCode: raw.exitCode ?? 0,
            output: raw.output ?? "")
    }
}

/// Percent-encode a single path segment (the cloud ids are URL-safe, but keep
/// parity with the TS SDK's `encodeURIComponent`).
func pathEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
}
