using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

/// PC USB direct relay (align VCamTang Relay role):
/// BXMS ingest (OBS plugin / other software) → VCU1 → usbmux Connect(device_port).
/// LAN/RTSP keeps using tools/BxUsbBridge.cs — not removed.
public static class BxUsbDirectRelay {
    static TypeMap typeMap = new TypeMap();
    static int devicePort = 28765;
    static IPAddress ingestAddr = IPAddress.Loopback;
    static int ingestPort = 18765;
    static uint videoSeq;
    static uint audioSeq;
    static readonly object phoneGate = new object();
    static TcpClient phone;
    static NetworkStream phoneStream;
    static bool loopbackPhone;
    static int loopbackPhonePort = 28765;
    static long pushOk;
    static long pushDrop;
    static DateTime lastUsbLog = DateTime.MinValue;
    static string lastUsbErr = "";

    public static int Main(string[] args) {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        if (args.Length > 0 && args[0] == "selftest") return SelfTest.Run(baseDir, args);

        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--loopback-phone") loopbackPhone = true;
            if (args[i] == "--loopback-port" && i + 1 < args.Length) int.TryParse(args[++i], out loopbackPhonePort);
        }

        LoadPorts(Path.Combine(baseDir, "ports.ini"));
        typeMap = TypeMap.Load(Path.Combine(baseDir, "vcu1-types.ini"));

        Console.WriteLine("BXFloat USB Direct Relay");
        Console.WriteLine("  device_port=" + devicePort + (loopbackPhone ? " (LOOPBACK " + loopbackPhonePort + ")" : ""));
        Console.WriteLine("  BXMS ingest=" + ingestAddr + ":" + ingestPort);
        Console.WriteLine("  顺序: 1)本窗口常开  2)手机注dylib+替换开  3)再开「一键推Demo」");
        Console.WriteLine("  手机未就绪时只丢帧，不断开电脑端 Demo 连接");

        Thread phoneKeeper = new Thread(PhoneKeepAlive);
        phoneKeeper.IsBackground = true;
        phoneKeeper.Start();

        TcpListener listener = new TcpListener(ingestAddr, ingestPort);
        listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        listener.Start();
        Console.WriteLine("[ingest] listen OK " + ingestAddr + ":" + ingestPort);
        while (true) {
            TcpClient c = listener.AcceptTcpClient();
            c.NoDelay = true;
            Thread t = new Thread(() => ServeIngest(c));
            t.IsBackground = true;
            t.Start();
        }
    }

    static void LoadPorts(string path) {
        if (!File.Exists(path)) return;
        string section = "";
        foreach (string raw in File.ReadAllLines(path)) {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            if (line.StartsWith("[") && line.EndsWith("]")) {
                section = line.Substring(1, line.Length - 2).ToLowerInvariant();
                continue;
            }
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string k = line.Substring(0, eq).Trim().ToLowerInvariant();
            string v = line.Substring(eq + 1).Trim();
            int n;
            IPAddress a;
            if (section == "ports" && k == "douyin" && int.TryParse(v, out n)) devicePort = n;
            if (section == "ingest" && k == "port" && int.TryParse(v, out n)) ingestPort = n;
            if (section == "ingest" && k == "listen" && IPAddress.TryParse(v, out a)) ingestAddr = a;
        }
    }

    static void PhoneKeepAlive() {
        while (true) {
            try {
                EnsurePhone();
                Thread.Sleep(2000);
            } catch (Exception ex) {
                Console.WriteLine("[usb] " + ex.Message);
                DropPhone();
                Thread.Sleep(1500);
            }
        }
    }

    static void EnsurePhone() {
        // Same connect path as PushToPhone — must honor --loopback-phone,
        // otherwise KeepAlive usbmux failures DropPhone and kill live loopback/USB sockets.
        lock (phoneGate) {
            EnsurePhoneUnlocked();
        }
    }

    static void DropPhone() {
        lock (phoneGate) {
            SoftDropPhoneUnlocked();
        }
    }

    static void ServeIngest(TcpClient client) {
        string peer = "?";
        try { peer = client.Client.RemoteEndPoint.ToString(); } catch { }
        Console.WriteLine("[ingest] + " + peer);
        NetworkStream s = client.GetStream();
        byte[] hdr = new byte[BxmsCodec.HeaderSize];
        try {
            while (true) {
                Usbmux.ReadExact(s, hdr, BxmsCodec.HeaderSize);
                uint plen = Vcu1Codec.ReadU32BE(hdr, 16);
                if (plen > Vcu1Codec.MaxPayload) throw new IOException("payload too large");
                byte[] whole = new byte[BxmsCodec.HeaderSize + (int)plen];
                Buffer.BlockCopy(hdr, 0, whole, 0, BxmsCodec.HeaderSize);
                if (plen > 0) {
                    byte[] body = new byte[plen];
                    Usbmux.ReadExact(s, body, (int)plen);
                    Buffer.BlockCopy(body, 0, whole, BxmsCodec.HeaderSize, (int)plen);
                }
                BxmsCodec.Message msg;
                string err;
                if (!BxmsCodec.TryDecode(whole, 0, whole.Length, out msg, out err))
                    throw new IOException(err);

                bool isAudio = msg.MsgType == BxmsCodec.MsgAudio || msg.MsgType == BxmsCodec.MsgAudioConfig;
                uint seq;
                lock (phoneGate) {
                    if (isAudio) seq = ++audioSeq; else seq = ++videoSeq;
                }
                ushort flags = msg.Flags != 0 ? msg.Flags : typeMap.DefaultFlags;
                var pkt = new Vcu1Codec.Packet {
                    Type = typeMap.MapMsg(msg.MsgType),
                    Flags = flags,
                    Sequence = seq,
                    PtsUs = msg.PtsUs,
                    Payload = msg.Payload
                };
                byte[] wire = Vcu1Codec.Encode(pkt);
                // 手机断线/未听端口：只丢帧，绝不把异常抛回 ingest（否则 Demo 被掐死）
                PushToPhoneSoft(wire);
                MaybeLogUsb(pkt);
            }
        } catch (Exception ex) {
            Console.WriteLine("[ingest] - " + peer + " " + ex.Message);
        } finally {
            try { client.Close(); } catch { }
        }
    }

    static void MaybeLogUsb(Vcu1Codec.Packet pkt) {
        DateTime now = DateTime.UtcNow;
        if ((now - lastUsbLog).TotalSeconds < 2.0) return;
        lastUsbLog = now;
        Console.WriteLine("[usb] ok=" + pushOk + " drop=" + pushDrop +
            " lastType=" + pkt.Type + " seq=" + pkt.Sequence + " len=" + pkt.Payload.Length +
            (lastUsbErr.Length > 0 ? (" err=" + lastUsbErr) : ""));
    }

    static void PushToPhoneSoft(byte[] wire) {
        lock (phoneGate) {
            if (TryWritePhoneUnlocked(wire)) {
                pushOk++;
                lastUsbErr = "";
                return;
            }
            // 清掉坏连接，再试一次；仍失败则丢帧，保持 Demo TCP 活着
            SoftDropPhoneUnlocked();
            if (TryWritePhoneUnlocked(wire)) {
                pushOk++;
                lastUsbErr = "";
                return;
            }
            pushDrop++;
        }
    }

    static bool TryWritePhoneUnlocked(byte[] wire) {
        try {
            EnsurePhoneUnlocked();
            phoneStream.Write(wire, 0, wire.Length);
            phoneStream.Flush();
            return true;
        } catch (Exception ex) {
            lastUsbErr = ex.Message;
            SoftDropPhoneUnlocked();
            return false;
        }
    }

    static void SoftDropPhoneUnlocked() {
        try { if (phoneStream != null) phoneStream.Close(); } catch { }
        try { if (phone != null) phone.Close(); } catch { }
        phoneStream = null;
        phone = null;
    }

    static void PushToPhone(byte[] wire) {
        PushToPhoneSoft(wire);
    }

    static void EnsurePhoneUnlocked() {
        if (phone != null && phone.Connected && phoneStream != null) return;
        if (loopbackPhone) {
            phone = new TcpClient();
            phone.NoDelay = true;
            phone.Connect(IPAddress.Loopback, loopbackPhonePort);
            phoneStream = phone.GetStream();
            Console.WriteLine("[usb] loopback phone 127.0.0.1:" + loopbackPhonePort);
            return;
        }
        int? id = Usbmux.ListDeviceId();
        if (id == null) throw new Exception("no iPhone on usbmux");
        phone = Usbmux.ConnectDevicePort(id.Value, devicePort);
        phoneStream = phone.GetStream();
        Console.WriteLine("[usb] connected DeviceID=" + id.Value + " port=" + devicePort);
    }
}
