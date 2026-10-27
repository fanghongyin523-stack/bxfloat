import CoreImage
import CoreVideo
import QuartzCore
import UIKit

/// 单一 DisplayLink + 降分辨率 CI 出图，供小窗与摄像预览盖层共用，避免双路全分辨率卡顿。
final class CamPreviewPresenter {
    static let shared = CamPreviewPresenter()

    /// 预览最长边（像素），够看且大幅降 CPU/GPU
    private let maxPreviewEdge: CGFloat = 720
    private let ci = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])
    private var link: CADisplayLink?
    private var lastFrameID: Int64 = -1
    private(set) var latestCGImage: CGImage?
    private var consumers = NSHashTable<AnyObject>.weakObjects()
    private let lock = NSLock()

    private init() {}

    func addConsumer(_ consumer: CamPreviewConsuming) {
        consumers.add(consumer as AnyObject)
        ensureRunning()
        if let img = latestCGImage {
            consumer.camPreviewDidUpdate(img)
        }
    }

    func removeConsumer(_ consumer: CamPreviewConsuming) {
        consumers.remove(consumer as AnyObject)
        if consumers.allObjects.isEmpty {
            stop()
        }
    }

    private func ensureRunning() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 10.0, *) {
            l.preferredFramesPerSecond = 20
        }
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastFrameID = -1
    }

    @objc private func tick() {
        let store = CamFrameStore.shared
        let fid = store.frameCount
        guard fid != lastFrameID, let pb = store.copyLatest() else { return }
        lastFrameID = fid

        var ciImage = CIImage(cvPixelBuffer: pb)
        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return }

        let longEdge = max(extent.width, extent.height)
        if longEdge > maxPreviewEdge {
            let s = maxPreviewEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let outExtent = ciImage.extent
        guard let cg = ci.createCGImage(ciImage, from: outExtent) else { return }

        lock.lock()
        latestCGImage = cg
        lock.unlock()

        for obj in consumers.allObjects {
            (obj as? CamPreviewConsuming)?.camPreviewDidUpdate(cg)
        }
    }
}

@objc protocol CamPreviewConsuming: AnyObject {
    func camPreviewDidUpdate(_ image: CGImage)
}
