import AVFoundation
import CoreMedia
import CoreVideo
import ObjectiveC
import QuartzCore
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

/// 真替换（防冻帧版）：
/// - 采集回调里只做像素拷贝，禁止 CI / UIKit
/// - AVCaptureVideoDataOutput.sampleBufferDelegate 是弱引用 → 必须强持有 proxy，否则立刻释放 → 回调=0、画面冻死
/// - 关替换：先清 active 再 unwrap
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureVideoDataOutput>.weakObjects()
    /// key=output（弱），value=proxy（强）——修回调为 0 的根因
    private static let retainedProxies = NSMapTable<AVCaptureVideoDataOutput, CamSampleBufferProxy>.weakToStrongObjects()
    private static var replaceActive = false
    /// 上次确认在拍摄面的时间；用于录制过渡 sticky，并在离开相机后超时释放
    private static var lastCameraSeenAt: CFAbsoluteTime = 0
    private static let stickyAwaySec: CFAbsoluteTime = 4.0

    /// 替换期间专用回调队列：避免抖音把 sampleBuffer 派到主线程导致触摸卡死
    static let paintQueue = DispatchQueue(label: "bx.cam.paint", qos: .userInteractive)

    private(set) static var wrapCount: Int64 = 0
    private(set) static var callbackCount: Int64 = 0
    private(set) static var paintCount: Int64 = 0
    private(set) static var paintFailCount: Int64 = 0
    private(set) static var retainedProxyCount: Int = 0

    static func noteCallback() { callbackCount += 1 }
    static func notePaintOK() {
        paintCount += 1
        CamPipelineDiag.shared.noteVideoReplaceOK()
    }
    static func notePaintFail() {
        paintFailCount += 1
        CamPipelineDiag.shared.noteVideoReplaceFail()
    }

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
        NSLog("BXFloatCam hooks installed (true-replace memcpy-only)")
    }

    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        let now = CFAbsoluteTimeGetCurrent()

        // 先改标志：关的时候即使还没 unwrap，回调也立刻透传
        lock.lock()
        let wasActive = replaceActive
        if onCamera { lastCameraSeenAt = now }
        // 用户关替换才拆。录制过渡 !onCamera 短时 sticky；离开相机超时后释放，避免影响其它页。
        let want: Bool
        if !enabled {
            want = false
        } else if onCamera {
            want = true
        } else if wasActive, lastCameraSeenAt > 0, (now - lastCameraSeenAt) < stickyAwaySec {
            want = true
        } else {
            want = false
        }
        let sticky = enabled && !onCamera && want
        replaceActive = want
        lock.unlock()

        CamFrameBlitter.shared.setEnabled(want)
        PreviewCover.stop()

        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                // 不要派到抖音原 queue（常是 main）再 wrap；直接在 paintQueue 上挂代理
                paintQueue.async { ensureWrapped(output) }
            } else {
                unwrap(output)
            }
        }
        retainedProxyCount = retainedProxies.count
        NSLog(
            "BXFloatCam applyReplaceMode cfg=%d cam=%d sticky=%d active=%d tracked=%d retainProxy=%d paintOK=%lld fail=%lld",
            enabled ? 1 : 0,
            onCamera ? 1 : 0,
            sticky ? 1 : 0,
            want ? 1 : 0,
            outputs.count,
            retainedProxyCount,
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
            var finalQueue = queue
            if isReplaceActive(),
               let vout = obj as? AVCaptureVideoDataOutput,
               let delegate,
               !(delegate is CamSampleBufferProxy)
            {
                let proxy = CamSampleBufferProxy(target: delegate, originalQueue: queue)
                retainedProxies.setObject(proxy, forKey: vout)
                retainedProxyCount = retainedProxies.count
                finalDelegate = proxy
                finalQueue = paintQueue
                vout.alwaysDiscardsLateVideoFrames = true
                wrapCount += 1
                let onMain = (queue == nil) || (queue == DispatchQueue.main)
                NSLog(
                    "BXFloatCam wrap #%lld retain=%d origMain=%d %@",
                    wrapCount,
                    retainedProxyCount,
                    onMain ? 1 : 0,
                    String(describing: type(of: delegate))
                )
            }
            // 外部主动设回非 proxy 时，丢掉旧持有
            if let vout = obj as? AVCaptureVideoDataOutput,
               !(finalDelegate is CamSampleBufferProxy)
            {
                retainedProxies.removeObject(forKey: vout)
                retainedProxyCount = retainedProxies.count
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
            unsafeBitCast(original, to: Fn.self)(obj, sel, finalDelegate, finalQueue)
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
                    paintQueue.async { ensureWrapped(vout) }
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
                let cfg = MediaConfigStore.shared.config
                applyReplaceMode(cfg.replaceCameraEnabled)
                MicReplaceHooks.applyAudioMode(cfg.audioCaptureMode)
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
            // 仅清可见性缓存。不要在 stopRunning 里 apply*Mode：
            // 录制切换常先停预览会话，再启录像会话；中间 apply 会把 AU/代理拆掉。
            ShootSurfaceDetector.invalidateCache()
            NSLog("BXFloatCam session stopRunning (keep inject sticky until startRunning/apply)")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func ensureWrapped(_ output: AVCaptureVideoDataOutput) {
        track(output)
        guard isReplaceActive() else { return }
        output.alwaysDiscardsLateVideoFrames = true
        if let existing = output.sampleBufferDelegate as? CamSampleBufferProxy {
            retainedProxies.setObject(existing, forKey: output)
            retainedProxyCount = retainedProxies.count
            // 已是我们的 proxy 但队列可能仍被抖音改回 main：强制拉回 paintQueue
            if output.sampleBufferCallbackQueue !== paintQueue {
                BXFloatRestoreSampleBufferDelegate(output, existing, paintQueue)
            }
            return
        }
        // delegate 已是 nil：可能是上次弱引用把 proxy 放掉了，无法恢复原 target
        guard let delegate = output.sampleBufferDelegate else {
            NSLog("BXFloatCam ensureWrapped skip: delegate=nil (need re-enter camera page)")
            return
        }
        let origQ = output.sampleBufferCallbackQueue
        let proxy = CamSampleBufferProxy(target: delegate, originalQueue: origQ)
        retainedProxies.setObject(proxy, forKey: output) // 先强持有再 set
        retainedProxyCount = retainedProxies.count
        // 走 swizzle：最终挂到 paintQueue
        output.setSampleBufferDelegate(proxy, queue: paintQueue)
        wrapCount += 1
        NSLog(
            "BXFloatCam ensureWrapped retained=%d origMain=%d",
            retainedProxyCount,
            (origQ == nil || origQ === DispatchQueue.main) ? 1 : 0
        )
    }

    private static func unwrap(_ output: AVCaptureVideoDataOutput) {
        let proxy =
            (output.sampleBufferDelegate as? CamSampleBufferProxy)
            ?? retainedProxies.object(forKey: output)
        if let proxy {
            let queue = proxy.originalQueue ?? DispatchQueue.global(qos: .userInteractive)
            BXFloatRestoreSampleBufferDelegate(output, proxy.originalTarget, queue)
            NSLog("BXFloatCam unwrapped")
        }
        retainedProxies.removeObject(forKey: output)
        retainedProxyCount = retainedProxies.count
    }
}

final class CamSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let originalTarget: AnyObject
    let originalQueue: DispatchQueue?

    init(target: AnyObject, originalQueue: DispatchQueue?) {
        self.originalTarget = target
        self.originalQueue = originalQueue
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

    @objc(captureOutput:didOutputSampleBuffer:fromConnection:)
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        CameraReplaceHooks.noteCallback()
        let t0 = CACurrentMediaTime()
        let onMain = Thread.isMainThread
        // 替换开启时必须盖掉真机像素；超时则 hold 上一完整帧，禁止闪真机。
        if CameraReplaceHooks.isReplaceActive() {
            if CamBufferPainter.paintInPlace(sampleBuffer) {
                CameraReplaceHooks.notePaintOK()
            } else {
                CameraReplaceHooks.notePaintFail()
            }
        }
        let ms = (CACurrentMediaTime() - t0) * 1000.0
        CamPipelineDiag.shared.notePaintCost(ms: ms, onMain: onMain)
        // 必须在本回调内同步转发给原代理（sampleBuffer 返回后不可再用）
        BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
    }

    @objc(captureOutput:didDropSampleBuffer:fromConnection:)
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        BXFloatForwardDidDrop(originalTarget, output, sampleBuffer, connection)
    }
}

/// 采集回调专用：只拷贝像素，禁止 CI。
/// 失败时用上一成功帧或涂黑，绝不把真机画面交给下游。
enum CamBufferPainter {
    private static var loggedFormat = false
    private static let lock = NSLock()
    private static var lastGood: CVPixelBuffer?
    private static var lastGoodW = 0
    private static var lastGoodH = 0
    private static var lastGoodFmt: OSType = 0

    /// 单帧软预算：超时 hold 上一完整帧，避免主线程/回调队列积压卡触摸。
    private static let budgetSec: CFTimeInterval = 0.006

    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let t0 = CACurrentMediaTime()
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard dw > 0, dh > 0 else { return false }

        let fmt = CVPixelBufferGetPixelFormatType(dst)
        CamFrameBlitter.shared.noteTarget(width: dw, height: dh, format: fmt)

        if !loggedFormat {
            loggedFormat = true
            NSLog("BXFloatCam paint dstFormat=%u %dx%d (memcpy-only)", fmt, dw, dh)
        }

        // 1) 后台预渲染帧（最快、不碰 ring）
        if let prepared = CamFrameBlitter.shared.copyPrepared(
            width: dw, height: dh, format: fmt
        ), copyPixels(from: prepared, to: dst) {
            rememberGood(prepared, width: dw, height: dh, format: fmt)
            return true
        }

        // 2) 预算紧张或主线程：直接 hold 上一完整帧，禁止再扫 ring / 二次全幅拷贝
        let tight = Thread.isMainThread || (CACurrentMediaTime() - t0) > budgetSec * 0.4
        if tight {
            if let good = copyLastGood(width: dw, height: dh, format: fmt),
               copyPixels(from: good, to: dst)
            {
                return true
            }
            return fillBlack(dst)
        }

        // 3) 预渲染未就绪：同 mediaTime 取帧（禁止 copyLatest）
        let t = AVSyncClock.shared.mediaTime()
        if (CACurrentMediaTime() - t0) < budgetSec,
           let src = CamFrameStore.shared.copyForMediaTime(t),
           CVPixelBufferGetWidth(src) == dw,
           CVPixelBufferGetHeight(src) == dh,
           CVPixelBufferGetPixelFormatType(src) == fmt,
           copyPixels(from: src, to: dst)
        {
            rememberGood(src, width: dw, height: dh, format: fmt)
            return true
        }

        if let good = copyLastGood(width: dw, height: dh, format: fmt),
           copyPixels(from: good, to: dst)
        {
            return true
        }

        return fillBlack(dst)
    }

    private static func rememberGood(_ buf: CVPixelBuffer, width: Int, height: Int, format: OSType) {
        lock.lock()
        lastGood = buf
        lastGoodW = width
        lastGoodH = height
        lastGoodFmt = format
        lock.unlock()
    }

    private static func copyLastGood(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastGood,
              lastGoodW == width,
              lastGoodH == height,
              lastGoodFmt == format
        else { return nil }
        return lastGood
    }

    private static func fillBlack(_ dst: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        let planes = CVPixelBufferGetPlaneCount(dst)
        if planes == 0 {
            guard let base = CVPixelBufferGetBaseAddress(dst) else { return false }
            memset(base, 0, CVPixelBufferGetBytesPerRow(dst) * CVPixelBufferGetHeight(dst))
            return true
        }
        for p in 0..<planes {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return false }
            let rows = CVPixelBufferGetHeightOfPlane(dst, p)
            let row = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let fill: UInt8 = (p == 0) ? 0 : 128 // Y=0, UV=128 → 黑
            memset(base, Int32(fill), row * rows)
        }
        return true
    }

    private static func copyPixels(from src: CVPixelBuffer, to dst: CVPixelBuffer) -> Bool {
        let planes = CVPixelBufferGetPlaneCount(src)
        let dstPlanes = CVPixelBufferGetPlaneCount(dst)
        guard planes == dstPlanes else { return false }
        guard CVPixelBufferGetWidth(src) == CVPixelBufferGetWidth(dst),
              CVPixelBufferGetHeight(src) == CVPixelBufferGetHeight(dst),
              CVPixelBufferGetPixelFormatType(src) == CVPixelBufferGetPixelFormatType(dst)
        else { return false }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        if planes == 0 {
            guard let s = CVPixelBufferGetBaseAddress(src),
                  let d = CVPixelBufferGetBaseAddress(dst) else { return false }
            let rows = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
            let sRow = CVPixelBufferGetBytesPerRow(src)
            let dRow = CVPixelBufferGetBytesPerRow(dst)
            let n = min(sRow, dRow)
            for y in 0..<rows {
                memcpy(d.advanced(by: y * dRow), s.advanced(by: y * sRow), n)
            }
            return true
        }

        for p in 0..<planes {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return false }
            let rows = min(
                CVPixelBufferGetHeightOfPlane(src, p),
                CVPixelBufferGetHeightOfPlane(dst, p)
            )
            let sRow = CVPixelBufferGetBytesPerRowOfPlane(src, p)
            let dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let n = min(sRow, dRow)
            for y in 0..<rows {
                memcpy(d.advanced(by: y * dRow), s.advanced(by: y * sRow), n)
            }
        }
        return true
    }
}

@_cdecl("BXFloatInstallCameraHooks")
public func BXFloatInstallCameraHooks() {
    CameraReplaceHooks.installIfNeeded()
}
