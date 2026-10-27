import CoreImage
import CoreVideo
import QuartzCore
import UIKit

/// 注入用 RTSP 播放器：拉流进 CamFrameStore，CIContext 刷 layer（避免 UIImage(ciImage:) 卡顿）。
final class RTSPVTPlayer: NSObject, StreamPlayer {
    private let preview = RTSPPreviewView()
    private var displayLink: CADisplayLink?
    private let ci = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private var lastFrameID: Int64 = -1
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
            if #available(iOS 10.0, *) {
                link.preferredFramesPerSecond = 30
            }
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
        preview.setCGImage(nil)
        lastFrameID = -1
    }

    @objc private func tick() {
        guard isPlaying else { return }
        let store = CamFrameStore.shared
        let fid = store.frameCount
        guard fid != lastFrameID, let pb = store.copyLatest() else { return }
        lastFrameID = fid
        let ciImage = CIImage(cvPixelBuffer: pb)
        let rect = ciImage.extent
        guard rect.width > 1, rect.height > 1,
              let cg = ci.createCGImage(ciImage, from: rect)
        else { return }
        preview.setCGImage(cg)
    }
}

private final class RTSPPreviewView: UIView {
    private let imageLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resizeAspect
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
