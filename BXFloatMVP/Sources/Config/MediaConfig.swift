import Foundation

enum ConnectionMode: String, Codable {
    /// 局域网：只填电脑 IP。App 拼 RTSP（低延迟）；注入版无 VLC 则拼 HLS
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
    /// MediaMTX RTSP 端口（默认 18554，独立 App 可手填 rtsp 用）
    var rtspPort: Int
    var streamPath: String
    var opacity: Float
    var windowScale: Float
    var overlayEnabled: Bool
    var muted: Bool

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
        muted: false
    )
}

extension MediaConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case streamURL, computerIP, usbComputerIP, connectionMode
        case hlsPort, rtspPort, streamPath, opacity, windowScale, overlayEnabled, muted
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
    }
}

extension MediaConfig {
    /// 实际拿去播放的地址
    func resolvedPlaybackURL() -> String {
        switch connectionMode {
        case .lan:
            let ip = sanitizedIP(computerIP)
            guard !ip.isEmpty else { return "" }
            #if canImport(MobileVLCKit)
            // 独立 App：RTSP + VLC，延迟通常远低于 HLS
            return "rtsp://\(ip):\(rtspPort)/\(streamPath)"
            #else
            // 注入 dylib：不能带 VLC，仍走 HLS
            return "http://\(ip):\(hlsPort)/\(streamPath)/index.m3u8"
            #endif
        case .usb:
            // 本机桥接端口，由 USBStreamBridge + 电脑助手转发到 MediaMTX（HLS）
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
