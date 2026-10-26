import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ObjectiveC
import UIKit

/// 替换摄像头画面：在采集回调里把最新电脑帧画进 CMSampleBuffer。
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleVideoDataOutput()
        NSLog("BXFloatCam hooks installed")
    }

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
            if let delegate {
                wrapped = CamSampleBufferProxy(target: delegate)
            } else {
                wrapped = nil
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
            let call = unsafeBitCast(original, to: Fn.self)
            call(obj, sel, wrapped, queue)
        }
        let imp = imp_implementationWithBlock(block)
        method_setImplementation(method, imp)
    }
}

/// 转发原始 delegate，并在「替换摄像头」开启时改写像素。
final class CamSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var target: AnyObject?
    private let outputSel = #selector(AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didOutput:from:))
    private let dropSel = #selector(AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didDrop:from:))

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
        if MediaConfigStore.shared.config.replaceCameraEnabled {
            CamBufferPainter.paintIfPossible(into: sampleBuffer)
        }
        invokeOutput(on: target, output: output, sampleBuffer: sampleBuffer, connection: connection)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let target, target.responds(to: dropSel) else { return }
        invokeCapture(sel: dropSel, on: target, output: output, sampleBuffer: sampleBuffer, connection: connection)
    }

    private func invokeOutput(
        on target: AnyObject?,
        output: AVCaptureOutput,
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection
    ) {
        guard let target, target.responds(to: outputSel) else { return }
        invokeCapture(sel: outputSel, on: target, output: output, sampleBuffer: sampleBuffer, connection: connection)
    }

    private func invokeCapture(
        sel: Selector,
        on target: AnyObject,
        output: AVCaptureOutput,
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection
    ) {
        typealias Fn = @convention(c) (AnyObject, Selector, AVCaptureOutput, CMSampleBuffer, AVCaptureConnection) -> Void
        guard let cls: AnyClass = object_getClass(target) else { return }
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let call = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        call(target, sel, output, sampleBuffer, connection)
    }
}

enum CamBufferPainter {
    static func paintIfPossible(into sampleBuffer: CMSampleBuffer) {
        guard let src = CamFrameStore.shared.copyLatest() else { return }
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard sw > 0, sh > 0, dw > 0, dh > 0 else { return }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        // 尺寸一致：整帧拷贝（同格式时）
        if sw == dw, sh == dh,
           CVPixelBufferGetPixelFormatType(src) == CVPixelBufferGetPixelFormatType(dst)
        {
            let planes = CVPixelBufferGetPlaneCount(src)
            if planes == 0 {
                if let s = CVPixelBufferGetBaseAddress(src),
                   let d = CVPixelBufferGetBaseAddress(dst)
                {
                    let bytes = min(
                        CVPixelBufferGetDataSize(src),
                        CVPixelBufferGetDataSize(dst)
                    )
                    memcpy(d, s, bytes)
                }
                return
            }
            for p in 0..<planes {
                guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                      let d = CVPixelBufferGetBaseAddressOfPlane(dst, p)
                else { continue }
                let rows = CVPixelBufferGetHeightOfPlane(src, p)
                let sRow = CVPixelBufferGetBytesPerRowOfPlane(src, p)
                let dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
                let copyW = min(sRow, dRow)
                for r in 0..<rows {
                    memcpy(d.advanced(by: r * dRow), s.advanced(by: r * sRow), copyW)
                }
            }
            return
        }

        // 尺寸不同：用 CoreImage 缩放到目标
        let ciSrc = CIImage(cvPixelBuffer: src)
        let scaleX = CGFloat(dw) / CGFloat(sw)
        let scaleY = CGFloat(dh) / CGFloat(sh)
        let scaled = ciSrc.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        ctx.render(scaled, to: dst)
    }
}
