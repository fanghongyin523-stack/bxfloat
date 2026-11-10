using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

/// Demo "other software" → BXMS ingest (127.0.0.1:18765).
/// Payload: real annex-B H.264 (SPS/PPS/IDR) + ADTS AAC (+ ASC). Framing/port unchanged.
public static class ProgramDemo {
    public static int Main(string[] args) {
        string host = args.Length > 0 ? args[0] : "127.0.0.1";
        int port = args.Length > 1 ? int.Parse(args[1]) : 18765;
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string h264Path = Path.Combine(baseDir, "demo-sample.annexb.h264");
        string aacPath = Path.Combine(baseDir, "demo-sample.adts.aac");
        Console.WriteLine("BxMediaSource demo → " + host + ":" + port);
        Console.WriteLine("  h264=" + h264Path);
        Console.WriteLine("  aac =" + aacPath);
        try {
            if (!File.Exists(h264Path)) throw new FileNotFoundException("missing H.264 sample", h264Path);
            if (!File.Exists(aacPath)) throw new FileNotFoundException("missing AAC sample", aacPath);

            byte[] h264 = File.ReadAllBytes(h264Path);
            byte[] aacFile = File.ReadAllBytes(aacPath);
            List<byte[]> videoAus = SplitAnnexBAccessUnits(h264);
            if (videoAus.Count == 0) throw new InvalidOperationException("no H.264 access units");
            byte[] spsPps = ExtractSpsPps(h264);
            if (spsPps == null || spsPps.Length == 0)
                throw new InvalidOperationException("H.264 sample missing SPS/PPS");

            List<byte[]> aacFrames = SplitAdtsFrames(aacFile);
            if (aacFrames.Count == 0) throw new InvalidOperationException("no ADTS AAC frames");
            // AAC-LC 44.1kHz stereo ASC (matches ffmpeg sample); also recoverable from ADTS.
            byte[] asc = new byte[] { 0x12, 0x10 };

            using (var c = new BxMediaSourceClient(host, port)) {
                c.SendVideoConfig(spsPps, 0);
                Thread.Sleep(20);
                for (int i = 0; i < videoAus.Count; i++) {
                    c.SendVideo(videoAus[i], (ulong)(i * 100000)); // 10fps → 100ms
                    Thread.Sleep(20);
                }
                c.SendAudioConfig(asc, 0);
                Thread.Sleep(10);
                for (int i = 0; i < aacFrames.Count; i++) {
                    // 1024 samples @ 44.1k ≈ 23220 µs
                    c.SendAudio(aacFrames[i], (ulong)(i * 23220));
                    Thread.Sleep(5);
                }
            }
            Console.WriteLine("demo send OK videoAU=" + videoAus.Count + " aacFrames=" + aacFrames.Count +
                " spsPps=" + spsPps.Length);
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("demo failed: " + ex.Message);
            return 1;
        }
    }

    /// Group annex-B into access units: non-VCL + following VCL (type 1/5).
    static List<byte[]> SplitAnnexBAccessUnits(byte[] data) {
        var nals = new List<Tuple<int, int, int>>(); // start, len, nalType
        int i = 0;
        while (i + 3 < data.Length) {
            int sc = 0;
            if (i + 3 < data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
                sc = 4;
            else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
                sc = 3;
            if (sc == 0) { i++; continue; }
            int nalStart = i;
            int payload = i + sc;
            int j = payload;
            while (j + 3 < data.Length) {
                if (data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 0 && data[j + 3] == 1) break;
                if (data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 1) break;
                j++;
            }
            if (j + 3 >= data.Length) j = data.Length;
            int nalType = data[payload] & 0x1F;
            nals.Add(Tuple.Create(nalStart, j - nalStart, nalType));
            i = j;
        }

        var aus = new List<byte[]>();
        var buf = new List<byte>();
        Action flush = () => {
            if (buf.Count == 0) return;
            aus.Add(buf.ToArray());
            buf.Clear();
        };
        foreach (var n in nals) {
            bool vcl = n.Item3 == 1 || n.Item3 == 5;
            for (int k = 0; k < n.Item2; k++) buf.Add(data[n.Item1 + k]);
            if (vcl) flush();
        }
        flush();
        return aus;
    }

    static byte[] ExtractSpsPps(byte[] data) {
        var buf = new List<byte>();
        int i = 0;
        while (i + 3 < data.Length) {
            int sc = 0;
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) sc = 4;
            else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) sc = 3;
            if (sc == 0) { i++; continue; }
            int payload = i + sc;
            int j = payload;
            while (j + 3 < data.Length) {
                if (data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 0 && data[j + 3] == 1) break;
                if (data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 1) break;
                j++;
            }
            if (j + 3 >= data.Length) j = data.Length;
            int nalType = data[payload] & 0x1F;
            if (nalType == 7 || nalType == 8) {
                for (int k = i; k < j; k++) buf.Add(data[k]);
            }
            if (nalType == 7 || nalType == 8) { /* keep scanning first set */ }
            if (buf.Count > 0 && nalType != 7 && nalType != 8 && nalType != 6 && nalType != 9)
                break;
            i = j;
        }
        return buf.ToArray();
    }

    static List<byte[]> SplitAdtsFrames(byte[] data) {
        var frames = new List<byte[]>();
        int i = 0;
        while (i + 7 <= data.Length) {
            if (data[i] != 0xFF || (data[i + 1] & 0xF0) != 0xF0) { i++; continue; }
            int frameLen = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | ((data[i + 5] & 0xE0) >> 5);
            if (frameLen < 7 || i + frameLen > data.Length) break;
            byte[] one = new byte[frameLen];
            Buffer.BlockCopy(data, i, one, 0, frameLen);
            frames.Add(one);
            i += frameLen;
        }
        return frames;
    }
}
