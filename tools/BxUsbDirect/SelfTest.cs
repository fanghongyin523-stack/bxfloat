using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

/// Offline / local self-test (no phone required for codec+ingest path).
public static class SelfTest {
    public static int Run(string baseDir, string[] args) {
        Console.WriteLine("=== BxUsbDirect selftest ===");
        int fail = 0;
        fail += TestCodecRoundtrip();
        fail += TestHeaderLayoutMatchesProven();
        fail += TestFakePhoneAndIngest(baseDir);
        fail += TestIngestToLoopbackRelay(baseDir);
        Console.WriteLine("[note] live usbmux→real phone NOT run in selftest (needs device + phone listen)");
        Console.WriteLine("[note] OBS GUI plugin binary needs OBS SDK build; interface = BxMediaSourceClient; LAN = BxUsbBridge");
        Console.WriteLine(fail == 0 ? "SELFTEST PASS" : ("SELFTEST FAIL count=" + fail));
        return fail == 0 ? 0 : 1;
    }

    static int TestCodecRoundtrip() {
        var p = new Vcu1Codec.Packet {
            Type = 3,
            Flags = 0x1234,
            Sequence = 7,
            PtsUs = 123456789UL,
            Payload = new byte[] { 0x00, 0x00, 0x00, 0x01, 0x67 }
        };
        byte[] wire = Vcu1Codec.Encode(p);
        Vcu1Codec.Packet q;
        string err;
        if (!Vcu1Codec.TryDecode(wire, 0, wire.Length, out q, out err)) {
            Console.WriteLine("[fail] decode: " + err);
            return 1;
        }
        if (q.Type != 3 || q.Flags != 0x1234 || q.Sequence != 7 || q.PtsUs != 123456789UL ||
            q.Payload.Length != 5 || q.Payload[4] != 0x67) {
            Console.WriteLine("[fail] roundtrip mismatch");
            return 1;
        }
        Console.WriteLine("[ok] VCU1 codec roundtrip hdr=" + Vcu1Codec.HexHeader(wire));
        return 0;
    }

    static int TestHeaderLayoutMatchesProven() {
        var p = new Vcu1Codec.Packet { Type = 3, Flags = 0x0001, Sequence = 0x01020304, PtsUs = 0x0807060504030201UL, Payload = new byte[] { 0xAA } };
        byte[] w = Vcu1Codec.Encode(p);
        if (w.Length != 25) { Console.WriteLine("[fail] size"); return 1; }
        if (w[0] != (byte)'V' || w[1] != (byte)'C' || w[2] != (byte)'U' || w[3] != (byte)'1') {
            Console.WriteLine("[fail] magic"); return 1;
        }
        if (w[4] != 1) { Console.WriteLine("[fail] version"); return 1; }
        if (w[5] != 3) { Console.WriteLine("[fail] type offset"); return 1; }
        if (w[6] != 0x00 || w[7] != 0x01) { Console.WriteLine("[fail] flags BE"); return 1; }
        if (w[8] != 0 || w[9] != 0 || w[10] != 0 || w[11] != 1) { Console.WriteLine("[fail] len BE"); return 1; }
        if (w[12] != 1 || w[13] != 2 || w[14] != 3 || w[15] != 4) { Console.WriteLine("[fail] seq BE"); return 1; }
        // pts BE 08 07 06 05 04 03 02 01
        if (w[16] != 8 || w[23] != 1) { Console.WriteLine("[fail] pts BE"); return 1; }
        Console.WriteLine("[ok] header layout matches proven 24B map");
        return 0;
    }

    static int TestFakePhoneAndIngest(string baseDir) {
        // Fake phone listens on a local TCP port; we point a mini push at it without usbmux.
        int fakePort = 28765;
        var listener = new TcpListener(IPAddress.Loopback, fakePort);
        try {
            listener.Start();
        } catch {
            fakePort = 28766;
            listener = new TcpListener(IPAddress.Loopback, fakePort);
            listener.Start();
        }
        byte[] received = null;
        var done = new ManualResetEvent(false);
        Thread acc = new Thread(() => {
            try {
                using (TcpClient phone = listener.AcceptTcpClient())
                using (NetworkStream ps = phone.GetStream()) {
                    byte[] hdr = new byte[Vcu1Codec.HeaderSize];
                    Usbmux.ReadExact(ps, hdr, Vcu1Codec.HeaderSize);
                    uint plen = Vcu1Codec.ReadU32BE(hdr, 8);
                    received = new byte[Vcu1Codec.HeaderSize + (int)plen];
                    Buffer.BlockCopy(hdr, 0, received, 0, Vcu1Codec.HeaderSize);
                    if (plen > 0) {
                        byte[] body = new byte[plen];
                        Usbmux.ReadExact(ps, body, (int)plen);
                        Buffer.BlockCopy(body, 0, received, Vcu1Codec.HeaderSize, (int)plen);
                    }
                    done.Set();
                }
            } catch (Exception ex) {
                Console.WriteLine("[fail] fake phone: " + ex.Message);
                done.Set();
            }
        });
        acc.IsBackground = true;
        acc.Start();

        // Direct VCU1 write to fake phone (simulates post-usbmux stream)
        Thread.Sleep(100);
        using (TcpClient c = new TcpClient()) {
            c.Connect(IPAddress.Loopback, fakePort);
            var pkt = new Vcu1Codec.Packet {
                Type = Vcu1Codec.TypeProvenPayloadEnqueue,
                Flags = 0,
                Sequence = 1,
                PtsUs = 1000,
                Payload = new byte[] { 0x00, 0x00, 0x00, 0x01, 0x65 }
            };
            byte[] wire = Vcu1Codec.Encode(pkt);
            c.GetStream().Write(wire, 0, wire.Length);
        }

        if (!done.WaitOne(3000) || received == null) {
            Console.WriteLine("[fail] fake phone did not receive");
            listener.Stop();
            return 1;
        }
        Vcu1Codec.Packet got;
        string err;
        if (!Vcu1Codec.TryDecode(received, 0, received.Length, out got, out err)) {
            Console.WriteLine("[fail] fake phone decode " + err);
            listener.Stop();
            return 1;
        }
        if (got.Type != 3 || got.Payload.Length != 5) {
            Console.WriteLine("[fail] fake phone content");
            listener.Stop();
            return 1;
        }
        Console.WriteLine("[ok] fake-phone VCU1 recv type=3 len=5");

        // BXMS encode/decode
        var msg = new BxmsCodec.Message {
            MsgType = BxmsCodec.MsgVideo,
            Flags = 0,
            PtsUs = 42,
            Payload = new byte[] { 1, 2, 3 }
        };
        byte[] bx = BxmsCodec.Encode(msg);
        BxmsCodec.Message msg2;
        if (!BxmsCodec.TryDecode(bx, 0, bx.Length, out msg2, out err) || msg2.Payload.Length != 3) {
            Console.WriteLine("[fail] BXMS " + err);
            listener.Stop();
            return 1;
        }
        Console.WriteLine("[ok] BXMS adapter framing");

        // Map types
        TypeMap map = TypeMap.Load(Path.Combine(baseDir, "vcu1-types.ini"));
        if (map.MapMsg(BxmsCodec.MsgVideo) != 3) {
            Console.WriteLine("[fail] type map default");
            listener.Stop();
            return 1;
        }
        Console.WriteLine("[ok] type map video→" + map.MapMsg(BxmsCodec.MsgVideo) + " (proven enqueue type)");

        listener.Stop();
        return 0;
    }

    static int TestIngestToLoopbackRelay(string baseDir) {
        // End-to-end: Demo client → Relay(--loopback-phone) → fake phone TCP
        string exe = Path.Combine(baseDir, "BxUsbDirectRelay.exe");
        if (!File.Exists(exe)) exe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "BxUsbDirectRelay.exe");
        if (!File.Exists(exe)) {
            Console.WriteLine("[skip] relay exe missing for ingest E2E");
            return 0;
        }

        int phonePort = 29001;
        int ingestPort = 19001;
        byte[] got = null;
        var gotEv = new ManualResetEvent(false);
        var phoneL = new TcpListener(IPAddress.Loopback, phonePort);
        phoneL.Start();
        Thread phoneT = new Thread(() => {
            try {
                using (var c = phoneL.AcceptTcpClient())
                using (var s = c.GetStream()) {
                    byte[] hdr = new byte[Vcu1Codec.HeaderSize];
                    Usbmux.ReadExact(s, hdr, Vcu1Codec.HeaderSize);
                    uint plen = Vcu1Codec.ReadU32BE(hdr, 8);
                    got = new byte[Vcu1Codec.HeaderSize + (int)plen];
                    Buffer.BlockCopy(hdr, 0, got, 0, Vcu1Codec.HeaderSize);
                    if (plen > 0) {
                        byte[] body = new byte[plen];
                        Usbmux.ReadExact(s, body, (int)plen);
                        Buffer.BlockCopy(body, 0, got, Vcu1Codec.HeaderSize, (int)plen);
                    }
                    gotEv.Set();
                }
            } catch (Exception ex) {
                Console.WriteLine("[fail] e2e phone " + ex.Message);
                gotEv.Set();
            }
        });
        phoneT.IsBackground = true;
        phoneT.Start();

        // Write temp ports.ini for ingest port
        string tmp = Path.Combine(Path.GetTempPath(), "bxusb-selftest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmp);
        File.WriteAllText(Path.Combine(tmp, "ports.ini"),
            "[ports]\ndouyin=28765\n[ingest]\nlisten=127.0.0.1\nport=" + ingestPort + "\n");
        File.Copy(Path.Combine(baseDir, "vcu1-types.ini"), Path.Combine(tmp, "vcu1-types.ini"), true);
        File.Copy(exe, Path.Combine(tmp, "BxUsbDirectRelay.exe"), true);

        var psi = new System.Diagnostics.ProcessStartInfo {
            FileName = Path.Combine(tmp, "BxUsbDirectRelay.exe"),
            Arguments = "--loopback-phone --loopback-port " + phonePort,
            WorkingDirectory = tmp,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        var proc = System.Diagnostics.Process.Start(psi);
        try {
            Thread.Sleep(800);
            // inline BXMS send (avoid depending on separate client assembly in selftest)
            using (var tc = new TcpClient()) {
                tc.Connect(IPAddress.Loopback, ingestPort);
                var msg = new BxmsCodec.Message {
                    MsgType = BxmsCodec.MsgVideo,
                    Flags = 0,
                    PtsUs = 555,
                    Payload = new byte[] { 0x00, 0x00, 0x00, 0x01, 0x65, 0x99 }
                };
                byte[] frame = BxmsCodec.Encode(msg);
                tc.GetStream().Write(frame, 0, frame.Length);
            }
            if (!gotEv.WaitOne(4000) || got == null) {
                Console.WriteLine("[fail] E2E ingest→loopback phone timeout");
                return 1;
            }
            Vcu1Codec.Packet p;
            string err;
            if (!Vcu1Codec.TryDecode(got, 0, got.Length, out p, out err) || p.Type != 3 || p.Payload.Length != 6) {
                Console.WriteLine("[fail] E2E decode " + err);
                return 1;
            }
            Console.WriteLine("[ok] E2E BXMS→Relay→VCU1 loopback phone type=3 len=6");
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("[fail] E2E " + ex.Message);
            return 1;
        } finally {
            try { if (proc != null && !proc.HasExited) proc.Kill(); } catch { }
            try { phoneL.Stop(); } catch { }
            try { Directory.Delete(tmp, true); } catch { }
        }
    }
}
