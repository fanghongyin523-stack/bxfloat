import CoreImage
import CoreVideo
import Foundation

/// 后台按「采集缓冲」的宽高+像素格式预渲染好一帧；采集回调里只 memcpy，绝不跑 CI。
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
    private var prepFmt: OSType = 0
    private var lastSrcID: Int64 = -1
    private var targetW = 0
    private var targetH = 0
    private var targetFmt: OSType = 0
    private var ticking = false

    private init() {}

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on {
            prepared = nil
            lastSrcID = -1
            prepW = 0
            prepH = 0
            prepFmt = 0
        }
        let needTick = on && !ticking
        if needTick { ticking = true }
        lock.unlock()
        if needTick { queue.async { self.tick() } }
    }

    /// 采集回调上报目标（只记数）。
    func noteTarget(width: Int, height: Int, format: OSType) {
        guard width > 0, height > 0, format != 0 else { return }
        lock.lock()
        targetW = width
        targetH = height
        targetFmt = format
        lock.unlock()
    }

    /// 尺寸+格式都匹配才返回，供回调 memcpy。
    func copyPrepared(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let prepared,
              prepW == width,
              prepH == height,
              prepFmt == format else { return nil }
        return prepared
    }

    var hasPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prepared != nil
    }

    private func tick() {
        lock.lock()
        let on = enabled
        let tw = targetW
        let th = targetH
        let tf = targetFmt
        if !on {
            ticking = false
            lock.unlock()
            return
        }
        lock.unlock()

        if tw > 0, th > 0, tf != 0 {
            prepareIfNeeded(width: tw, height: th, format: tf)
        }

        queue.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.tick()
        }
    }

    private func prepareIfNeeded(width: Int, height: Int, format: OSType) {
        let store = CamFrameStore.shared
        guard store.hasFreshFrame else { return }
        // 与声音同一 mediaTime，取最接近的历史帧（不能只拿 latest，否则音画脱节）
        let mediaT = AVSyncClock.shared.mediaTime()
        guard let src = store.copyForMediaTime(mediaT) ?? store.copyLatest() else { return }
        // mediaTime 量化到 33ms 一档，与采集节奏对齐并驱动重渲
        let syncKey = Int64((mediaT * 30.0).rounded())

        lock.lock()
        let unchanged = (prepW == width && prepH == height && prepFmt == format &&
            prepared != nil && lastSrcID == syncKey)
        if unchanged {
            lock.unlock()
            return
        }
        lastSrcID = syncKey
        lock.unlock()

        // 统一先渲到 BGRA，再视目标格式决定是否二次写入
        var bgra: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bgra
        ) == kCVReturnSuccess, let bgra else { return }

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
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ci.render(placed, to: bgra, bounds: bounds, colorSpace: colorSpace)

        let final: CVPixelBuffer
        if format == kCVPixelFormatType_32BGRA {
            final = bgra
        } else {
            var dst: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &dst
            ) == kCVReturnSuccess, let dst else { return }
            // 后台把 BGRA 转成采集格式（YUV 等）
            ci.render(CIImage(cvPixelBuffer: bgra), to: dst, bounds: bounds, colorSpace: colorSpace)
            final = dst
        }

        lock.lock()
        prepared = final
        prepW = width
        prepH = height
        prepFmt = format
        lock.unlock()
    }
}
