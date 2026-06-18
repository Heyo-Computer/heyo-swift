import Foundation

/// Shell wire-frame tags. Internal so the unit tests can assert the exact byte
/// layout against the protocol in `mvm-ctrl/src/api.rs::shell_stream_ws`.
enum ShellFrame {
    static let stdin: UInt8 = 0x01
    static let stdout: UInt8 = 0x02

    /// Wrap stdin bytes: `[0x01, ...bytes]`.
    static func encodeStdin(_ data: Data) -> Data {
        var frame = Data([stdin])
        frame.append(data)
        return frame
    }

    /// Parse a stdout frame `[0x02, seq:u64-be, ...bytes]`. Returns `nil` for a
    /// malformed or non-stdout frame.
    static func decodeStdout(_ data: Data) -> (seq: UInt64, payload: Data)? {
        guard let tag = data.first, tag == stdout, data.count >= 9 else { return nil }
        var seq: UInt64 = 0
        for byte in data[data.startIndex + 1 ..< data.startIndex + 9] {
            seq = (seq << 8) | UInt64(byte)
        }
        let payload = data.subdata(in: (data.startIndex + 9) ..< data.endIndex)
        return (seq, payload)
    }
}
