import Foundation

/// VCU1 wire codec — byte-for-byte mirror of `tools/BxUsbDirect/Vcu1Codec.cs`.
/// Header size 24. Big-endian multi-byte fields. Do not invent offsets.
enum Vcu1Codec {
    static let headerSize = 24
    static let protocolVersion: UInt8 = 1
    static let maxPayload = 0x400000

    /// Proven immediates from binaries (semantic labels still partial).
    static let typeProvenPayloadEnqueue: UInt8 = 3
    static let typeProvenRelaySpecial: UInt8 = 6

    struct Packet {
        var type: UInt8
        var flags: UInt16
        var sequence: UInt32
        var ptsUs: UInt64
        var payload: Data
    }

    static func tryDecode(_ buf: Data, offset: Int = 0) -> (Packet?, String?) {
        let length = buf.count - offset
        if length < headerSize { return (nil, "short header") }
        if buf[offset] != 0x56 || buf[offset + 1] != 0x43 ||
            buf[offset + 2] != 0x55 || buf[offset + 3] != 0x31 {
            return (nil, "bad magic")
        }
        if buf[offset + 4] != protocolVersion { return (nil, "bad version") }
        let type = buf[offset + 5]
        let flags = readU16BE(buf, offset + 6)
        let plen = readU32BE(buf, offset + 8)
        if plen > UInt32(maxPayload) { return (nil, "payload too large") }
        if length < headerSize + Int(plen) { return (nil, "short payload") }
        let seq = readU32BE(buf, offset + 12)
        let pts = readU64BE(buf, offset + 16)
        let payloadStart = offset + headerSize
        let payload = buf.subdata(in: payloadStart..<(payloadStart + Int(plen)))
        return (Packet(type: type, flags: flags, sequence: seq, ptsUs: pts, payload: payload), nil)
    }

    static func readU16BE(_ b: Data, _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    static func readU32BE(_ b: Data, _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func readU64BE(_ b: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }
}
