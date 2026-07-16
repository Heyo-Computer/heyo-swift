import XCTest
import Compression
@testable import HeyoSDK

/// Pure-logic tests — no network. These verify the wire encodings the SDK must
/// match byte-for-byte against the TS/Rust SDKs and the cloud.
final class UnitTests: XCTestCase {

    // MARK: - Shell frames

    func testStdinFrameLayout() {
        let frame = ShellFrame.encodeStdin(Data("ls\n".utf8))
        XCTAssertEqual(frame.first, 0x01)
        XCTAssertEqual(Array(frame.dropFirst()), Array("ls\n".utf8))
    }

    func testStdoutFrameRoundTrip() {
        // [0x02, seq:u64-be, ...payload]
        let seq: UInt64 = 0x0102_0304_0506_0708
        var frame = Data([0x02])
        frame.append(contentsOf: withUnsafeBytes(of: seq.bigEndian) { Array($0) })
        frame.append(Data("hi".utf8))

        let decoded = ShellFrame.decodeStdout(frame)
        XCTAssertEqual(decoded?.seq, seq)
        XCTAssertEqual(decoded?.payload, Data("hi".utf8))
    }

    func testStdoutFrameRejectsShortOrWrongTag() {
        XCTAssertNil(ShellFrame.decodeStdout(Data([0x02, 0, 0, 0])))      // too short
        XCTAssertNil(ShellFrame.decodeStdout(Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0]))) // wrong tag
        XCTAssertNil(ShellFrame.decodeStdout(Data()))                     // empty
    }

    func testStdoutFrameEmptyPayload() {
        var frame = Data([0x02])
        frame.append(contentsOf: [UInt8](repeating: 0, count: 7))
        frame.append(42)  // seq = 42
        let decoded = ShellFrame.decodeStdout(frame)
        XCTAssertEqual(decoded?.seq, 42)
        XCTAssertEqual(decoded?.payload, Data())
    }

    // MARK: - SqlValue coding

    func testSqlValueRoundTrip() throws {
        let values: [SqlValue] = [.null, .bool(true), .int(42), .double(3.5), .text("hi")]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([SqlValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testSqlValueDecodesWireRow() throws {
        let json = Data("[null, true, 7, \"name\"]".utf8)
        let row = try JSONDecoder().decode([SqlValue].self, from: json)
        XCTAssertEqual(row, [.null, .bool(true), .int(7), .text("name")])
    }

    // MARK: - JSONValue helpers

    func testObjectDroppingNil() {
        let obj = JSONValue.object(droppingNil: [
            "keep": .string("x"),
            "drop": nil,
            "zero": .int(0),
        ])
        guard case let .object(dict) = obj else { return XCTFail("not an object") }
        XCTAssertEqual(Set(dict.keys), ["keep", "zero"])
    }

    // MARK: - Status decoding

    func testSandboxStatusDecoding() throws {
        func decode(_ s: String) throws -> SandboxStatus {
            try JSONDecoder().decode(SandboxStatus.self, from: Data("\"\(s)\"".utf8))
        }
        XCTAssertEqual(try decode("running"), .running)
        XCTAssertEqual(try decode("cold-stored"), .coldStored)
        XCTAssertEqual(try decode("something-new"), .unknown)
    }

    // MARK: - Error mapping

    func testValidateStatusMapping() {
        func status(_ code: Int) -> HeyoError? {
            let http = HTTPURLResponse(
                url: URL(string: "https://x/y")!, statusCode: code,
                httpVersion: nil, headerFields: nil)!
            do {
                try HeyoClient.validate(http, data: Data("{\"message\":\"boom\"}".utf8), path: "/y")
                return nil
            } catch let e as HeyoError {
                return e
            } catch {
                return nil
            }
        }
        if case .authentication = status(401) {} else { XCTFail("401") }
        if case .authentication = status(403) {} else { XCTFail("403") }
        if case .notFound = status(404) {} else { XCTFail("404") }
        if case .invalidArgument = status(400) {} else { XCTFail("400") }
        if case .invalidArgument = status(422) {} else { XCTFail("422") }
        if case let .api(s, _, _) = status(500) { XCTAssertEqual(s, 500) } else { XCTFail("500") }
        XCTAssertNil(status(204))  // 2xx does not throw
    }

    // MARK: - Tar + gzip

    func testTarHeaderFieldsAndChecksum() {
        let tar = buildTar([TarFileEntry(path: "workspace/a.txt", content: Data("hello".utf8))], mtime: 0)
        // Find the file header (after the dir entries). Scan 512-byte blocks for
        // the one whose name starts with "workspace/a.txt".
        var found = false
        var offset = 0
        while offset + 512 <= tar.count {
            let block = tar.subdata(in: offset ..< offset + 512)
            let name = String(decoding: block.prefix(while: { $0 != 0 }), as: UTF8.self)
            if name == "workspace/a.txt" {
                found = true
                // ustar magic at offset 257.
                let magic = block.subdata(in: 257 ..< 263)
                XCTAssertEqual(Array(magic), Array("ustar\0".utf8))
                // size octal at 124, width 12 → "00000000005" + space (5 bytes).
                let sizeField = String(decoding: block.subdata(in: 124 ..< 135), as: UTF8.self)
                XCTAssertEqual(Int(sizeField, radix: 8), 5)
                // Verify checksum.
                var sum = 0
                var b = Array(block)
                for i in 148..<156 { b[i] = 0x20 }
                for byte in b { sum += Int(byte) }
                let recorded = String(decoding: block.subdata(in: 148 ..< 154), as: UTF8.self)
                XCTAssertEqual(Int(recorded, radix: 8), sum)
            }
            offset += 512
        }
        XCTAssertTrue(found, "file header not found in tar")
    }

    func testGzipRoundTrip() throws {
        let original = Data("the quick brown fox ".utf8) + Data(repeating: 0x41, count: 5000)
        let compressed = gzip(original)
        // gzip magic + deflate method.
        XCTAssertEqual(Array(compressed.prefix(3)), [0x1f, 0x8b, 0x08])
        // ISIZE trailer == original length (mod 2^32).
        let isize = compressed.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(isize, UInt32(original.count))
        // Inflate the raw DEFLATE body and confirm it matches.
        let body = compressed.subdata(in: 10 ..< (compressed.count - 8))
        let inflated = inflateRaw(body, expectedSize: original.count)
        XCTAssertEqual(inflated, original)
    }

    /// Inflate a raw DEFLATE stream via the Compression framework.
    private func inflateRaw(_ data: Data, expectedSize: Int) -> Data {
        let dstCapacity = max(expectedSize, 64)
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dstRaw.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return dst.prefix(written)
    }

    // MARK: - Client config

    func testLocalClientHasNoAuth() {
        let client = HeyoClient.local()
        XCTAssertEqual(client.baseURL, "http://127.0.0.1:34099")
        XCTAssertNil(client.wsAuthorization())
    }

    func testWsURLSchemeSwap() {
        let cloud = HeyoClient(HeyoClientOptions(apiKey: "k", baseURL: "https://server.heyo.computer"))
        XCTAssertEqual(cloud.wsURL("/x").scheme, "wss")
        XCTAssertEqual(cloud.wsAuthorization(), "Bearer k")
        let local = HeyoClient.local()
        XCTAssertEqual(local.wsURL("/x").scheme, "ws")
    }

    // MARK: - Transfer (receive) wire coding

    func testTransferStatusDecodesDoneRow() throws {
        let json = Data("""
        {"receive_id":"rcv-1234abcd","bundle_id":"bnd-5678ef01",
         "status":"done","restored_id":"sb-99","memory_restored":true,
         "error":null,"bytes_received":1048576}
        """.utf8)
        let s = try JSONDecoder().decode(TransferReceiveStatus.self, from: json)
        XCTAssertEqual(s.status, .done)
        XCTAssertTrue(s.status.isTerminal)
        XCTAssertEqual(s.restoredId, "sb-99")
        XCTAssertEqual(s.memoryRestored, true)
        XCTAssertEqual(s.bytesReceived, 1_048_576)
    }

    func testTransferStatusToleratesPartialPullingRow() throws {
        // Mid-flight rows omit restored_id/memory_restored; bytes may be absent.
        let json = Data(#"{"receive_id":"rcv-1","bundle_id":"bnd-1","status":"pulling"}"#.utf8)
        let s = try JSONDecoder().decode(TransferReceiveStatus.self, from: json)
        XCTAssertEqual(s.status, .pulling)
        XCTAssertFalse(s.status.isTerminal)
        XCTAssertNil(s.restoredId)
        XCTAssertEqual(s.bytesReceived, 0)
    }

    func testTransferStatusMapsUnknownPhase() throws {
        let json = Data(#"{"receive_id":"rcv-1","bundle_id":"bnd-1","status":"verifying"}"#.utf8)
        let s = try JSONDecoder().decode(TransferReceiveStatus.self, from: json)
        XCTAssertEqual(s.status, .unknown)
    }

    func testReceiveOptionsDefaults() {
        let o = ReceiveOptions()
        XCTAssertTrue(o.startAfter)
        XCTAssertFalse(o.requireMemory)
        XCTAssertNil(o.name)
        XCTAssertNil(o.backend)
        XCTAssertNil(o.relay)
    }
}
