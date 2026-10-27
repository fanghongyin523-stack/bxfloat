import CoreImage
import CoreVideo
import Foundation

/// 后台把推流预缩放到采集尺寸（BGRA），采集回调里只做轻量写入，避免冻帧。
final class CamFrameBlitter {
    static let shared = CamFrameBlitter()

    private let queue = DispatchQueue(label: "com.baixiang.cam.blit", qos: .userInteractive)
    private let lock = NSLock()
    private let ci = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])

    private var enabled = false
    private var prepared: CVPixelBuffer?
    private var prepW = 0
    private var prepH = 0
    private var lastSrcID: Int64 = -1
    private var targetW = 0
    private var targetH = 0
    private var ticking = false

    private init() {}

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on {
            prepared = nil
            lastSrcID = -1
        }
        let needTick = on && !ticking
        if needTick { ticking = true }
        lock.unlock()
        if needTick { queue.async { self.tick() } }
    }

    /// 采集回调上报目标尺寸（仅记数，不碰 UIKit）。
    func noteTarget(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        targetW = width
        targetH = height
        lock.unlock()
    }

    func copyPrepared(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let prepared, prepW == width, prepH == height else { return nil }
        return prepared
    }

    private func tick() {
        lock.lock()
        let on = enabled
        let tw = targetW
        let th = targetH
        if !on {
            ticking = false
            lock.unlock()
            return
        }
        lock.unlock()

        if tw > 0, th > 0 {
            prepareIfNeeded(width: tw, height: th)
        }

        queue.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.tick()
        }
    }

    private func prepareIfNeeded(width: Int, height: Int) {
        let store = CamFrameStore.shared
        guard store.hasFreshFrame, let src = store.copyLatest() else { return }
        let fid = store.frameCount

        lock.lock()
        let same = (fid == lastSrcID && prepW == width && prepH == height && prepared != nil)
        if same {
            lock.unlock()
            return
        }
        lastSrcID = fid
        lock.unlock()

        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out
        )
        guard st == kCVReturnSuccess, let out else { return }

        let ciSrc = CIImage(cvPixelBuffer: src)
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        guard sw > 1, sh > 1 else { return }

        let scale = max(CGFloat(width) / sw, CGFloat(height) / sh)
        let scaled = ciSrc.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropped = scaled.cropped(
            to: CGRect(
                x: (scaled.extent.width - CGFloat(width)) / 2,
                y: (scaled.extent.height - CGFloat(height)) / 2,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )
        let placed = cropped.transformed(
            by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        )
        ci.render(
            placed,
            to: out,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        lock.lock()
        prepared = out
        prepW = width
        prepH = height
        lock.unlock()
    }
}
