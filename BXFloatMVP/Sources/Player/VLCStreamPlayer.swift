import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit

/// RTSP / 部分网络流：用 VLC 解码（局域网摄像头常用）。
final class VLCStreamPlayer: NSObject, StreamPlayer, VLCMediaPlayerDelegate {
    private let mediaPlayer = VLCMediaPlayer()
    private let container = UIView()

    var view: UIView { container }

    var isPlaying: Bool {
        mediaPlayer.isPlaying
    }

    var isMuted: Bool {
        get { mediaPlayer.audio?.isMuted ?? false }
        set { mediaPlayer.audio?.isMuted = newValue }
    }

    override init() {
        super.init()
        container.backgroundColor = .black
        mediaPlayer.drawable = container
        mediaPlayer.delegate = self
    }

    func load(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamPlayerError.emptyURL }
        guard let url = URL(string: trimmed) else { throw StreamPlayerError.invalidURL }

        stop()
        let media = VLCMedia(url: url)
        // 低延迟优先（可略增卡顿风险）
        media.addOption(":network-caching=120")
        media.addOption(":live-caching=120")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        media.addOption(":rtsp-tcp")
        media.addOption(":rtsp-frame-buffer-size=0")
        media.addOption(":drop-late-frames")
        media.addOption(":skip-frames")
        media.addOption(":avcodec-hw=any")
        mediaPlayer.media = media
    }

    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        NSLog("BXFloat VLC state=%@", String(describing: mediaPlayer.state))
    }
}
#endif
