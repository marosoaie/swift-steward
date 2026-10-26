/// Pins output too long to spell out in a test: its length in bytes and
/// 64-bit FNV-1a hash, as `length:hex`, as SwiftStewardTests pins the
/// `steward` command's.
enum Fingerprint {
    static func of(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let hash = bytes.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(bytes.count):\(String(hash, radix: 16))"
    }
}
