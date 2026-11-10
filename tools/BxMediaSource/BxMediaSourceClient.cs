using System;
using System.Net.Sockets;

/// Interface for OBS shim / other software to push encoded A/V into BxUsbDirectRelay (BXMS).
/// Dual-channel product note:
///   - USB direct: send BXMS here → Relay → VCU1 → phone
///   - LAN: push RTSP/HLS to MediaMTX and use BxUsbBridge (existing)
public sealed class BxMediaSourceClient : IDisposable {
    readonly TcpClient client;
    readonly NetworkStream stream;

    public BxMediaSourceClient(string host = "127.0.0.1", int port = 18765) {
        client = new TcpClient();
        client.NoDelay = true;
        client.Connect(host, port);
        stream = client.GetStream();
    }

    public void SendVideoConfig(byte[] avcExtraOrConfig, ulong ptsUs = 0, ushort flags = 0) {
        Send(BxmsCodec.MsgVideoConfig, flags, ptsUs, avcExtraOrConfig);
    }
    public void SendAudioConfig(byte[] ascOrConfig, ulong ptsUs = 0, ushort flags = 0) {
        Send(BxmsCodec.MsgAudioConfig, flags, ptsUs, ascOrConfig);
    }
    public void SendVideo(byte[] annexOrAvcc, ulong ptsUs, ushort flags = 0) {
        Send(BxmsCodec.MsgVideo, flags, ptsUs, annexOrAvcc);
    }
    public void SendAudio(byte[] aacFrame, ulong ptsUs, ushort flags = 0) {
        Send(BxmsCodec.MsgAudio, flags, ptsUs, aacFrame);
    }

    void Send(byte msgType, ushort flags, ulong ptsUs, byte[] payload) {
        var m = new BxmsCodec.Message {
            MsgType = msgType,
            Flags = flags,
            PtsUs = ptsUs,
            Payload = payload ?? Array.Empty<byte>()
        };
        byte[] frame = BxmsCodec.Encode(m);
        stream.Write(frame, 0, frame.Length);
        stream.Flush();
    }

    public void Dispose() {
        try { stream.Close(); } catch { }
        try { client.Close(); } catch { }
    }
}
