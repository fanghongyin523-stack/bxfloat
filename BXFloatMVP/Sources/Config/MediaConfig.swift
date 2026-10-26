import Foundation

enum ConnectionMode: String, Codable {
    /// 局域网：只填电脑 IP → RTSP（App=VLC，注入=内嵌 RTSP+VT）
    case lan
    /// 数据线：不需 SIM/热点；手机播 127.0.0.1，电脑 usbmux 桥到 MediaMTX
    case usb
    /// 本地视频文件路径
    case localVideo
    /// 手动完整 URL（http/rtsp/file）
    case manual
}

struct MediaConfig: Equatable {
    var streamURL: String
    var computerIP: String
    /// 兼容旧配置字段（热点方案遗留，直连方案不再使用）
    var usbComputerIP: String
    var connectionMode: ConnectionMode
    /// MediaMTX HLS 端口（默认 18888）
    var hlsPort: Int
    /// MediaMTX RTSP 端口（默认 18554）
    var rtspPort: Int
    var streamPath: String
    var opacity: Float
    var windowScale: Float
    var overlayEnabled: Bool
    var muted: Bool
    /// 最终目标：替换摄像头画面
    var replaceCameraEnabled: Bool
    /// 第2期：融合真实摄像头（占位持久化）
    var blendRealCamera: Bool
    var blendOBSPercent: Int

    /// usbmux 隧道端口（电脑助手连这个）
    static let usbTunnelPort = 19888

    static let `default` = MediaConfig(
        streamURL: "",
        computerIP: "",
        usbComputerIP: "",
        connectionMode: .lan,
        hlsPort: 18888,
        rtspPort: 18554,
        streamPath: "stream",
        opacity: 1.0,
        windowScale: 0.42,
        overlayEnabled: false,
        muted: false,
        replaceCameraEnabled: false,
        blendRealCamera: false,
        blendOBSPercent: 90
    )
}

extension MediaConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case streamURL, computerIP, usbComputerIP, connectionMode
        case hlsPort, rtspPort, streamPath, opacity, windowScale, overlayEnabled, muted
        case replaceCameraEnabled, blendRealCamera, blendOBSPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        computerIP = try c.decodeIfPresent(String.self, forKey: .computerIP) ?? ""
        usbComputerIP = try c.decodeIfPresent(String.self, forKey: .usbComputerIP) ?? ""
        connectionMode = try c.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .lan
        hlsPort = try c.decodeIfPresent(Int.self, forKey: .hlsPort) ?? 18888
        rtspPort = try c.decodeIfPresent(Int.self, forKey: .rtspPort) ?? 18554
        streamPath = try c.decodeIfPresent(String.self, forKey: .streamPath) ?? "stream"
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        windowScale = try c.decodeIfPresent(Float.self, forKey: .windowScale) ?? 0.42
        overlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        replaceCameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .replaceCameraEnabled) ?? false
        blendRealCamera = try c.decodeIfPresent(Bool.self, forKey: .blendRealCamera) ?? false
        blendOBSPercent = try c.decodeIfPresent(Int.self, forKey: .blendOBSPercent) ?? 90
    }
}

extension MediaConfig {
    /// 实际拿去播放的地址（局域网统一 RTSP，冲 3 秒内）
    func resolvedPlaybackURL() -> String {
        switch connectionMode {
        case .lan:
            let ip = sanitizedIP(computerIP)
            guard !ip.isEmpty else { return "" }
            return "rtsp://\(ip):\(rtspPort)/\(streamPath)"
        case .usb:
            // 第1期 USB 仍 HLS；第2期再上 RTSP 隧道
            return "http://127.0.0.1:\(hlsPort)/\(streamPath)/index.m3u8"
        case .localVideo, .manual:
            return streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func sanitizedIP(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "http://", with: "")
        s = s.replacingOccurrences(of: "https://", with: "")
        s = s.replacingOccurrences(of: "rtsp://", with: "")
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        if let colon = s.firstIndex(of: ":"), s.contains(".") {
            let host = String(s[..<colon])
            if host.split(separator: ".").count == 4 {
                return host
            }
        }
        return s
    }
}

final class MediaConfigStore {
    static let shared = MediaConfigStore()

    private let defaultsKey = "baixiang.conf.mvp.v2"
    private(set) var config: MediaConfig = .default

    private init() {}

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(MediaConfig.self, from: data)
        {
            config = decoded
            return
        }
        // 兼容旧版 key
        if let data = UserDefaults.standard.data(forKey: "baixiang.conf.mvp"),
           let old = try? JSONDecoder().decode(OldMediaConfig.self, from: data)
        {
            var migrated = MediaConfig.default
            migrated.streamURL = old.streamURL
            migrated.opacity = old.opacity
            migrated.windowScale = old.windowScale
            migrated.overlayEnabled = old.overlayEnabled
            migrated.muted = old.muted
            if old.streamURL.lowercased().hasPrefix("rtsp://") || old.streamURL.lowercased().hasPrefix("http") {
                migrated.connectionMode = .manual
            }
            config = migrated
            save(migrated, postNotification: false)
            return
        }
        config = .default
    }

    func save(_ config: MediaConfig, postNotification: Bool = true) {
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if postNotification {
            NotificationCenter.default.post(name: .bxMediaConfigDidChange, object: nil)
        }
    }

    func update(postNotification: Bool = true, _ mutate: (inout MediaConfig) -> Void) {
        var next = config
        mutate(&next)
        save(next, postNotification: postNotification)
    }
}

private struct OldMediaConfig: Codable {
    var streamURL: String
    var opacity: Float
    var windowScale: Float
    var overlayEnabled: Bool
    var muted: Bool
}

extension Notification.Name {
    static let bxMediaConfigDidChange = Notification.Name("com.baixiang.notify.reload")
}
