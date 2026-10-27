import CoreImage
import CoreVideo
import QuartzCore
import UIKit

/// 单一 DisplayLink 调度 + 后台降分辨率 CI 出图，供小窗与摄像预览盖层共用。
/// CI 不在主线程跑，避免抖音主界面卡死 DisplayLink 变成「幻灯片」。
final class CamPreviewPresenter {
    static let shared = CamPreviewPresenter()

    /// 预览最长边（像素）：小窗够看，显著降 CPU/GPU
    private let maxPreviewEdge: CGFloat = 540
    private let ci = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])
    private let renderQueue = DispatchQueue(label: "com.baixiang.preview.render", qos: .userInteractive)
    private var link: CADisplayLink?
    private var lastFrameID: Int64 = -1
    private var rendering = false
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
            l.preferredFramesPerSecond = 24
        }
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lock.lock()
        lastFrameID = -1
        rendering = false
        lock.unlock()
    }

    @objc private func tick() {
        let store = CamFrameStore.shared
        let fid = store.frameCount
        guard let pb = store.copyLatest() else { return }

        lock.lock()
        // 上一帧还在渲染：不占主线程，下一拍再取最新
        if rendering || fid == lastFrameID {
            lock.unlock()
            return
        }
        rendering = true
        lastFrameID = fid
        lock.unlock()

        let maxEdge = maxPreviewEdge
        let ciContext = ci
        renderQueue.async { [weak self] in
            guard let self else { return }
            var cgOut: CGImage?
            defer {
                self.lock.lock()
                self.rendering = false
                if let cgOut {
                    self.latestCGImage = cgOut
                }
                self.lock.unlock()
                if let cgOut {
                    DispatchQueue.main.async {
                        for obj in self.consumers.allObjects {
                            (obj as? CamPreviewConsuming)?.camPreviewDidUpdate(cgOut)
                        }
                    }
                }
            }

            var ciImage = CIImage(cvPixelBuffer: pb)
            let extent = ciImage.extent
            guard extent.width > 1, extent.height > 1 else { return }

            let longEdge = max(extent.width, extent.height)
            if longEdge > maxEdge {
                let s = maxEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            cgOut = ciContext.createCGImage(ciImage, from: ciImage.extent)
        }
    }
}

@objc protocol CamPreviewConsuming: AnyObject {
    func camPreviewDidUpdate(_ image: CGImage)
}
