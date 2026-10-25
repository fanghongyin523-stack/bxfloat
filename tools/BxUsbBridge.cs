using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class BxUsbBridge {
    const string UsbmuxHost = "127.0.0.1";
    const int UsbmuxPort = 27015;
    const int TunnelPort = 19888;
    const int MediaPort = 18888;
    const int Workers = 8;

    public static void Run() {
        Console.WriteLine("等待手机 usbmux...");
        while (true) {
            try {
                int? deviceId = ListDeviceId();
                if (deviceId == null) {
                    Console.WriteLine("未检测到 iPhone（检查线 / 信任 / Apple 驱动）");
                    Thread.Sleep(2000);
                    continue;
                }
                Console.WriteLine("设备 DeviceID=" + deviceId + "，启动 " + Workers + " 路桥接");
                Thread[] threads = new Thread[Workers];
                for (int i = 0; i < Workers; i++) {
                    int wid = i + 1;
                    int did = deviceId.Value;
                    threads[i] = new Thread(() => WorkerLoop(did, wid));
                    threads[i].IsBackground = true;
                    threads[i].Start();
                }
                foreach (var t in threads) t.Join();
            } catch (Exception ex) {
                Console.WriteLine("错误: " + ex.Message);
                Thread.Sleep(2000);
            }
        }
    }

    static void WorkerLoop(int deviceId, int wid) {
        while (true) {
            try {
                OneBridge(deviceId, wid);
            } catch {
            }
            Thread.Sleep(400);
        }
    }

    static void OneBridge(int deviceId, int wid) {
        TcpClient phone = null;
        TcpClient media = null;
        try {
            phone = ConnectTunnel(deviceId, TunnelPort);
            media = new TcpClient();
            media.NoDelay = true;
            media.Connect("127.0.0.1", MediaPort);
            Console.WriteLine("[W" + wid + "] 桥接已建立");
            NetworkStream a = phone.GetStream();
            NetworkStream b = media.GetStream();
            Thread t1 = new Thread(() => CopyStream(a, b));
            Thread t2 = new Thread(() => CopyStream(b, a));
            t1.IsBackground = true;
            t2.IsBackground = true;
            t1.Start();
            t2.Start();
            t1.Join();
            try { phone.Close(); } catch {}
            try { media.Close(); } catch {}
            t2.Join(500);
        } finally {
            try { if (phone != null) phone.Close(); } catch {}
            try { if (media != null) media.Close(); } catch {}
        }
    }

    static void CopyStream(NetworkStream src, NetworkStream dst) {
        byte[] buf = new byte[65536];
        try {
            while (true) {
                int n = src.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                dst.Write(buf, 0, n);
                dst.Flush();
            }
        } catch {}
        try { src.Close(); } catch {}
        try { dst.Close(); } catch {}
    }

    static int? ListDeviceId() {
        using (TcpClient client = new TcpClient()) {
            client.ReceiveTimeout = 5000;
            client.SendTimeout = 5000;
            client.Connect(UsbmuxHost, UsbmuxPort);
            NetworkStream stream = client.GetStream();
            string plist =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
                "<plist version=\"1.0\"><dict>" +
                "<key>MessageType</key><string>ListDevices</string>" +
                "<key>ClientVersionString</key><string>BXFloatUSB</string>" +
                "<key>ProgName</key><string>BXFloatUSB</string>" +
                "</dict></plist>";
            SendPlist(stream, 1, plist);
            string text = ReadPlist(stream);
            Match m = Regex.Match(text, @"<key>DeviceID</key>\s*<integer>(\d+)</integer>");
            if (!m.Success) return null;
            return int.Parse(m.Groups[1].Value);
        }
    }

    static TcpClient ConnectTunnel(int deviceId, int port) {
        TcpClient client = new TcpClient();
        client.NoDelay = true;
        client.Connect(UsbmuxHost, UsbmuxPort);
        NetworkStream stream = client.GetStream();
        int netPort = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);
        string plist =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            "<key>DeviceID</key><integer>" + deviceId + "</integer>" +
            "<key>PortNumber</key><integer>" + netPort + "</integer>" +
            "<key>ClientVersionString</key><string>BXFloatUSB</string>" +
            "<key>ProgName</key><string>BXFloatUSB</string>" +
            "</dict></plist>";
        SendPlist(stream, 2, plist);
        string text = ReadPlist(stream);
        if (!Regex.IsMatch(text, @"<key>Number</key>\s*<integer>0</integer>")) {
            client.Close();
            throw new Exception("连手机端口失败，请先打开手机数据线悬浮窗");
        }
        return client;
    }

    static void SendPlist(NetworkStream stream, uint tag, string plist) {
        byte[] body = Encoding.UTF8.GetBytes(plist);
        byte[] hdr = new byte[16];
        BitConverter.GetBytes((uint)(16 + body.Length)).CopyTo(hdr, 0);
        BitConverter.GetBytes((uint)1).CopyTo(hdr, 4);
        BitConverter.GetBytes((uint)8).CopyTo(hdr, 8);
        BitConverter.GetBytes(tag).CopyTo(hdr, 12);
        stream.Write(hdr, 0, 16);
        stream.Write(body, 0, body.Length);
        stream.Flush();
    }

    static string ReadPlist(NetworkStream stream) {
        byte[] hdr = new byte[16];
        ReadExact(stream, hdr, 16);
        int len = BitConverter.ToInt32(hdr, 0);
        int payloadLen = len - 16;
        byte[] payload = new byte[payloadLen];
        ReadExact(stream, payload, payloadLen);
        return Encoding.UTF8.GetString(payload);
    }

    static void ReadExact(NetworkStream stream, byte[] buf, int size) {
        int read = 0;
        while (read < size) {
            int n = stream.Read(buf, read, size - read);
            if (n <= 0) throw new IOException("usbmux closed");
            read += n;
        }
    }
}
