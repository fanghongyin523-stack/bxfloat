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

        // 推流替换 / 开直播保持 ~50Hz。拍摄、分段拍、分屏拍回到 ~30Hz，
        // 避免预渲染和抖音自己的相机/GPU 抢时间。仍在 blit 队列，不占主线程。
        let interval = ShootSurfaceDetector.isNativeShootCapture() ? 0.033 : 0.020
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
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

        let cfgEarly = MediaConfigStore.shared.config
        let rotEarly = ((cfgEarly.rotationDegrees % 360) + 360) % 360
        // 无旋转/镜像时不经 CI。CI 写进 420 常常是一张黑帧：收帧计数在涨，抖音预览却全黑。
        if rotEarly == 0, !cfgEarly.mirrored,
           let cpu = cpuPrepare(src, width: width, height: height, format: format)
        {
            lock.lock()
            prepared = cpu
            prepW = width
            prepH = height
            prepFmt = format
            lock.unlock()
            return
        }

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
        publishCPU(bgra)

        let final: CVPixelBuffer
        if format == kCVPixelFormatType_32BGRA {
            final = bgra
        } else if isBiplanar420(format),
                  let dst = makeBuffer(pool: dstP, width: width, height: height, format: format),
                  writeBGRA(bgra, into420: dst, videoRange: isVideoRange(format))
        {
            // 第二次 CI 写 420 经常得到一整张黑帧（收帧在涨，预览却是黑的）。
            // BGRA 已经在 CPU 上，这里直接换成相机要的 NV12。
            CamFrameStore.ensureBT709Attachments(dst)
            final = dst
        } else {
            guard let dst = makeBuffer(pool: dstP, width: width, height: height, format: format) else {
                return
            }
            CamFrameStore.ensureBT709Attachments(dst)
            ci.render(CIImage(cvPixelBuffer: bgra), to: dst, bounds: bounds, colorSpace: bt709)
            publishCPU(dst)
            final = dst
        }

        lock.lock()
        prepared = final
        prepW = width
        prepH = height
        prepFmt = format
        lock.unlock()
    }

    private func isBiplanar420(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func isVideoRange(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8Planar
    }

    /// 把 GPU 上的 CI 结果拉回 CPU，避免随后 memcpy 读到一片 0。
    private func publishCPU(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    /// 同格式拷贝，或 BGRA↔NV12。失败则交给 CI。
    private func cpuPrepare(_ src: CVPixelBuffer, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        let sf = CVPixelBufferGetPixelFormatType(src)
        guard sw > 1, sh > 1, width > 1, height > 1 else { return nil }
        guard let dst = makeBuffer(pool: nil, width: width, height: height, format: format) else { return nil }
        let ok: Bool
        if sf == format {
            ok = transferSameFormat(src, dst)
        } else if sf == kCVPixelFormatType_32BGRA, isBiplanar420(format) {
            ok = writeBGRA(src, into420: dst, videoRange: isVideoRange(format))
        } else if isBiplanar420(sf), format == kCVPixelFormatType_32BGRA {
            ok = write420(src, intoBGRA: dst, videoRange: isVideoRange(sf))
        } else {
            ok = false
        }
        if ok {
            CamFrameStore.ensureBT709Attachments(dst)
            return dst
        }
        return nil
    }

    private func transferSameFormat(_ src: CVPixelBuffer, _ dst: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(src)
        guard planes == CVPixelBufferGetPlaneCount(dst) else { return false }
        if planes == 0 {
            return scaleBytes(
                src: CVPixelBufferGetBaseAddress(src),
                sRow: CVPixelBufferGetBytesPerRow(src),
                sW: CVPixelBufferGetWidth(src),
                sH: CVPixelBufferGetHeight(src),
                dst: CVPixelBufferGetBaseAddress(dst),
                dRow: CVPixelBufferGetBytesPerRow(dst),
                dW: CVPixelBufferGetWidth(dst),
                dH: CVPixelBufferGetHeight(dst),
                bpp: 4
            )
        }
        for p in 0..<planes {
            let sW = CVPixelBufferGetWidthOfPlane(src, p)
            let sH = CVPixelBufferGetHeightOfPlane(src, p)
            let dW = CVPixelBufferGetWidthOfPlane(dst, p)
            let dH = CVPixelBufferGetHeightOfPlane(dst, p)
            let bpp = p == 0 ? 1 : 2
            if !scaleBytes(
                src: CVPixelBufferGetBaseAddressOfPlane(src, p),
                sRow: CVPixelBufferGetBytesPerRowOfPlane(src, p),
                sW: sW,
                sH: sH,
                dst: CVPixelBufferGetBaseAddressOfPlane(dst, p),
                dRow: CVPixelBufferGetBytesPerRowOfPlane(dst, p),
                dW: dW,
                dH: dH,
                bpp: bpp
            ) {
                return false
            }
        }
        return true
    }

    private func scaleBytes(
        src: UnsafeMutableRawPointer?,
        sRow: Int,
        sW: Int,
        sH: Int,
        dst: UnsafeMutableRawPointer?,
        dRow: Int,
        dW: Int,
        dH: Int,
        bpp: Int
    ) -> Bool {
        guard let src, let dst, sW > 0, sH > 0, dW > 0, dH > 0, sRow >= sW * bpp, dRow >= dW * bpp else {
            return false
        }
        let sBase = src.assumingMemoryBound(to: UInt8.self)
        let dBase = dst.assumingMemoryBound(to: UInt8.self)
        if sW == dW, sH == dH, sRow == dRow {
            memcpy(dBase, sBase, sRow * sH)
            return true
        }
        for y in 0..<dH {
            let sy = min(sH - 1, y * sH / dH)
            let sLine = sBase.advanced(by: sy * sRow)
            let dLine = dBase.advanced(by: y * dRow)
            if sW == dW, bpp == 1 {
                memcpy(dLine, sLine, dW)
                continue
            }
            for x in 0..<dW {
                let sx = min(sW - 1, x * sW / dW)
                let sPix = sLine.advanced(by: sx * bpp)
                let dPix = dLine.advanced(by: x * bpp)
                for b in 0..<bpp {
                    dPix[b] = sPix[b]
                }
            }
        }
        return true
    }

    /// BGRA → NV12。videoRange 时 Y 落在 16...235，避免抖音按 limited 解出全黑。
    private func writeBGRA(_ src: CVPixelBuffer, into420 dst: CVPixelBuffer, videoRange: Bool) -> Bool {
        guard CVPixelBufferGetPlaneCount(dst) >= 2, CVPixelBufferGetPlaneCount(src) == 0 else { return false }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src)?.assumingMemoryBound(to: UInt8.self),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1)?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        let sW = CVPixelBufferGetWidth(src)
        let sH = CVPixelBufferGetHeight(src)
        let sRow = CVPixelBufferGetBytesPerRow(src)
        let dW = CVPixelBufferGetWidth(dst)
        let dH = CVPixelBufferGetHeight(dst)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let uvH = CVPixelBufferGetHeightOfPlane(dst, 1)
        let uvW = CVPixelBufferGetWidthOfPlane(dst, 1)
        guard sW > 1, sH > 1, dW > 1, dH > 1, uvH > 0, uvW > 0 else { return false }
        for y in 0..<dH {
            let sy = min(sH - 1, y * sH / dH)
            let sLine = sBase.advanced(by: sy * sRow)
            let yLine = yBase.advanced(by: y * yRow)
            for x in 0..<dW {
                let sx = min(sW - 1, x * sW / dW)
                let p = sLine.advanced(by: sx * 4)
                yLine[x] = luma(b: p[0], g: p[1], r: p[2], videoRange: videoRange)
            }
        }
        for y in 0..<uvH {
            let sy = min(sH - 1, (y * 2) * sH / dH)
            let sLine = sBase.advanced(by: sy * sRow)
            let uvLine = uvBase.advanced(by: y * uvRow)
            for x in 0..<uvW {
                let sx = min(sW - 1, (x * 2) * sW / dW)
                let p = sLine.advanced(by: sx * 4)
                let chroma = chroma(b: p[0], g: p[1], r: p[2])
                uvLine[x * 2] = chroma.0
                uvLine[x * 2 + 1] = chroma.1
            }
        }
        return true
    }

    private func write420(_ src: CVPixelBuffer, intoBGRA dst: CVPixelBuffer, videoRange: Bool) -> Bool {
        guard CVPixelBufferGetPlaneCount(src) >= 2, CVPixelBufferGetPlaneCount(dst) == 0 else { return false }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(src, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(src, 1)?.assumingMemoryBound(to: UInt8.self),
              let dBase = CVPixelBufferGetBaseAddress(dst)?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        let sW = CVPixelBufferGetWidth(src)
        let sH = CVPixelBufferGetHeight(src)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        let dW = CVPixelBufferGetWidth(dst)
        let dH = CVPixelBufferGetHeight(dst)
        let dRow = CVPixelBufferGetBytesPerRow(dst)
        guard sW > 1, sH > 1, dW > 1, dH > 1 else { return false }
        let bias = videoRange ? 16 : 0
        let scale = videoRange ? 255.0 / 219.0 : 1.0
        for y in 0..<dH {
            let sy = min(sH - 1, y * sH / dH)
            let yLine = yBase.advanced(by: sy * yRow)
            let uvLine = uvBase.advanced(by: (sy / 2) * uvRow)
            let dLine = dBase.advanced(by: y * dRow)
            for x in 0..<dW {
                let sx = min(sW - 1, x * sW / dW)
                let yy = Int(yLine[sx])
                let cb = Int(uvLine[(sx / 2) * 2]) - 128
                let cr = Int(uvLine[(sx / 2) * 2 + 1]) - 128
                let yv = (Double(yy - bias) * scale)
                var r = yv + 1.5748 * Double(cr)
                var g = yv - 0.1873 * Double(cb) - 0.4681 * Double(cr)
                var b = yv + 1.8556 * Double(cb)
                r = min(255, max(0, r))
                g = min(255, max(0, g))
                b = min(255, max(0, b))
                let p = dLine.advanced(by: x * 4)
                p[0] = UInt8(b)
                p[1] = UInt8(g)
                p[2] = UInt8(r)
                p[3] = 255
            }
        }
        return true
    }

    private func luma(b: UInt8, g: UInt8, r: UInt8, videoRange: Bool) -> UInt8 {
        let y = (66 * Int(r) + 129 * Int(g) + 25 * Int(b) + 128) >> 8
        if videoRange {
            return UInt8(min(235, max(16, y + 16)))
        }
        return UInt8(min(255, max(0, y)))
    }

    private func chroma(b: UInt8, g: UInt8, r: UInt8) -> (UInt8, UInt8) {
        let cb = ((-38 * Int(r) - 74 * Int(g) + 112 * Int(b) + 128) >> 8) + 128
        let cr = ((112 * Int(r) - 94 * Int(g) - 18 * Int(b) + 128) >> 8) + 128
        return (UInt8(min(255, max(0, cb))), UInt8(min(255, max(0, cr))))
    }
}
