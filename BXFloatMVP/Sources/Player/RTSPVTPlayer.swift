import QuartzCore
import UIKit

/// 注入用 RTSP 播放器：拉流进 CamFrameStore，小窗吃共享降分辨率预览。
final class RTSPVTPlayer: NSObject, StreamPlayer, CamPreviewConsuming {
    private let preview = RTSPPreviewView()
    private(set) var isPlaying = false
    var isMuted: Bool = true

    var view: UIView { preview }

    func load(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamPlayerError.emptyURL }
        guard StreamURLAnalyzer.kind(of: trimmed) == .rtsp else {
            throw StreamPlayerError.invalidURL
        }
        RTSPVTPuller.shared.start(urlString: trimmed)
    }

    func play() {
        isPlaying = true
        CamPreviewPresenter.shared.addConsumer(self)
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        CamPreviewPresenter.shared.removeConsumer(self)
        RTSPVTPuller.shared.stop()
        preview.setCGImage(nil)
    }

    func camPreviewDidUpdate(_ image: CGImage) {
        guard isPlaying else { return }
        preview.setCGImage(image)
    }
}

private final class RTSPPreviewView: UIView {
    private let imageLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(imageLayer)
        // 铺满小窗并裁切黑边（与拍摄盖层 scaleAspectFill 一致）
        imageLayer.contentsGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    func setCGImage(_ image: CGImage?) {
        imageLayer.contents = image
    }
}
