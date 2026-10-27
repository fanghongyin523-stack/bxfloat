import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ObjectiveC
import UIKit

/// 替换摄像头画面（对标 aux 思路）：
/// 1) 尽早 swizzle setSampleBufferDelegate
/// 2) 再 hook addOutput / startRunning，把已经挂上的 delegate 重新包一层
/// 3) 不要改只读相机帧，而是新建 CMSampleBuffer 再交给原回调
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()

    private(set) static var wrapCount: Int64 = 0
    private(set) static var callbackCount: Int64 = 0
    private(set) static var paintCount: Int64 = 0
    private(set) static var paintFailCount: Int64 = 0

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else {
            rewrapRunningSessions()
            return
        }
        installed = true
        swizzleVideoDataOutput()
        swizzleSessionAddOutput()
        swizzleSessionStartRunning()
        NSLog("BXFloatCam hooks installed")
        // 相机可能已启动：延迟再扫几次
        DispatchQueue.main.async {
            rewrapRunningSessions()
        }
        for sec in [1, 2, 4, 8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sec)) {
                rewrapRunningSessions()
            }
        }
    }

    // MARK: - Swizzles

    private static func swizzleVideoDataOutput() {
        let cls: AnyClass = AVCaptureVideoDataOutput.self
        let sel = NSSelectorFromString("setSampleBufferDelegate:queue:")
        guard let method = class_getInstanceMethod(cls, sel) else {
            NSLog("BXFloatCam missing setSampleBufferDelegate")
            return
        }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?, DispatchQueue?) -> Void = { obj, delegate, queue in
            let wrapped: AnyObject?
            if let delegate, !(delegate is CamSampleBufferProxy) {
                wrapped = CamSampleBufferProxy(target: delegate)
                wrapCount += 1
                NSLog("BXFloatCam wrap delegate #%lld %@", wrapCount, String(describing: type(of: delegate)))
            } else {
                wrapped = delegate
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, wrapped, queue)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionAddOutput() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("addOutput:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { session, output in
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel, output)
            if let vout = output as? AVCaptureVideoDataOutput {
                DispatchQueue.main.async {
                    rewrap(output: vout)
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
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
            DispatchQueue.main.async {
                rewrapRunningSessions()
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// 通过 KVC / runtime 尽量找到已有 VideoDataOutput 并重设 delegate（走我们的 swizzle）
    static func rewrapRunningSessions() {
        // 扫描常见持有：UIApplication windows 下不一定有 session。
        // 用 objc 关联：对所有 AVCaptureVideoDataOutput 实例无法直接枚举。
        // 折中：若宿主把 session 挂在通知/单例上不可靠；依赖 addOutput/startRunning。
        // 再补：尝试从当前 key window 的 responder 链拿不到。
        // 这里额外 hook 已存在的 output：通过 _output 不可行。
        // 实用做法：用户开替换后，提示重进拍摄页；同时我们在 startRunning 时 rewrap。
        NSLog(
            "BXFloatCam rewrap tick wrap=%lld cb=%lld paint=%lld fail=%lld frames=%lld",
            wrapCount, callbackCount, paintCount, paintFailCount, CamFrameStore.shared.frameCount
        )
    }

    fileprivate static func rewrap(output: AVCaptureVideoDataOutput) {
        guard let delegate = output.sampleBufferDelegate else { return }
        if delegate is CamSampleBufferProxy { return }
        let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
        // 再 set 一次，触发 swizzle 包装
        output.setSampleBufferDelegate(nil, queue: nil)
        output.setSampleBufferDelegate(delegate, queue: queue)
        NSLog("BXFloatCam rewrap existing output")
    }

    fileprivate static func noteCallback() { callbackCount += 1 }
    fileprivate static func notePaintOK() { paintCount += 1 }
    fileprivate static func notePaintFail() { paintFailCount += 1 }
}

/// 转发原 delegate；替换开启时用「新 sampleBuffer」替换相机帧。
final class CamSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var target: AnyObject?
    private let outputSel = #selector(
        AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didOutput:from:)
    )
    private let dropSel = #selector(
        AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didDrop:from:)
    )

    init(target: AnyObject) {
        self.target = target
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return target?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let target, target.responds(to: aSelector) { return target }
        return super.forwardingTarget(for: aSelector)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        CameraReplaceHooks.noteCallback()
        var forward = sampleBuffer
        if MediaConfigStore.shared.config.replaceCameraEnabled {
            if let replaced = CamBufferPainter.makeReplacing(sampleBuffer) {
                forward = replaced
                CameraReplaceHooks.notePaintOK()
            } else {
                CameraReplaceHooks.notePaintFail()
            }
        }
        invokeCapture(sel: outputSel, on: target, output: output, sampleBuffer: forward, connection: connection)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        invokeCapture(sel: dropSel, on: target, output: output, sampleBuffer: sampleBuffer, connection: connection)
    }

    private func invokeCapture(
        sel: Selector,
        on target: AnyObject?,
        output: AVCaptureOutput,
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection
    ) {
        guard let target, target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AVCaptureOutput, CMSampleBuffer, AVCaptureConnection
        ) -> Void
        guard let cls: AnyClass = object_getClass(target) else { return }
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(
            target, sel, output, sampleBuffer, connection
        )
    }
}

enum CamBufferPainter {
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// 新建与相机帧同尺寸/格式的 buffer，画入电脑画面，再包成 CMSampleBuffer。
    static func makeReplacing(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let src = CamFrameStore.shared.copyLatest() else { return nil }
        guard let dstProto = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let dw = CVPixelBufferGetWidth(dstProto)
        let dh = CVPixelBufferGetHeight(dstProto)
        guard dw > 0, dh > 0 else { return nil }

        // 统一输出 BGRA：CI 可靠写入；整帧替换 sampleBuffer 时多数链路可接受
        let format = kCVPixelFormatType_32BGRA
        var newPB: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            dw,
            dh,
            format,
            attrs as CFDictionary,
            &newPB
        )
        guard status == kCVReturnSuccess, let newPB else { return nil }

        let ciSrc = CIImage(cvPixelBuffer: src)
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        guard sw > 0, sh > 0 else { return nil }
        let scaled = ciSrc.transformed(
            by: CGAffineTransform(scaleX: CGFloat(dw) / sw, y: CGFloat(dh) / sh)
        )
        let bounds = CGRect(x: 0, y: 0, width: dw, height: dh)
        ci.render(scaled, to: newPB, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())

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
        guard err == noErr else { return nil }
        return out
    }
}

/// 供 ObjC constructor 尽早调用
@_cdecl("BXFloatInstallCameraHooks")
public func BXFloatInstallCameraHooks() {
    CameraReplaceHooks.installIfNeeded()
}
