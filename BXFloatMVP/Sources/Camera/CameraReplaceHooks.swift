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

private var bxSavedVideoSettingsKey: UInt8 = 0

/// 摄像头替换钩子。
/// 关替换：还原 delegate + videoSettings，原样透传，避免黑屏。
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureVideoDataOutput>.weakObjects()
    /// 配置开关且当前在摄像页时才真正包装
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

    /// enabled=配置开替换；内部再结合摄像页决定是否包装。
    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        let want = enabled && onCamera
        replaceActive = want
        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                ensureWrapped(output)
            } else {
                unwrap(output)
            }
        }
        NSLog(
            "BXFloatCam applyReplaceMode cfg=%d cam=%d active=%d tracked=%d",
            enabled ? 1 : 0,
            onCamera ? 1 : 0,
            want ? 1 : 0,
            outputs.count
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
                // 进摄像页：若配置开了替换再包装
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
                // 会话停后按当前页面重算；离开摄像页会拆包装并停盖层
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
        preferBGRA(output)
        guard let delegate = output.sampleBufferDelegate else { return }
        if delegate is CamSampleBufferProxy { return }
        let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
        let proxy = CamSampleBufferProxy(target: delegate)
        output.setSampleBufferDelegate(proxy, queue: queue)
        wrapCount += 1
        NSLog("BXFloatCam ensureWrapped")
    }

    private static func unwrap(_ output: AVCaptureVideoDataOutput) {
        restoreVideoSettings(output)
        if let proxy = output.sampleBufferDelegate as? CamSampleBufferProxy {
            let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
            BXFloatRestoreSampleBufferDelegate(output, proxy.originalTarget, queue)
            NSLog("BXFloatCam unwrapped")
        }
    }

    private static func preferBGRA(_ output: AVCaptureVideoDataOutput) {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        let want = Int(kCVPixelFormatType_32BGRA)
        if objc_getAssociatedObject(output, &bxSavedVideoSettingsKey) == nil {
            // 保存原始 settings；nil 用 NSNull 占位，unwrap 时还原成 nil
            let saved: Any = (output.videoSettings as NSDictionary?) ?? NSNull()
            objc_setAssociatedObject(
                output,
                &bxSavedVideoSettingsKey,
                saved,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        if let cur = output.videoSettings?[key] as? Int, cur == want { return }
        output.videoSettings = [key: want]
    }

    private static func restoreVideoSettings(_ output: AVCaptureVideoDataOutput) {
        guard let saved = objc_getAssociatedObject(output, &bxSavedVideoSettingsKey) else { return }
        if saved is NSNull {
            output.videoSettings = nil
        } else if let dict = saved as? [String: Any] {
            output.videoSettings = dict
        } else if let dict = saved as? NSDictionary {
            output.videoSettings = dict as? [String: Any]
        }
        objc_setAssociatedObject(output, &bxSavedVideoSettingsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        NSLog("BXFloatCam restored videoSettings")
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
        // 关替换：100% 原帧透传
        guard MediaConfigStore.shared.config.replaceCameraEnabled,
              ShootSurfaceDetector.isCameraSurfaceVisible()
        else {
            BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
            return
        }
        var forward = sampleBuffer
        if let replaced = CamBufferPainter.makeReplacing(sampleBuffer) {
            forward = replaced
            CameraReplaceHooks.notePaintOK()
        } else {
            CameraReplaceHooks.notePaintFail()
            // 画失败时仍送原帧，避免整页黑
        }
        BXFloatForwardDidOutput(originalTarget, output, forward, connection)
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

    static func makeReplacing(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard CamFrameStore.shared.hasFreshFrame,
              let src = CamFrameStore.shared.copyLatest() else { return nil }
        guard let dstProto = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let dw = CVPixelBufferGetWidth(dstProto)
        let dh = CVPixelBufferGetHeight(dstProto)
        guard dw > 0, dh > 0 else { return nil }

        var newPB: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, dw, dh, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &newPB
        )
        guard status == kCVReturnSuccess, let newPB else { return nil }

        let ciSrc = CIImage(cvPixelBuffer: src)
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        guard sw > 0, sh > 0 else { return nil }
        let sx = CGFloat(dw) / sw
        let sy = CGFloat(dh) / sh
        let scale = max(sx, sy)
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
        ci.render(
            placed,
            to: newPB,
            bounds: CGRect(x: 0, y: 0, width: dw, height: dh),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: newPB,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return nil }
        var out: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: newPB,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        return err == noErr ? out : nil
    }
}

@_cdecl("BXFloatInstallCameraHooks")
public func BXFloatInstallCameraHooks() {
    CameraReplaceHooks.installIfNeeded()
}
