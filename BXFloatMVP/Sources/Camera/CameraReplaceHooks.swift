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
    /// stopRunning 后保持注入直到 startRunning/回到拍摄面；与离开相机 4s TTL 分开，不靠拉长 TTL
    private static var pauseSticky = false
    private static var pauseStickyAt: CFAbsoluteTime = 0
    private static let pauseStickyMaxSec: CFAbsoluteTime = 180.0
    private static var resumeFirstFramePending = false

    /// 仅当抖音原回调是 main/nil 时改挂此队列，避免触摸卡死；非 main 原队列保持不动
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
        _ = CamPipelineDiag.shared // 启动主线程卡顿看门狗 + 自动落盘
        NSLog("BXFloatCam hooks installed (true-replace memcpy-only)")
    }

    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        let now = CFAbsoluteTimeGetCurrent()

        // 先改标志：关的时候即使还没 unwrap，回调也立刻透传
        lock.lock()
        let wasActive = replaceActive
        if onCamera {
            lastCameraSeenAt = now
            if pauseSticky {
                pauseSticky = false
                resumeFirstFramePending = true
            }
        }
        // 用户关替换才拆。pauseSticky=会话暂停/切换；离开相机仍用 4s TTL（不拉长）。
        let want: Bool
        if !enabled {
            want = false
            pauseSticky = false
            resumeFirstFramePending = false
        } else if onCamera {
            want = true
        } else if pauseSticky, (now - pauseStickyAt) < pauseStickyMaxSec {
            want = true
        } else if wasActive, lastCameraSeenAt > 0, (now - lastCameraSeenAt) < stickyAwaySec {
            want = true
        } else {
            want = false
            pauseSticky = false
        }
        let sticky = enabled && !onCamera && want
        let pause = pauseSticky
        replaceActive = want
        lock.unlock()

        CamFrameBlitter.shared.setEnabled(want)
        PreviewCover.stop()

        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                // 在 paintQueue 上 wrap，避免占主线程；最终回调队列见 preferCallbackQueue
                paintQueue.async { ensureWrapped(output) }
            } else {
                unwrap(output)
            }
        }
        retainedProxyCount = retainedProxies.count
        CamPipelineDiag.shared.noteSessionEvent(
            "applyReplace cfg=\(enabled ? 1 : 0) cam=\(onCamera ? 1 : 0) sticky=\(sticky ? 1 : 0) pause=\(pause ? 1 : 0) active=\(want ? 1 : 0)"
        )
        NSLog(
            "BXFloatCam applyReplaceMode cfg=%d cam=%d sticky=%d pause=%d active=%d tracked=%d retainProxy=%d paintOK=%lld fail=%lld",
            enabled ? 1 : 0,
            onCamera ? 1 : 0,
            sticky ? 1 : 0,
            pause ? 1 : 0,
            want ? 1 : 0,
            outputs.count,
            retainedProxyCount,
            paintCount,
            paintFailCount
        )
    }

    /// main/nil → paintQueue；否则保留抖音原队列，保证转发线程符合其设定
    private static func preferCallbackQueue(_ original: DispatchQueue?) -> DispatchQueue {
        if let original, original !== DispatchQueue.main {
            return original
        }
        return paintQueue
    }

    static func noteResumeFirstFrameIfNeeded(onMain: Bool, paintMs: Double) {
        lock.lock()
        let pending = resumeFirstFramePending
        if pending { resumeFirstFramePending = false }
        lock.unlock()
        guard pending else { return }
        CamPipelineDiag.shared.noteSessionEvent(
            String(format: "resumeFirstFrame onMain=%d paintMs=%.1f", onMain ? 1 : 0, paintMs)
        )
    }

    static func markPauseStickyFromStopRunning() {
        lock.lock()
        if replaceActive {
            pauseSticky = true
            pauseStickyAt = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()
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
                finalQueue = preferCallbackQueue(queue)
                vout.alwaysDiscardsLateVideoFrames = true
                wrapCount += 1
                let onMain = (queue == nil) || (queue == DispatchQueue.main)
                let usedPaint = finalQueue === paintQueue
                CamPipelineDiag.shared.noteSessionEvent(
                    "wrap origMain=\(onMain ? 1 : 0) usedPaintQ=\(usedPaint ? 1 : 0) \(String(describing: type(of: delegate)))"
                )
                NSLog(
                    "BXFloatCam wrap #%lld retain=%d origMain=%d usedPaintQ=%d %@",
                    wrapCount,
                    retainedProxyCount,
                    onMain ? 1 : 0,
                    usedPaint ? 1 : 0,
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
            let onMain = Thread.isMainThread
            // 必须同步调用原实现：异步会破坏抖音暂停/继续的 stop→start 时序（isRunning 竞态）。
            CamPipelineDiag.shared.noteSessionEvent("startRunning begin onMain=\(onMain ? 1 : 0) sync=1")
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let t0 = CACurrentMediaTime()
            unsafeBitCast(original, to: Fn.self)(session, sel)
            let ms = (CACurrentMediaTime() - t0) * 1000.0
            CamPipelineDiag.shared.noteSessionEvent(
                String(format: "startRunning done ms=%.0f onMain=%d", ms, onMain ? 1 : 0)
            )
            // apply 仍异步，避免在启停路径上做 wrap/锁
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
            let onMain = Thread.isMainThread
            CamPipelineDiag.shared.noteSessionEvent("stopRunning begin onMain=\(onMain ? 1 : 0) sync=1")
            markPauseStickyFromStopRunning()
            MicReplaceHooks.markPauseStickyFromStopRunning()
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let t0 = CACurrentMediaTime()
            // 同步 stop：禁止 async，否则继续录制时 start 可能跑在 stop 完成前
            unsafeBitCast(original, to: Fn.self)(session, sel)
            let ms = (CACurrentMediaTime() - t0) * 1000.0
            ShootSurfaceDetector.invalidateCache()
            CamPipelineDiag.shared.noteSessionEvent(
                String(format: "stopRunning done ms=%.0f pauseSticky=1", ms)
            )
            NSLog("BXFloatCam session stopRunning sync (pauseSticky until startRunning/apply)")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func ensureWrapped(_ output: AVCaptureVideoDataOutput) {
        track(output)
        guard isReplaceActive() else { return }
        output.alwaysDiscardsLateVideoFrames = true
        let desiredQ: DispatchQueue = {
            if let existing = output.sampleBufferDelegate as? CamSampleBufferProxy {
                return preferCallbackQueue(existing.originalQueue)
            }
            return preferCallbackQueue(output.sampleBufferCallbackQueue)
        }()
        if let existing = output.sampleBufferDelegate as? CamSampleBufferProxy {
            retainedProxies.setObject(existing, forKey: output)
            retainedProxyCount = retainedProxies.count
            // 原是 main 却被改回 main：拉回 paintQueue；非 main 则保持其原队列
            if output.sampleBufferCallbackQueue !== desiredQ {
                BXFloatRestoreSampleBufferDelegate(output, existing, desiredQ)
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
        let q = preferCallbackQueue(origQ)
        // 走 swizzle
        output.setSampleBufferDelegate(proxy, queue: q)
        wrapCount += 1
        NSLog(
            "BXFloatCam ensureWrapped retained=%d origMain=%d usedPaintQ=%d",
            retainedProxyCount,
            (origQ == nil || origQ === DispatchQueue.main) ? 1 : 0,
            q === paintQueue ? 1 : 0
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
    /// 原回调在 main 时：paint 在 paintQueue，向 main 合并投递（丢中间帧），避免 sync 死锁与 30fps 灌主线程
    private let deliverLock = NSLock()
    private var pendingSample: CMSampleBuffer?
    private var pendingOutput: AVCaptureOutput?
    private var pendingConnection: AVCaptureConnection?
    private var deliverScheduled = false
    private var coalescedDropCount: Int64 = 0

    init(target: AnyObject, originalQueue: DispatchQueue?) {
        self.originalTarget = target
        self.originalQueue = originalQueue
        super.init()
    }

    private var originalWasMain: Bool {
        originalQueue == nil || originalQueue === DispatchQueue.main
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
        CameraReplaceHooks.noteResumeFirstFrameIfNeeded(onMain: onMain, paintMs: ms)
        forwardDidOutput(output, sampleBuffer: sampleBuffer, connection: connection)
    }

    @objc(captureOutput:didDropSampleBuffer:fromConnection:)
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        BXFloatForwardDidDrop(originalTarget, output, sampleBuffer, connection)
    }

    private func forwardDidOutput(
        _ output: AVCaptureOutput,
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection
    ) {
        // 非 main 原队列：回调已在其队列，同步转发。
        if !originalWasMain {
            BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
            return
        }
        // 已在主线程（少见）：直接转，勿再 async
        if Thread.isMainThread {
            BXFloatForwardDidOutput(originalTarget, output, sampleBuffer, connection)
            return
        }
        // paintQueue → main：合并投递（Swift ARC 持有 sampleBuffer）。禁止 main.sync。
        deliverLock.lock()
        if pendingSample != nil {
            coalescedDropCount += 1
        }
        pendingSample = sampleBuffer
        pendingOutput = output
        pendingConnection = connection
        let needSchedule = !deliverScheduled
        deliverScheduled = true
        let drops = coalescedDropCount
        deliverLock.unlock()
        if drops > 0, drops % 120 == 0 {
            CamPipelineDiag.shared.noteSessionEvent("fwdCoalesce drops=\(drops)")
        }
        guard needSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingToOriginal()
        }
    }

    private func flushPendingToOriginal() {
        deliverLock.lock()
        let sb = pendingSample
        let out = pendingOutput
        let conn = pendingConnection
        pendingSample = nil
        pendingOutput = nil
        pendingConnection = nil
        deliverScheduled = false
        deliverLock.unlock()
        guard let sb, let out, let conn else { return }
        BXFloatForwardDidOutput(originalTarget, out, sb, conn)
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

        // 1) 后台预渲染帧（最快、不碰 ring；copyPrepared 内短锁）
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

        // 3) 预渲染未就绪：同 mediaTime 取帧；锁拿不到则 hold，避免回调堵在 ring 锁上
        let t = AVSyncClock.shared.mediaTime()
        if (CACurrentMediaTime() - t0) < budgetSec,
           let src = CamFrameStore.shared.copyForMediaTimeIfLock(t),
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
