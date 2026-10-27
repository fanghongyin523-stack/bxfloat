import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ObjectiveC
import UIKit

@_silgen_name("BXFloatForwardDidOutput")
func BXFloatForwardDidOutput(
    _ target: AnyObject?,
    _ output: AVCaptureOutput,
    _ sampleBuffer: CMSampleBuffer,
    _ connection: AVCaptureConnection
)

@_silgen_name("BXFloatForwardDidDrop")
func BXFloatForwardDidDrop(
    _ target: AnyObject?,
    _ output: AVCaptureOutput,
    _ sampleBuffer: CMSampleBuffer,
    _ connection: AVCaptureConnection
)

@_silgen_name("BXFloatRestoreSampleBufferDelegate")
func BXFloatRestoreSampleBufferDelegate(
    _ output: AVCaptureVideoDataOutput,
    _ delegate: AnyObject?,
    _ queue: DispatchQueue?
)

/// 真替换：包装 sample 回调，把推流画进采集缓冲；抖音 UI 仍在预览层之上，按钮可点。
/// 规则：回调里绝不碰 UIKit；不改 videoSettings；重活在 CamFrameBlitter 后台做。
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureVideoDataOutput>.weakObjects()

    /// 采集回调只读这个标志（加锁），禁止扫视图树。
    private static var replaceActive = false

    private(set) static var wrapCount: Int64 = 0
    private(set) static var callbackCount: Int64 = 0
    private(set) static var paintCount: Int64 = 0
    private(set) static var paintFailCount: Int64 = 0

    static func noteCallback() { callbackCount += 1 }
    static func notePaintOK() { paintCount += 1 }
    static func notePaintFail() { paintFailCount += 1 }

    static func isReplaceActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return replaceActive
    }

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleVideoDataOutput()
        swizzleSessionAddOutput()
        swizzleSessionStartRunning()
        swizzleSessionStopRunning()
        NSLog("BXFloatCam hooks installed (true-replace)")
    }

    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        let want = enabled && onCamera

        lock.lock()
        replaceActive = want
        lock.unlock()

        CamFrameBlitter.shared.setEnabled(want)
        // 真替换不再用盖层窗（盖层会挡住开播按钮/标题）
        PreviewCover.stop()

        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                ensureWrapped(output)
            } else {
                unwrap(output)
            }
        }
        NSLog(
            "BXFloatCam applyReplaceMode cfg=%d cam=%d active=%d tracked=%d paintOK=%lld fail=%lld",
            enabled ? 1 : 0,
            onCamera ? 1 : 0,
            want ? 1 : 0,
            outputs.count,
            paintCount,
            paintFailCount
        )
    }

    private static func track(_ output: AVCaptureVideoDataOutput) {
        trackedOutputs.add(output)
    }

    private static func swizzleVideoDataOutput() {
        let cls: AnyClass = AVCaptureVideoDataOutput.self
        let sel = NSSelectorFromString("setSampleBufferDelegate:queue:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?, DispatchQueue?) -> Void = { obj, delegate, queue in
            if let vout = obj as? AVCaptureVideoDataOutput {
                track(vout)
            }
            var finalDelegate = delegate
            if isReplaceActive(),
               let delegate,
               !(delegate is CamSampleBufferProxy)
            {
                finalDelegate = CamSampleBufferProxy(target: delegate)
                wrapCount += 1
                NSLog("BXFloatCam wrap #%lld %@", wrapCount, String(describing: type(of: delegate)))
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, finalDelegate, queue)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionAddOutput() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("addOutput:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { session, output in
            if let s = session as? AVCaptureSession {
                ShootSurfaceDetector.trackSession(s)
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel, output)
            if let vout = output as? AVCaptureVideoDataOutput {
                track(vout)
                if isReplaceActive() {
                    DispatchQueue.main.async { ensureWrapped(vout) }
                }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionStartRunning() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("startRunning")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            if let s = session as? AVCaptureSession {
                ShootSurfaceDetector.trackSession(s)
            }
            ShootSurfaceDetector.invalidateCache()
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
            DispatchQueue.main.async {
                applyReplaceMode(MediaConfigStore.shared.config.replaceCameraEnabled)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionStopRunning() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("stopRunning")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
            ShootSurfaceDetector.invalidateCache()
            DispatchQueue.main.async {
                applyReplaceMode(MediaConfigStore.shared.config.replaceCameraEnabled)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func ensureWrapped(_ output: AVCaptureVideoDataOutput) {
        track(output)
        // 不改 videoSettings
        guard let delegate = output.sampleBufferDelegate else { return }
        if delegate is CamSampleBufferProxy { return }
        let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
        let proxy = CamSampleBufferProxy(target: delegate)
        output.setSampleBufferDelegate(proxy, queue: queue)
        wrapCount += 1
        NSLog("BXFloatCam ensureWrapped")
    }

    private static func unwrap(_ output: AVCaptureVideoDataOutput) {
        if let proxy = output.sampleBufferDelegate as? CamSampleBufferProxy {
            let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
            BXFloatRestoreSampleBufferDelegate(output, proxy.originalTarget, queue)
            NSLog("BXFloatCam unwrapped")
        }
    }
}

final class CamSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let originalTarget: AnyObject

    init(target: AnyObject) {
        self.originalTarget = target
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalTarget.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalTarget.responds(to: aSelector) { return originalTarget }
        return super.forwardingTarget(for: aSelector)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        CameraReplaceHooks.noteCallback()
        // 只看原子开关；禁止在此扫 UIKit
        if CameraReplaceHooks.isReplaceActive() {
            if CamBufferPainter.paintInPlace(sampleBuffer) {
                CameraReplaceHooks.notePaintOK()
            } else {
                CameraReplaceHooks.notePaintFail()
            }
        }
        BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        BXFloatForwardDidDrop(originalTarget, output, sampleBuffer, connection)
    }
}

enum CamBufferPainter {
    private static let ci = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])
    private static var loggedFormat = false

    /// 把预缩放帧写入采集缓冲；同一 CMSampleBuffer 原样转发。
    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard dw > 0, dh > 0 else { return false }

        let fmt = CVPixelBufferGetPixelFormatType(dst)
        CamFrameBlitter.shared.noteTarget(width: dw, height: dh)

        if !loggedFormat {
            loggedFormat = true
            NSLog("BXFloatCam paint dstFormat=%u %dx%d", fmt, dw, dh)
        }

        // 优先用后台预缩放好的 BGRA
        if let prepared = CamFrameBlitter.shared.copyPrepared(width: dw, height: dh) {
            return blit(prepared, into: dst, format: fmt, width: dw, height: dh)
        }

        // 预缩放还没好：直接从 store 画一帧（可能稍慢，仅兜底）
        guard CamFrameStore.shared.hasFreshFrame,
              let src = CamFrameStore.shared.copyLatest() else { return false }
        return render(src, into: dst, width: dw, height: dh)
    }

    private static func blit(
        _ src: CVPixelBuffer,
        into dst: CVPixelBuffer,
        format: OSType,
        width: Int,
        height: Int
    ) -> Bool {
        if format == kCVPixelFormatType_32BGRA {
            return copyBGRA(src, to: dst)
        }
        // YUV 等：CI 一次写入（源已是目标尺寸，比整链路缩放轻）
        let image = CIImage(cvPixelBuffer: src)
        ci.render(
            image,
            to: dst,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return true
    }

    private static func copyBGRA(_ src: CVPixelBuffer, to dst: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return false }
        let sh = CVPixelBufferGetHeight(src)
        let dh = CVPixelBufferGetHeight(dst)
        let rows = min(sh, dh)
        let sRow = CVPixelBufferGetBytesPerRow(src)
        let dRow = CVPixelBufferGetBytesPerRow(dst)
        let sW = CVPixelBufferGetWidth(src)
        let dW = CVPixelBufferGetWidth(dst)
        let bytes = min(sW, dW) * 4
        for y in 0..<rows {
            memcpy(d.advanced(by: y * dRow), s.advanced(by: y * sRow), bytes)
        }
        return true
    }

    private static func render(
        _ src: CVPixelBuffer,
        into dst: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> Bool {
        let ciSrc = CIImage(cvPixelBuffer: src)
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        guard sw > 1, sh > 1 else { return false }
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
            to: dst,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return true
    }
}

@_cdecl("BXFloatInstallCameraHooks")
public func BXFloatInstallCameraHooks() {
    CameraReplaceHooks.installIfNeeded()
}
