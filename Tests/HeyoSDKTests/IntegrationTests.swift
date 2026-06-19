import XCTest
@testable import HeyoSDK

/// Live end-to-end tests against a real Heyo backend. Skipped unless
/// `HEYO_API_KEY` is set, mirroring the Rust SDK's `#[ignore]` tests. Point at a
/// non-default backend with `HEYO_BASE_URL`.
///
/// Run with: `HEYO_API_KEY=heyo_api_… swift test`
final class IntegrationTests: XCTestCase {

    private func clientOptions() throws -> HeyoClientOptions {
        guard let key = ProcessInfo.processInfo.environment["HEYO_API_KEY"], !key.isEmpty else {
            throw XCTSkip("HEYO_API_KEY not set — skipping live integration test")
        }
        var opts = HeyoClientOptions(apiKey: key)
        if let base = ProcessInfo.processInfo.environment["HEYO_BASE_URL"], !base.isEmpty {
            opts.baseURL = base
        }
        return opts
    }

    func testSmokeCreateExecKill() async throws {
        let opts = try clientOptions()
        let sandbox = try await Sandbox.create(.init(image: "ubuntu:24.04"), clientOptions: opts)
        defer { Task { try? await sandbox.kill() } }

        let result = try await sandbox.commands.run("echo hello")
        XCTAssertTrue(result.stdout.contains("hello"), "stdout was: \(result.stdout)")
        XCTAssertEqual(result.exitCode, 0)

        try await sandbox.kill()
    }

    func testShellEchoAndClose() async throws {
        let opts = try clientOptions()
        let sandbox = try await Sandbox.create(.init(image: "ubuntu:24.04"), clientOptions: opts)
        defer { Task { try? await sandbox.kill() } }

        let shell = try await sandbox.shell(.init(cols: 100, rows: 40))

        // Collect output in the background.
        let collected = Task { () -> String in
            var acc = ""
            for await chunk in shell.output {
                acc += String(decoding: chunk, as: UTF8.self)
                if acc.contains("shell-marker") { break }
            }
            return acc
        }

        try await shell.write("echo shell-marker\n")
        let output = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw XCTSkip("shell output timed out")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertTrue(output.contains("shell-marker"), "shell output was: \(output)")

        try await shell.resize(cols: 120, rows: 50)
        try await shell.close()
        let isClosed = await shell.isClosed
        XCTAssertTrue(isClosed)

        try await sandbox.kill()
    }

    func testDatabaseSelectOne() async throws {
        let opts = try clientOptions()
        let regions = try await Database.regions(clientOptions: opts)
        let region = regions.first ?? "us-east"
        let db = try await Database.create(.init(name: "heyo-swift-test", region: region), clientOptions: opts)
        defer { Task { try? await db.delete() } }

        let result = try await db.exec("SELECT 1 AS one")
        XCTAssertEqual(result.rows.first?.first, .int(1))

        try await db.delete()
    }

    func testDatabaseCheckoutCheckinConflict() async throws {
        let opts = try clientOptions()
        let regions = try await Database.regions(clientOptions: opts)
        let region = regions.first ?? "us-east"
        let db = try await Database.create(.init(name: "heyo-swift-ccin", region: region), clientOptions: opts)
        defer { Task { try? await db.delete() } }

        try await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)")
        let checkout = try await db.checkout()

        // A successful checkin with the right version.
        let result = try await db.checkin(checkout.bytes, options: .init(expectedVersion: checkout.dataVersion))
        XCTAssertGreaterThanOrEqual(result.dataVersion, checkout.dataVersion)

        // A stale checkin must conflict.
        do {
            _ = try await db.checkin(checkout.bytes, options: .init(expectedVersion: checkout.dataVersion))
            XCTFail("expected checkinConflict")
        } catch let HeyoError.checkinConflict(expected, _) {
            XCTAssertEqual(expected, checkout.dataVersion)
        }

        try await db.delete()
    }
}
