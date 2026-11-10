using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

/// usbmuxd TCP client — same approach as existing BxUsbBridge / VCamTang Relay (ListDevices + Connect).
public static class Usbmux {
    public const string Host = "127.0.0.1";
    public const int Port = 27015;

    public static int? ListDeviceId() {
        using (TcpClient client = new TcpClient()) {
            client.ReceiveTimeout = 5000;
            client.SendTimeout = 5000;
            client.Connect(Host, Port);
            NetworkStream stream = client.GetStream();
            string plist =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
                "<plist version=\"1.0\"><dict>" +
                "<key>MessageType</key><string>ListDevices</string>" +
                "<key>ClientVersionString</key><string>vcamtang-direct-multi-1.0</string>" +
                "<key>ProgName</key><string>BXFloat Direct Relay</string>" +
                "<key>kLibUSBMuxVersion</key><integer>3</integer>" +
                "</dict></plist>";
            SendPlist(stream, 1, plist);
            string text = ReadPlist(stream);
            Match m = Regex.Match(text, "<key>DeviceID</key>\\s*<integer>(\\d+)</integer>");
            if (!m.Success) return null;
            return int.Parse(m.Groups[1].Value);
        }
    }

    public static TcpClient ConnectDevicePort(int deviceId, int devicePort) {
        TcpClient client = new TcpClient();
        client.NoDelay = true;
        client.Connect(Host, Port);
        NetworkStream stream = client.GetStream();
        // PortNumber is big-endian u16 in usbmux plist integer (same as BxUsbBridge)
        int netPort = ((devicePort & 0xFF) << 8) | ((devicePort >> 8) & 0xFF);
        string plist =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            "<key>DeviceID</key><integer>" + deviceId + "</integer>" +
            "<key>PortNumber</key><integer>" + netPort + "</integer>" +
            "<key>ClientVersionString</key><string>vcamtang-direct-multi-1.0</string>" +
            "<key>ProgName</key><string>BXFloat Direct Relay</string>" +
            "<key>kLibUSBMuxVersion</key><integer>3</integer>" +
            "</dict></plist>";
        SendPlist(stream, 2, plist);
        string text = ReadPlist(stream);
        if (!Regex.IsMatch(text, "<key>Number</key>\\s*<integer>0</integer>")) {
            client.Close();
            throw new Exception("usbmux Connect to device_port=" + devicePort + " failed");
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
        if (payloadLen < 0 || payloadLen > 8 * 1024 * 1024) throw new IOException("bad usbmux length");
        byte[] payload = new byte[payloadLen];
        ReadExact(stream, payload, payloadLen);
        return Encoding.UTF8.GetString(payload);
    }

    public static void ReadExact(NetworkStream stream, byte[] buf, int size) {
        int read = 0;
        while (read < size) {
            int n = stream.Read(buf, read, size - read);
            if (n <= 0) throw new IOException("usbmux/socket closed");
            read += n;
        }
    }
}
