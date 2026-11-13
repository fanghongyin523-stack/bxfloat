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
            clearPreparedLocked()
        }
        let needTick = on && !ticking
        if needTick { ticking = true }
        lock.unlock()
        if needTick { queue.async { self.tick() } }
    }

    /// 换源时丢掉预渲染，禁止本地/局域网/USB 残帧互串
    func invalidatePrepared() {
        lock.lock()
        clearPreparedLocked()
        lock.unlock()
    }

    private func clearPreparedLocked() {
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

        // ~50Hz 预渲染：比 30Hz 更跟得上解码出帧，利于流畅（仍在 blit 队列，不占主线程）
        queue.asyncAfter(deadline: .now() + 0.020) { [weak self] in
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
        let tag: (CVPixelBuffer) -> CVPixelBuffer = { buf in
            // 420 目标缓冲也打 BT.709，避免二次 render 时无附件偏色
            if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8Planar
                || format == kCVPixelFormatType_420YpCbCr8PlanarFullRange
            {
                CamFrameStore.ensureBT709Attachments(buf)
            }
            return buf
        }
        if let pool {
            var buf: CVPixelBuffer?
            let err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
            if err == kCVReturnSuccess, let buf { return tag(buf) }
        }
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buf
        ) == kCVReturnSuccess, let buf else { return nil }
        return tag(buf)
    }

    private func prepareIfNeeded(width: Int, height: Int, format: OSType) {
        let store = CamFrameStore.shared
        guard store.hasFreshFrame else { return }

        // 缺帧/时钟冻结：上屏用最新已解码帧，禁止钉在冻结 mediaTime 上两秒才换一张
        let stalled = AVSyncClock.shared.isVideoPresentationStalled()
        let mediaT = AVSyncClock.shared.mediaTime()
        let src: CVPixelBuffer?
        let syncKey: Int64
        if stalled {
            src = store.copyLatest()
            // 每来一帧必刷新 prepared（勿用冻结 mediaT 桶）
            syncKey = store.frameCount
        } else {
            src = store.copyForMediaTimeIfLock(mediaT) ?? store.copyForMediaTime(mediaT)
            // mediaT 桶 ⊕ frameCount：同桶内新解码帧也会刷新
            syncKey = (Int64((mediaT * 30.0).rounded()) & 0x3FFF_FFFF) ^ (store.frameCount << 20)
        }
        guard let src else { return }

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

        // 对标 VCamTang paint：rotation + mirrored 后 cover 到宿主尺寸
        // 色彩：BT.709（与解码附件 / 发送端建议 VUI 对齐），禁止无标记 DeviceRGB 解错 limited/full
        let cfg = MediaConfigStore.shared.config
        // CIImage 读 CV 附件（BT.709）；render 目标用 itur_709，禁止 DeviceRGB 解错 limited/full
        let bt709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        var ciSrc = CIImage(cvPixelBuffer: src)
        let rot = ((cfg.rotationDegrees % 360) + 360) % 360
        if rot == 90 {
            ciSrc = ciSrc.oriented(.right)
        } else if rot == 180 {
            ciSrc = ciSrc.oriented(.down)
        } else if rot == 270 {
            ciSrc = ciSrc.oriented(.left)
        }
        if cfg.mirrored {
            ciSrc = ciSrc.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -ciSrc.extent.width, y: 0))
        }
        let sw = ciSrc.extent.width
        let sh = ciSrc.extent.height
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
        ci.render(placed, to: bgra, bounds: bounds, colorSpace: bt709)

        let final: CVPixelBuffer
        if format == kCVPixelFormatType_32BGRA {
            final = bgra
        } else {
            guard let dst = makeBuffer(pool: dstP, width: width, height: height, format: format) else {
                return
            }
            CamFrameStore.ensureBT709Attachments(dst)
            ci.render(CIImage(cvPixelBuffer: bgra), to: dst, bounds: bounds, colorSpace: bt709)
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
