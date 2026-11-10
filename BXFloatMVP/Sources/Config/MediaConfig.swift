import Foundation

enum ConnectionMode: String, Codable {
    /// 局域网：只填电脑 IP → RTSP
    case lan
    /// 数据线：手机播 127.0.0.1，电脑 usbmux 桥到本机媒体口（MediaMTX 等；PC 源可为 OBS/其他推流软件）
    case usb
    /// 本地视频文件路径（对标 VCamLocalPlayer）
    case localVideo
    /// 手动完整 URL（http/rtsp/file）
    case manual
}

/// 直播麦采集：推流声 / 手机原麦 / 静音
enum AudioCaptureMode: String, Codable {
    case stream
    case microphone
    case mute
}

struct MediaConfig: Equatable {
    var streamURL: String
    var computerIP: String
    /// 兼容旧配置字段（热点方案遗留，直连方案不再使用）
    var usbComputerIP: String
    var connectionMode: ConnectionMode
    /// PC 媒体 HLS 端口（默认 18888；当前常见为 MediaMTX）
    var hlsPort: Int
    /// PC 媒体 RTSP 端口（默认 18554；助手桥到此口，不绑死某一推流软件）
    var rtspPort: Int
    /// USB 直连 VCU1 device_port（默认 28765，对齐 ports.ini douyin）
    var vcu1Port: Int
    var streamPath: String
    var opacity: Float
    var windowScale: Float
    var overlayEnabled: Bool
    var muted: Bool
    /// 替换摄像头画面（默认关：须手填并手动开启）
    var replaceCameraEnabled: Bool
    /// 麦克风采集：推流声音 / 原麦 / 静音
    var audioCaptureMode: AudioCaptureMode
    /// 融合真实摄像头（对标目标面板）
    var blendRealCamera: Bool
    /// 推流画面融合占比 0…100（历史 JSON 键仍为 blendOBSPercent；OBS 只是一种 PC 源）
    var blendStreamPercent: Int
    /// 画面方向：旋转角度（0/90/180/270）与镜像（对标 VCam rotation/mirrored）
    var rotationDegrees: Int
    var mirrored: Bool
    /// 定时显示真实镜头
    var timedRealCamera: Bool
    /// 间隔秒（面板展示可用小时换算）
    var timedRealIntervalSec: Int
    /// 露出时长秒：1/2/3
    var timedRealShowSec: Int
    /// 高级区是否展开
    var advancedExpanded: Bool

    /// usbmux 隧道端口（电脑助手连这个）
    static let usbTunnelPort = 19888

    static let `default` = MediaConfig(
        streamURL: "",
        computerIP: "",
        usbComputerIP: "",
        connectionMode: .lan,
        hlsPort: 18888,
        rtspPort: 18554,
        vcu1Port: 28765,
        streamPath: "stream",
        opacity: 1.0,
        windowScale: 0.42,
        overlayEnabled: false,
        muted: false,
        replaceCameraEnabled: false,
        audioCaptureMode: .microphone,
        blendRealCamera: false,
        blendStreamPercent: 90,
        rotationDegrees: 0,
        mirrored: false,
        timedRealCamera: false,
        timedRealIntervalSec: 2 * 3600,
        timedRealShowSec: 2,
        advancedExpanded: true
    )
}

extension MediaConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case streamURL, computerIP, usbComputerIP, connectionMode
        case hlsPort, rtspPort, vcu1Port, streamPath, opacity, windowScale, overlayEnabled, muted
        case replaceCameraEnabled, audioCaptureMode, blendRealCamera
        case blendStreamPercent = "blendOBSPercent"
        case rotationDegrees, mirrored, timedRealCamera, timedRealIntervalSec, timedRealShowSec
        case advancedExpanded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        computerIP = try c.decodeIfPresent(String.self, forKey: .computerIP) ?? ""
        usbComputerIP = try c.decodeIfPresent(String.self, forKey: .usbComputerIP) ?? ""
        connectionMode = try c.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .lan
        hlsPort = try c.decodeIfPresent(Int.self, forKey: .hlsPort) ?? 18888
        rtspPort = try c.decodeIfPresent(Int.self, forKey: .rtspPort) ?? 18554
        vcu1Port = try c.decodeIfPresent(Int.self, forKey: .vcu1Port) ?? 28765
        streamPath = try c.decodeIfPresent(String.self, forKey: .streamPath) ?? "stream"
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        windowScale = try c.decodeIfPresent(Float.self, forKey: .windowScale) ?? 0.42
        overlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        // 硬约束：替换默认关；旧配置若曾为开也允许，但新默认 false
        replaceCameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .replaceCameraEnabled) ?? false
        if let mode = try c.decodeIfPresent(AudioCaptureMode.self, forKey: .audioCaptureMode) {
            audioCaptureMode = mode
        } else if muted {
            audioCaptureMode = .mute
        } else {
            // 默认手机麦克风；推流声须手动开开关
            audioCaptureMode = .microphone
        }
        blendRealCamera = try c.decodeIfPresent(Bool.self, forKey: .blendRealCamera) ?? false
        blendStreamPercent = try c.decodeIfPresent(Int.self, forKey: .blendStreamPercent) ?? 90
        rotationDegrees = try c.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
        timedRealCamera = try c.decodeIfPresent(Bool.self, forKey: .timedRealCamera) ?? false
        timedRealIntervalSec = try c.decodeIfPresent(Int.self, forKey: .timedRealIntervalSec) ?? (2 * 3600)
        timedRealShowSec = try c.decodeIfPresent(Int.self, forKey: .timedRealShowSec) ?? 2
        advancedExpanded = try c.decodeIfPresent(Bool.self, forKey: .advancedExpanded) ?? true
    }
}

extension MediaConfig {
    /// 实际拿去播放的地址
    func resolvedPlaybackURL() -> String {
        switch connectionMode {
        case .lan:
            let ip = sanitizedIP(computerIP)
            guard !ip.isEmpty else { return "" }
            return "rtsp://\(ip):\(rtspPort)/\(streamPath)"
        case .usb:
            return "rtsp://127.0.0.1:\(rtspPort)/\(streamPath)"
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

    private let defaultsKey = "baixiang.conf.mvp.v4"
    private(set) var config: MediaConfig = .default

    private init() {}

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(MediaConfig.self, from: data)
        {
            config = decoded
            return
        }
        // v3 → v4：强制默认关替换 + 原麦（禁止旧配置「开关看着关实际还在拉」）
        if let data = UserDefaults.standard.data(forKey: "baixiang.conf.mvp.v3"),
           var decoded = try? JSONDecoder().decode(MediaConfig.self, from: data)
        {
            decoded.replaceCameraEnabled = false
            decoded.audioCaptureMode = .microphone
            decoded.muted = false
            config = decoded
            save(decoded, postNotification: false)
            return
        }
        // 兼容 v2
        if let data = UserDefaults.standard.data(forKey: "baixiang.conf.mvp.v2"),
           var decoded = try? JSONDecoder().decode(MediaConfig.self, from: data)
        {
            decoded.replaceCameraEnabled = false
            decoded.audioCaptureMode = .microphone
            config = decoded
            save(decoded, postNotification: false)
            return
        }
        if let data = UserDefaults.standard.data(forKey: "baixiang.conf.mvp"),
           let old = try? JSONDecoder().decode(OldMediaConfig.self, from: data)
        {
            var migrated = MediaConfig.default
            migrated.streamURL = old.streamURL
            migrated.opacity = old.opacity
            migrated.windowScale = old.windowScale
            migrated.overlayEnabled = old.overlayEnabled
            migrated.muted = old.muted
            migrated.replaceCameraEnabled = false
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
