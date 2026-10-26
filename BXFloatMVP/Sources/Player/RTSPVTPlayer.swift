import QuartzCore
import UIKit

/// 注入用 RTSP 播放器：拉流进 CamFrameStore，并用 CIImage 刷到 view 做小窗预览。
final class RTSPVTPlayer: NSObject, StreamPlayer {
    private let preview = RTSPPreviewView()
    private var displayLink: CADisplayLink?
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
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        RTSPVTPuller.shared.stop()
        preview.image = nil
    }

    @objc private func tick() {
        guard isPlaying, let pb = CamFrameStore.shared.copyLatest() else { return }
        preview.image = UIImage(ciImage: CIImage(cvPixelBuffer: pb))
    }
}

private final class RTSPPreviewView: UIView {
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}
