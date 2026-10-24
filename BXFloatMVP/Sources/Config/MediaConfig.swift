import Foundation

struct MediaConfig: Codable, Equatable {
    /// 播放地址：本地 file://、http(s)、或后续 RTSP
    var streamURL: String
    /// 0.2 ~ 1.0
    var opacity: Float
    /// 悬浮窗默认边长比例（相对短边）
    var windowScale: Float
    /// 是否开启悬浮窗
    var overlayEnabled: Bool
    /// 是否静音
    var muted: Bool

    static let `default` = MediaConfig(
        streamURL: "",
        opacity: 1.0,
        windowScale: 0.42,
        overlayEnabled: false,
        muted: false
    )
}

final class MediaConfigStore {
    static let shared = MediaConfigStore()

    private let defaultsKey = "baixiang.conf.mvp"
    private(set) var config: MediaConfig = .default

    private init() {}

    func load() {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(MediaConfig.self, from: data)
        else {
            config = .default
            return
        }
        config = decoded
    }

    func save(_ config: MediaConfig) {
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: .bxMediaConfigDidChange, object: nil)
    }

    func update(_ mutate: (inout MediaConfig) -> Void) {
        var next = config
        mutate(&next)
        save(next)
    }
}

extension Notification.Name {
    static let bxMediaConfigDidChange = Notification.Name("com.baixiang.notify.reload")
}
