using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Threading;

/// Demo "other software" → BXMS ingest (127.0.0.1:18765).
/// Payload: real annex-B H.264 (SPS/PPS/IDR) + ADTS AAC (+ ASC). Framing/port unchanged.
/// Default: loop A/V forever; auto-reconnect if Relay/phone blips.
public static class ProgramDemo {
    public static int Main(string[] args) {
        string host = "127.0.0.1";
        int port = 18765;
        // 0 = forever (Ctrl+C). Positive = stop after N seconds.
        int seconds = 0;
        for (int a = 0; a < args.Length; a++) {
            string s = args[a];
            if (s == "--seconds" && a + 1 < args.Length) {
                seconds = int.Parse(args[++a]);
                continue;
            }
            if (s.StartsWith("--seconds=")) {
                seconds = int.Parse(s.Substring("--seconds=".Length));
                continue;
            }
            if (!s.StartsWith("-") && host == "127.0.0.1" && a == 0) {
                host = s;
                continue;
            }
            if (!s.StartsWith("-") && a <= 1) {
                int p;
                if (int.TryParse(s, out p)) port = p;
            }
        }

        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string h264Path = Path.Combine(baseDir, "demo-sample.annexb.h264");
        string aacPath = Path.Combine(baseDir, "demo-sample.adts.aac");
        Console.WriteLine("BxMediaSource Demo（循环 + 断线自动重连）");
        Console.WriteLine("  目标 " + host + ":" + port);
        Console.WriteLine("  先开「USB直连助手」，手机替换开，再让本窗口一直跑");
        Console.WriteLine("  结束：Ctrl+C");
        try {
            if (!File.Exists(h264Path)) throw new FileNotFoundException("缺少 H.264 样片", h264Path);
            if (!File.Exists(aacPath)) throw new FileNotFoundException("缺少 AAC 样片", aacPath);

            byte[] h264 = File.ReadAllBytes(h264Path);
            byte[] aacFile = File.ReadAllBytes(aacPath);
            List<byte[]> videoAus = SplitAnnexBAccessUnits(h264);
            if (videoAus.Count == 0) throw new InvalidOperationException("no H.264 access units");
            byte[] spsPps = ExtractSpsPps(h264);
            if (spsPps == null || spsPps.Length == 0)
                throw new InvalidOperationException("H.264 sample missing SPS/PPS");

            List<byte[]> aacFrames = SplitAdtsFrames(aacFile);
            if (aacFrames.Count == 0) throw new InvalidOperationException("no ADTS AAC frames");
            byte[] asc = new byte[] { 0x12, 0x10 };

            const ulong videoStepUs = 100000; // 10fps
            const ulong audioStepUs = 23220;  // 1024 @ 44.1k
            Console.CancelKeyPress += (sender, e) => {
                e.Cancel = true;
                _stop = true;
            };

            var sw = Stopwatch.StartNew();
            int reconnects = 0;
            while (!_stop) {
                if (seconds > 0 && sw.Elapsed.TotalSeconds >= seconds) break;
                try {
                    using (var c = new BxMediaSourceClient(host, port)) {
                        Console.WriteLine("[demo] 已连上 Relay，开始推流" +
                            (reconnects > 0 ? (" (重连#" + reconnects + ")") : ""));
                        c.SendVideoConfig(spsPps, 0);
                        Thread.Sleep(20);
                        c.SendAudioConfig(asc, 0);
                        Thread.Sleep(10);

                        ulong vPts = 0;
                        ulong aPts = 0;
                        int vi = 0;
                        int ai = 0;
                        int cycles = 0;
                        long sentV = 0;
                        long sentA = 0;
                        var lastLog = sw.Elapsed;

                        while (!_stop) {
                            if (seconds > 0 && sw.Elapsed.TotalSeconds >= seconds) break;

                            if (aPts <= vPts) {
                                c.SendAudio(aacFrames[ai], aPts);
                                aPts += audioStepUs;
                                ai++;
                                if (ai >= aacFrames.Count) ai = 0;
                                sentA++;
                                Thread.Sleep(5);
                            } else {
                                if (vi == 0) {
                                    c.SendVideoConfig(spsPps, vPts);
                                    Thread.Sleep(5);
                                }
                                c.SendVideo(videoAus[vi], vPts);
                                vPts += videoStepUs;
                                vi++;
                                if (vi >= videoAus.Count) {
                                    vi = 0;
                                    cycles++;
                                }
                                sentV++;
                                Thread.Sleep(15);
                            }

                            if (sw.Elapsed - lastLog > TimeSpan.FromSeconds(2)) {
                                lastLog = sw.Elapsed;
                                Console.WriteLine(
                                    "[demo] 推流中 t=" + sw.Elapsed.TotalSeconds.ToString("0.0") +
                                    "s 视频=" + sentV + " 音频=" + sentA + " 循环=" + cycles);
                            }
                        }
                    }
                } catch (SocketException ex) {
                    if (_stop) break;
                    reconnects++;
                    Console.WriteLine("[demo] 连不上/被断开：" + ex.Message);
                    Console.WriteLine("       → 确认「USB直连助手」窗口还在，1 秒后重试…");
                    Thread.Sleep(1000);
                } catch (IOException ex) {
                    if (_stop) break;
                    reconnects++;
                    Console.WriteLine("[demo] 连接中断：" + ex.Message);
                    Console.WriteLine("       → 1 秒后自动重连（手机重开后也会自己恢复）");
                    Thread.Sleep(1000);
                } catch (Exception ex) {
                    if (_stop) break;
                    reconnects++;
                    Console.WriteLine("[demo] " + ex.Message + " → 1 秒后重试");
                    Thread.Sleep(1000);
                }
            }
            Console.WriteLine("[demo] 结束");
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("demo failed: " + ex.Message);
            return 1;
        }
    }

    static volatile bool _stop = false;

    static List<byte[]> SplitAnnexBAccessUnits(byte[] data) {
        var nals = new List<Tuple<int, int, int>>();
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
