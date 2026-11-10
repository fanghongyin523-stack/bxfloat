using System;
using System.IO;

/// VCU1 wire codec — fields proven from vcamtang-obs-usb.dll header builder + Relay parser.
/// Header size 24 (0x18). Big-endian multi-byte fields.
public static class Vcu1Codec {
    public const int HeaderSize = 24;
    public const uint Magic = 0x31554356; // 'VCU1' little-endian memory image of bytes 56 43 55 31
    public const byte ProtocolVersion = 1;
    public const int MaxPayload = 0x400000; // Relay/DLL reject larger

    // Proven immediates from binaries (semantic labels still partial — see docs).
    public const byte TypeProvenPayloadEnqueue = 3; // DLL packet enqueue [obj+8]=3
    public const byte TypeProvenRelaySpecial = 6;   // Relay cmp type==6 then special path

    public struct Packet {
        public byte Type;
        public ushort Flags;
        public uint Sequence;
        public ulong PtsUs;
        public byte[] Payload;
    }

    public static byte[] Encode(Packet p) {
        if (p.Payload == null) p.Payload = Array.Empty<byte>();
        if (p.Payload.Length > MaxPayload) throw new ArgumentOutOfRangeException("payload too large");
        byte[] buf = new byte[HeaderSize + p.Payload.Length];
        // magic VCU1 as on-wire bytes
        buf[0] = (byte)'V';
        buf[1] = (byte)'C';
        buf[2] = (byte)'U';
        buf[3] = (byte)'1';
        buf[4] = ProtocolVersion;
        buf[5] = p.Type;
        WriteU16BE(buf, 6, p.Flags);
        WriteU32BE(buf, 8, (uint)p.Payload.Length);
        WriteU32BE(buf, 12, p.Sequence);
        WriteU64BE(buf, 16, p.PtsUs);
        Buffer.BlockCopy(p.Payload, 0, buf, HeaderSize, p.Payload.Length);
        return buf;
    }

    public static bool TryDecode(byte[] buf, int offset, int length, out Packet p, out string err) {
        p = default(Packet);
        err = null;
        if (length < HeaderSize) { err = "short header"; return false; }
        if (buf[offset] != (byte)'V' || buf[offset + 1] != (byte)'C' ||
            buf[offset + 2] != (byte)'U' || buf[offset + 3] != (byte)'1') {
            err = "bad magic";
            return false;
        }
        if (buf[offset + 4] != ProtocolVersion) { err = "bad version"; return false; }
        byte type = buf[offset + 5];
        ushort flags = ReadU16BE(buf, offset + 6);
        uint plen = ReadU32BE(buf, offset + 8);
        if (plen > MaxPayload) { err = "payload too large"; return false; }
        if (length < HeaderSize + (int)plen) { err = "short payload"; return false; }
        uint seq = ReadU32BE(buf, offset + 12);
        ulong pts = ReadU64BE(buf, offset + 16);
        byte[] payload = new byte[plen];
        Buffer.BlockCopy(buf, offset + HeaderSize, payload, 0, (int)plen);
        p = new Packet { Type = type, Flags = flags, Sequence = seq, PtsUs = pts, Payload = payload };
        return true;
    }

    public static void WriteU16BE(byte[] b, int o, ushort v) {
        b[o] = (byte)(v >> 8); b[o + 1] = (byte)v;
    }
    public static void WriteU32BE(byte[] b, int o, uint v) {
        b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16);
        b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v;
    }
    public static void WriteU64BE(byte[] b, int o, ulong v) {
        for (int i = 7; i >= 0; i--) { b[o + (7 - i)] = (byte)(v >> (8 * i)); }
    }
    public static ushort ReadU16BE(byte[] b, int o) {
        return (ushort)((b[o] << 8) | b[o + 1]);
    }
    public static uint ReadU32BE(byte[] b, int o) {
        return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3];
    }
    public static ulong ReadU64BE(byte[] b, int o) {
        ulong v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | b[o + i];
        return v;
    }

    public static string HexHeader(byte[] frame) {
        int n = Math.Min(HeaderSize, frame.Length);
        var chars = new char[n * 3];
        for (int i = 0; i < n; i++) {
            string h = frame[i].ToString("X2");
            chars[i * 3] = h[0]; chars[i * 3 + 1] = h[1]; chars[i * 3 + 2] = ' ';
        }
        return new string(chars).Trim();
    }
}
