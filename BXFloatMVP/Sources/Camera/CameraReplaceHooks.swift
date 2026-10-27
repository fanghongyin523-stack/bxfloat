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

/// 摄像头替换钩子。
/// - 关替换：必须拆掉 proxy，且绝不改 videoSettings（改格式是真机黑屏主因）
/// - 开替换：原地把推流画进原 CVPixelBuffer，保留同一 CMSampleBuffer（抖音依赖附件/格式）
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureVideoDataOutput>.weakObjects()
    /// 配置开替换且当前在摄像页时才包装
    private static var replaceActive = false

    private(set) static var wrapCount: Int64 = 0
    private(set) static var callbackCount: Int64 = 0
    private(set) static var paintCount: Int64 = 0
    private(set) static var paintFailCount: Int64 = 0

    static func noteCallback() { callbackCount += 1 }
    static func notePaintOK() { paintCount += 1 }
    static func notePaintFail() { paintFailCount += 1 }

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleVideoDataOutput()
        swizzleSessionAddOutput()
        swizzleSessionStartRunning()
        swizzleSessionStopRunning()
        NSLog("BXFloatCam hooks installed")
    }

    /// `enabled` = 配置里的「替换摄像头」；内部再结合摄像页决定是否包装。
    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        let want = enabled && onCamera
        let was = replaceActive
        replaceActive = want
        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                ensureWrapped(output)
            } else {
                unwrap(output)
            }
        }
        if was != want || !want {
            NSLog(
                "BXFloatCam applyReplaceMode cfg=%d cam=%d active=%d tracked=%d paintOK=%lld fail=%lld cb=%lld",
                enabled ? 1 : 0,
                onCamera ? 1 : 0,
                want ? 1 : 0,
                outputs.count,
                paintCount,
                paintFailCount,
                callbackCount
            )
        }
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
            // 仅摄像页 + 开替换时包装；否则原样，保证真镜头通路
            if replaceActive,
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
                if replaceActive {
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
                if !ShootSurfaceDetector.isCameraSurfaceVisible() {
                    PreviewCover.stop()
                }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func ensureWrapped(_ output: AVCaptureVideoDataOutput) {
        track(output)
        // 故意不改 videoSettings：强改 BGRA 会弄崩抖音美颜/预览，关替换后仍黑屏
        guard let delegate = output.sampleBufferDelegate else { return }
        if delegate is CamSampleBufferProxy { return }
        let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
        let proxy = CamSampleBufferProxy(target: delegate)
        output.setSampleBufferDelegate(proxy, queue: queue)
        wrapCount += 1
        NSLog("BXFloatCam ensureWrapped (no videoSettings touch)")
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
    /// 必须强引用！weak 会导致原 delegate 释放 → 真机摄像头黑屏
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
        // 关替换或离开摄像页：100% 原帧透传
        guard MediaConfigStore.shared.config.replaceCameraEnabled,
              ShootSurfaceDetector.isCameraSurfaceVisible()
        else {
            BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
            return
        }
        // 原地绘制成功则仍转发「同一个」sampleBuffer（像素已被替换）
        if CamBufferPainter.paintInPlace(sampleBuffer) {
            CameraReplaceHooks.notePaintOK()
        } else {
            CameraReplaceHooks.notePaintFail()
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

    /// 把推流画进采集缓冲的像素里，不新建 CMSampleBuffer（保留格式与附件）。
    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CamFrameStore.shared.hasFreshFrame,
              let src = CamFrameStore.shared.copyLatest() else { return false }
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }

        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard dw > 0, dh > 0 else { return false }

        let fmt = CVPixelBufferGetPixelFormatType(dst)
        if !loggedFormat {
            loggedFormat = true
            NSLog("BXFloatCam paint dstFormat=%u %dx%d", fmt, dw, dh)
        }

        let ciSrc = CIImage(cvPixelBuffer: src)
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        guard sw > 0, sh > 0 else { return false }

        let scale = max(CGFloat(dw) / sw, CGFloat(dh) / sh)
        let scaled = ciSrc.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropped = scaled.cropped(
            to: CGRect(
                x: (scaled.extent.width - CGFloat(dw)) / 2,
                y: (scaled.extent.height - CGFloat(dh)) / 2,
                width: CGFloat(dw),
                height: CGFloat(dh)
            )
        )
        let placed = cropped.transformed(
            by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        )
        let bounds = CGRect(x: 0, y: 0, width: dw, height: dh)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 优先直接渲到目标缓冲（BGRA / 部分 YUV 可用）
        if canRenderDirectly(fmt) {
            ci.render(placed, to: dst, bounds: bounds, colorSpace: colorSpace)
            return true
        }

        // 其它格式：先渲到临时 BGRA，再经 CI 写入目标（尽量保原格式）
        var tmp: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault, dw, dh, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &tmp
        )
        guard st == kCVReturnSuccess, let tmp else { return false }
        ci.render(placed, to: tmp, bounds: bounds, colorSpace: colorSpace)
        let tmpImage = CIImage(cvPixelBuffer: tmp)
        ci.render(tmpImage, to: dst, bounds: bounds, colorSpace: colorSpace)
        return true
    }

    private static func canRenderDirectly(_ fmt: OSType) -> Bool {
        switch fmt {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_32RGBA,
             kCVPixelFormatType_64RGBAHalf,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    /// 兼容旧调用名（已不再新建 sample）
    static func makeReplacing(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        paintInPlace(sampleBuffer) ? sampleBuffer : nil
    }
}

@_cdecl("BXFloatInstallCameraHooks")
public func BXFloatInstallCameraHooks() {
    CameraReplaceHooks.installIfNeeded()
}
