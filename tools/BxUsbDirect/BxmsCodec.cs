using System;

/// BX Media Source local ingest framing (PC adapter interface for OBS / other apps).
/// NOT claimed as VCamTang's private localhost wire format (that local framing is unproven).
/// After ingest, Relay re-packs to proven VCU1 for usbmux → phone.
public static class BxmsCodec {
    public const int HeaderSize = 20;
    public const byte Version = 1;

    // Adapter-level message kinds (our interface). Mapped to VCU1 type via ports.ini / TypeMap.
    public const byte MsgVideoConfig = 1;
    public const byte MsgAudioConfig = 2;
    public const byte MsgVideo = 3;
    public const byte MsgAudio = 4;

    public struct Message {
        public byte MsgType;
        public ushort Flags;
        public ulong PtsUs;
        public byte[] Payload;
    }

    public static byte[] Encode(Message m) {
        if (m.Payload == null) m.Payload = Array.Empty<byte>();
        byte[] buf = new byte[HeaderSize + m.Payload.Length];
        buf[0] = (byte)'B'; buf[1] = (byte)'X'; buf[2] = (byte)'M'; buf[3] = (byte)'S';
        buf[4] = Version;
        buf[5] = m.MsgType;
        Vcu1Codec.WriteU16BE(buf, 6, m.Flags);
        Vcu1Codec.WriteU64BE(buf, 8, m.PtsUs);
        Vcu1Codec.WriteU32BE(buf, 16, (uint)m.Payload.Length);
        Buffer.BlockCopy(m.Payload, 0, buf, HeaderSize, m.Payload.Length);
        return buf;
    }

    public static bool TryDecode(byte[] buf, int offset, int length, out Message m, out string err) {
        m = default(Message);
        err = null;
        if (length < HeaderSize) { err = "short BXMS header"; return false; }
        if (buf[offset] != (byte)'B' || buf[offset + 1] != (byte)'X' ||
            buf[offset + 2] != (byte)'M' || buf[offset + 3] != (byte)'S') {
            err = "bad BXMS magic";
            return false;
        }
        if (buf[offset + 4] != Version) { err = "bad BXMS version"; return false; }
        byte mt = buf[offset + 5];
        ushort flags = Vcu1Codec.ReadU16BE(buf, offset + 6);
        ulong pts = Vcu1Codec.ReadU64BE(buf, offset + 8);
        uint plen = Vcu1Codec.ReadU32BE(buf, offset + 16);
        if (plen > Vcu1Codec.MaxPayload) { err = "BXMS payload too large"; return false; }
        if (length < HeaderSize + (int)plen) { err = "short BXMS payload"; return false; }
        byte[] payload = new byte[plen];
        Buffer.BlockCopy(buf, offset + HeaderSize, payload, 0, (int)plen);
        m = new Message { MsgType = mt, Flags = flags, PtsUs = pts, Payload = payload };
        return true;
    }
}
