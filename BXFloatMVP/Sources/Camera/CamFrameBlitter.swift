import CoreImage
import CoreVideo
import Foundation

/// 后台按采集格式预渲染；失败时保留上一帧，避免闪回真机摄像头。
/// 使用 CVPixelBufferPool 复用缓冲，避免长录时每帧 Create 导致内存/卡顿。
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
    private var lastSyncKey: Int64 = -1
    private var targetW = 0
    private var targetH = 0
    private var targetFmt: OSType = 0
    private var ticking = false

    private var bgraPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0
    private var poolDstFmt: OSType = 0

    private init() {}

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on {
            prepared = nil
            lastSyncKey = -1
            prepW = 0
            prepH = 0
            prepFmt = 0
            bgraPool = nil
            dstPool = nil
            poolW = 0
            poolH = 0
            poolDstFmt = 0
        }
        let needTick = on && !ticking
        if needTick { ticking = true }
        lock.unlock()
        if needTick { queue.async { self.tick() } }
    }

    func noteTarget(width: Int, height: Int, format: OSType) {
        guard width > 0, height > 0, format != 0 else { return }
        lock.lock()
        targetW = width
        targetH = height
        targetFmt = format
        lock.unlock()
    }

    /// 匹配则返回预渲染帧；尺寸突变前仍返回旧帧，杜绝闪真机。
    func copyPrepared(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        guard lock.lock(before: Date().addingTimeInterval(0.001)) else { return nil }
        defer { lock.unlock() }
        guard let prepared else { return nil }
        if prepW == width, prepH == height, prepFmt == format {
            return prepared
        }
        return nil
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

    private func ensurePools(width: Int, height: Int, format: OSType) {
        lock.lock()
        let need =
            bgraPool == nil || dstPool == nil || poolW != width || poolH != height || poolDstFmt != format
        if !need {
            lock.unlock()
            return
        }
        lock.unlock()

        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        var bgra: CVPixelBufferPool?
        var dst: CVPixelBufferPool?
        let bgraSrc: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let dstSrc: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault, attrs as CFDictionary, bgraSrc as CFDictionary, &bgra
        )
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault, attrs as CFDictionary, dstSrc as CFDictionary, &dst
        )

        lock.lock()
        bgraPool = bgra
        dstPool = dst
        poolW = width
        poolH = height
        poolDstFmt = format
        lock.unlock()
    }

    private func makeBuffer(pool: CVPixelBufferPool?, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if let pool {
            var buf: CVPixelBuffer?
            let err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
            if err == kCVReturnSuccess, let buf { return buf }
        }
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buf
        ) == kCVReturnSuccess else { return nil }
        return buf
    }

    private func prepareIfNeeded(width: Int, height: Int, format: OSType) {
        let store = CamFrameStore.shared
        guard store.hasFreshFrame else { return }
        let mediaT = AVSyncClock.shared.mediaTime()
        guard let src = store.copyForMediaTimeIfLock(mediaT) ?? store.copyForMediaTime(mediaT) else {
            return
        }

        let syncKey = Int64((mediaT * 30.0).rounded())
        lock.lock()
        let unchanged = prepared != nil && prepW == width && prepH == height &&
            prepFmt == format && lastSyncKey == syncKey
        if unchanged {
            lock.unlock()
            return
        }
        lastSyncKey = syncKey
        lock.unlock()

        ensurePools(width: width, height: height, format: format)

        lock.lock()
        let bgraP = bgraPool
        let dstP = dstPool
        lock.unlock()

        guard let bgra = makeBuffer(
            pool: bgraP, width: width, height: height, format: kCVPixelFormatType_32BGRA
        ) else { return }

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
            guard let dst = makeBuffer(pool: dstP, width: width, height: height, format: format) else {
                return
            }
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
