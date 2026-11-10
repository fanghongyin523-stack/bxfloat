using System;
using System.Collections.Generic;
using System.IO;

/// Maps BXMS adapter msg types → VCU1 type/flags.
/// Only VCU1 type values 3 and 6 are binary-proven; defaults use 3 for media payloads.
public sealed class TypeMap {
    public byte VideoConfigType = Vcu1Codec.TypeProvenPayloadEnqueue;
    public byte AudioConfigType = Vcu1Codec.TypeProvenPayloadEnqueue;
    public byte VideoType = Vcu1Codec.TypeProvenPayloadEnqueue;
    public byte AudioType = Vcu1Codec.TypeProvenPayloadEnqueue;
    public ushort DefaultFlags = 0; // bit meanings UNPROVEN — send 0 unless overridden

    public static TypeMap Load(string path) {
        var m = new TypeMap();
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return m;
        foreach (string raw in File.ReadAllLines(path)) {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#") || line.StartsWith("[")) continue;
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string k = line.Substring(0, eq).Trim().ToLowerInvariant();
            string v = line.Substring(eq + 1).Trim();
            byte b;
            ushort u;
            if (k == "video_config_type" && byte.TryParse(v, out b)) m.VideoConfigType = b;
            else if (k == "audio_config_type" && byte.TryParse(v, out b)) m.AudioConfigType = b;
            else if (k == "video_type" && byte.TryParse(v, out b)) m.VideoType = b;
            else if (k == "audio_type" && byte.TryParse(v, out b)) m.AudioType = b;
            else if (k == "default_flags" && ushort.TryParse(v, out u)) m.DefaultFlags = u;
        }
        return m;
    }

    public byte MapMsg(byte bxmsMsg) {
        switch (bxmsMsg) {
            case BxmsCodec.MsgVideoConfig: return VideoConfigType;
            case BxmsCodec.MsgAudioConfig: return AudioConfigType;
            case BxmsCodec.MsgVideo: return VideoType;
            case BxmsCodec.MsgAudio: return AudioType;
            default: return VideoType;
        }
    }
}
