import CoreImage
import CoreVideo
import Foundation

/// 后台按采集格式预渲染；失败时保留上一帧，避免闪回真机摄像头。
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
        lock.lock()
        defer { lock.unlock() }
        guard let prepared else { return nil }
        if prepW == width, prepH == height, prepFmt == format {
            return prepared
        }
        // 目标格式尚未对齐时，先别返回错误尺寸（避免花屏）；返回 nil 让上层再用 latest 路径
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

    private func prepareIfNeeded(width: Int, height: Int, format: OSType) {
        let store = CamFrameStore.shared
        guard store.hasFreshFrame else { return }
        let mediaT = AVSyncClock.shared.mediaTime()
        guard let src = store.copyForMediaTime(mediaT) ?? store.copyLatest() else { return }

        // 约每帧更新；同一档不重复渲
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
            ) == kCVReturnSuccess, let dst else {
                // 转换失败：至少把 BGRA 存上（若目标恰好能用）或保留旧 prepared
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
