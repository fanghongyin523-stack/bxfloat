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

/// 真替换（对齐 VCam 稳态挂钩）：
/// - 只在宿主 setSampleBufferDelegate 时包一层 proxy；采集跑起来后绝不重绑
/// - 保留宿主原回调队列（禁止改挂 paintQueue 再回灌 main → 二次拍摄卡死）
/// - 回调里只做限时像素拷贝；超时 hold 上一帧
/// - stop/start 只改武装标志，不 unwrap、不 apply 重绑
enum CameraReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureVideoDataOutput>.weakObjects()
    /// key=output（弱），value=proxy（强）——修回调为 0 的根因
    private static let retainedProxies = NSMapTable<AVCaptureVideoDataOutput, CamSampleBufferProxy>.weakToStrongObjects()
    private static var replaceActive = false
    /// 上次确认在拍摄面的时间（诊断用）
    private static var lastCameraSeenAt: CFAbsoluteTime = 0
    /// stopRunning 后保持武装；二次 start 前仍保持，禁止超时拆钩
    private static var pauseSticky = false
    private static var pauseStickyAt: CFAbsoluteTime = 0
    private static var resumeFirstFramePending = false
    /// 宿主 beginConfiguration / stop / start 窗口内：只转发不 paint，避免跟 session 锁打架卡死
    private static var quietUntil: CFAbsoluteTime = 0

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

    /// 切模式 / beginConfiguration 安静窗：只转发，不 paint
    static func isSessionQuiet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() < quietUntil
    }

    static func markSessionQuiet(seconds: CFAbsoluteTime) {
        lock.lock()
        let until = CFAbsoluteTimeGetCurrent() + max(0.05, seconds)
        if until > quietUntil { quietUntil = until }
        lock.unlock()
    }

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleVideoDataOutput()
        swizzleSessionAddOutput()
        swizzleSessionBeginConfiguration()
        swizzleSessionCommitConfiguration()
        swizzleSessionStartRunning()
        swizzleSessionStopRunning()
        _ = CamPipelineDiag.shared // 启动主线程卡顿看门狗 + 自动落盘
        NSLog("BXFloatCam hooks installed (true-replace memcpy-only + quiet-window)")
    }

    static func applyReplaceMode(_ enabled: Bool) {
        installIfNeeded()
        // 对齐参考：
        // - 用户「开替换」边沿：包一次已有输出（否则只涨收帧不换画）
        // - 点「开始录制」走 startRunning：只武装，绝不 setDelegate（否则整屏卡死）
        // - 已武装稳态：什么都不动
        let want = enabled
        lock.lock()
        let wasActive = replaceActive
        if want == wasActive {
            if want { lastCameraSeenAt = CFAbsoluteTimeGetCurrent() }
            lock.unlock()
            return
        }
        if want {
            if pauseSticky {
                pauseSticky = false
                resumeFirstFramePending = true
            }
            lastCameraSeenAt = CFAbsoluteTimeGetCurrent()
        } else {
            pauseSticky = false
            resumeFirstFramePending = false
        }
        replaceActive = want
        lock.unlock()

        CamFrameBlitter.shared.setEnabled(want)
        PreviewCover.stop()

        if want {
            wrapMissingOutputsOnce()
        } else {
            for output in trackedOutputs.allObjects {
                unwrap(output)
            }
        }
        retainedProxyCount = retainedProxies.count
        CamPipelineDiag.shared.noteSessionEvent(
            "applyReplace edge cfg=\(enabled ? 1 : 0) was=\(wasActive ? 1 : 0) active=\(want ? 1 : 0) retain=\(retainedProxyCount)"
        )
    }

    /// 只包「还不是 proxy」的输出；已包的绝不重绑队列。
    private static func wrapMissingOutputsOnce() {
        for output in trackedOutputs.allObjects {
            wrapOneIfNeeded(output)
        }
        retainedProxyCount = retainedProxies.count
    }

    private static func wrapOneIfNeeded(_ output: AVCaptureVideoDataOutput) {
        track(output)
        guard isReplaceActive() else { return }
        if let existing = output.sampleBufferDelegate as? CamSampleBufferProxy {
            retainedProxies.setObject(existing, forKey: output)
            return
        }
        guard let delegate = output.sampleBufferDelegate else { return }
        let queue = output.sampleBufferCallbackQueue
        let proxy = CamSampleBufferProxy(target: delegate, originalQueue: queue)
        retainedProxies.setObject(proxy, forKey: output)
        // 禁止写 alwaysDiscardsLateVideoFrames：分段拍/切模式时常在 session 配置窗内，
        // 改 output 属性会跟宿主锁打架 → 整屏卡死。晚帧靠 paint 预算丢弃即可。
        // 走 swizzle；队列保持宿主原样
        output.setSampleBufferDelegate(proxy, queue: queue)
        wrapCount += 1
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
            // 已是我们的 proxy：原样下发，禁止二次包装
            if delegate is CamSampleBufferProxy {
                typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
                unsafeBitCast(original, to: Fn.self)(obj, sel, delegate, queue)
                return
            }
            var finalDelegate = delegate
            // 对齐 VCam：武装时在宿主设回调的当口包一层；队列原样保留，绝不改挂
            if isReplaceActive(),
               let vout = obj as? AVCaptureVideoDataOutput,
               let delegate
            {
                let proxy = CamSampleBufferProxy(target: delegate, originalQueue: queue)
                retainedProxies.setObject(proxy, forKey: vout)
                retainedProxyCount = retainedProxies.count
                finalDelegate = proxy
                // 不在此处改 alwaysDiscardsLateVideoFrames（见 wrapOneIfNeeded 注释）
                wrapCount += 1
            } else if let vout = obj as? AVCaptureVideoDataOutput {
                // 宿主清空/换掉非 proxy：释放旧强持有
                retainedProxies.removeObject(forKey: vout)
                retainedProxyCount = retainedProxies.count
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
            // 只 track。包代理交给后续 setSampleBufferDelegate swizzle（禁止在 addOutput 里 setDelegate）
            if let vout = output as? AVCaptureVideoDataOutput {
                track(vout)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionBeginConfiguration() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("beginConfiguration")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            // 切分段拍会进这里：安静窗内禁止 paint，让宿主改 session 不被 memcpy 拖死
            markSessionQuiet(seconds: 1.20)
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionCommitConfiguration() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("commitConfiguration")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
            // commit 后再安静一小段，等首批回调过完
            markSessionQuiet(seconds: 0.45)
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
            // 点「开始录制」会进这里。对齐 VCam：只武装标志，start 前后都禁止 setDelegate。
            // 上一版在 start 后 wrapMissingOutputsOnce → 整屏卡死。
            markSessionQuiet(seconds: 0.55)
            let cfgArmed = MediaConfigStore.shared.config
            if cfgArmed.replaceCameraEnabled {
                lock.lock()
                replaceActive = true
                pauseSticky = false
                resumeFirstFramePending = true
                lastCameraSeenAt = CFAbsoluteTimeGetCurrent()
                lock.unlock()
                CamFrameBlitter.shared.setEnabled(true)
            }
            MicReplaceHooks.armBeforeStartRunningIfNeeded()
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionStopRunning() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("stopRunning")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            // 只标 sticky，绝不 unwrap（VCam：stop 不拆注入）
            markSessionQuiet(seconds: 0.80)
            markPauseStickyFromStopRunning()
            MicReplaceHooks.markPauseStickyFromStopRunning()
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Fn.self)(session, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func unwrap(_ output: AVCaptureVideoDataOutput) {
        let proxy =
            (output.sampleBufferDelegate as? CamSampleBufferProxy)
            ?? retainedProxies.object(forKey: output)
        if let proxy {
            let queue = proxy.originalQueue
            BXFloatRestoreSampleBufferDelegate(output, proxy.originalTarget, queue)
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
        // 对齐 VCam：宿主回调队列上同步处理；配置窗/切模式安静期内只转发不 paint。
        // 禁止改队列后再 async 回 main（二次拍摄卡顿根因）。
        if CameraReplaceHooks.isReplaceActive(), !CameraReplaceHooks.isSessionQuiet() {
            if CamBufferPainter.paintInPlace(sampleBuffer) {
                CameraReplaceHooks.notePaintOK()
            } else {
                CameraReplaceHooks.notePaintFail()
            }
        }
        let ms = (CACurrentMediaTime() - t0) * 1000.0
        CamPipelineDiag.shared.notePaintCost(ms: ms, onMain: onMain)
        CameraReplaceHooks.noteResumeFirstFrameIfNeeded(onMain: onMain, paintMs: ms)
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
    private static var sourceEpoch: UInt64 = 0
    private static var lastGoodEpoch: UInt64 = 0

    /// 换源（局域网↔本地↔USB）时清残帧，避免切过去还停在旧画面
    static func bumpSourceEpochAndClearHold() {
        lock.lock()
        sourceEpoch &+= 1
        lastGood = nil
        lastGoodW = 0
        lastGoodH = 0
        lastGoodFmt = 0
        lastGoodEpoch = 0
        lock.unlock()
        CamFrameBlitter.shared.invalidatePrepared()
        NSLog("BXFloatCam sourceEpoch bump clearHold")
    }

    /// 单帧软预算：超时 hold 上一完整帧（主线程更紧），避免二次拍摄卡触摸。
    private static let budgetSec: CFTimeInterval = 0.004

    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let t0 = CACurrentMediaTime()
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard dw > 0, dh > 0 else { return false }

        // 定时露真 / 未开替换：透传真摄像头（对标目标面板「定时显示真实镜头」）
        if CamReplacePolicy.shouldPassThroughRealCamera() {
            return true
        }

        let fmt = CVPixelBufferGetPixelFormatType(dst)
        CamFrameBlitter.shared.noteTarget(width: dw, height: dh, format: fmt)
        // 主线程回调（录制键/切分段拍常在 main）：禁止 clone、禁止碰 ring；
        // 只允许一次短 memcpy；超时直接透传，避免整屏卡死。
        let onMain = Thread.isMainThread
        let blendFrac = onMain ? 1.0 : CamReplacePolicy.streamBlendFraction()
        var realSnapshot: CVPixelBuffer?
        if !onMain, blendFrac < 0.999 {
            realSnapshot = cloneBuffer(dst)
        }

        if !loggedFormat {
            loggedFormat = true
            NSLog("BXFloatCam paint dstFormat=%u %dx%d (memcpy-only)", fmt, dw, dh)
        }

        // 主线程：预算更紧；绝不走 ring / clone；超时透传保触摸
        if onMain {
            if let prepared = CamFrameBlitter.shared.copyPrepared(
                width: dw, height: dh, format: fmt
            ), (CACurrentMediaTime() - t0) < budgetSec * 0.5,
               copyPixels(from: prepared, to: dst)
            {
                rememberGood(prepared, width: dw, height: dh, format: fmt)
                return true
            }
            if (CACurrentMediaTime() - t0) < budgetSec,
               let good = copyLastGood(width: dw, height: dh, format: fmt),
               copyPixels(from: good, to: dst)
            {
                return true
            }
            return true
        }

        // 1) 后台预渲染帧（最快、不碰 ring；copyPrepared 内短锁）
        if let prepared = CamFrameBlitter.shared.copyPrepared(
            width: dw, height: dh, format: fmt
        ), copyPixels(from: prepared, to: dst) {
            rememberGood(prepared, width: dw, height: dh, format: fmt)
            finishBlend(dst: dst, real: realSnapshot, frac: blendFrac)
            return true
        }

        // 2) 预算紧张：仅 hold「本源 epoch」帧；无新素材则透传真机（禁止粘旧源）
        let tight = (CACurrentMediaTime() - t0) > budgetSec * 0.4
        if tight {
            if let good = copyLastGood(width: dw, height: dh, format: fmt),
               copyPixels(from: good, to: dst)
            {
                finishBlend(dst: dst, real: realSnapshot, frac: blendFrac)
                return true
            }
            return true // 透传真摄像头，等新流首帧
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
            finishBlend(dst: dst, real: realSnapshot, frac: blendFrac)
            return true
        }

        if let good = copyLastGood(width: dw, height: dh, format: fmt),
           copyPixels(from: good, to: dst)
        {
            finishBlend(dst: dst, real: realSnapshot, frac: blendFrac)
            return true
        }

        // 换源后环空：透传真机，不要黑屏/旧本地帧
        return true
    }

    /// 融合真实摄像头：dst=推流画面，real=真机，frac=推流占比
    private static func finishBlend(dst: CVPixelBuffer, real: CVPixelBuffer?, frac: CGFloat) {
        guard let real, frac < 0.999 else { return }
        blendPixels(obs: dst, real: real, obsFrac: frac)
    }

    private static func cloneBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let out
        else { return nil }
        _ = copyPixels(from: src, to: out)
        return out
    }

    private static func blendPixels(obs: CVPixelBuffer, real: CVPixelBuffer, obsFrac: CGFloat) {
        guard CVPixelBufferGetPixelFormatType(obs) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(real) == kCVPixelFormatType_32BGRA
        else { return }
        let w = CVPixelBufferGetWidth(obs)
        let h = CVPixelBufferGetHeight(obs)
        guard w == CVPixelBufferGetWidth(real), h == CVPixelBufferGetHeight(real) else { return }
        CVPixelBufferLockBaseAddress(obs, [])
        CVPixelBufferLockBaseAddress(real, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(real, .readOnly)
            CVPixelBufferUnlockBaseAddress(obs, [])
        }
        guard let oBase = CVPixelBufferGetBaseAddress(obs)?.assumingMemoryBound(to: UInt8.self),
              let rBase = CVPixelBufferGetBaseAddress(real)?.assumingMemoryBound(to: UInt8.self)
        else { return }
        let oRow = CVPixelBufferGetBytesPerRow(obs)
        let rRow = CVPixelBufferGetBytesPerRow(real)
        let a = max(0, min(1, obsFrac))
        let b = 1 - a
        for y in 0..<h {
            let oLine = oBase.advanced(by: y * oRow)
            let rLine = rBase.advanced(by: y * rRow)
            for x in 0..<w {
                let i = x * 4
                for c in 0..<3 {
                    let ov = CGFloat(oLine[i + c])
                    let rv = CGFloat(rLine[i + c])
                    oLine[i + c] = UInt8(max(0, min(255, ov * a + rv * b)))
                }
            }
        }
    }

    private static func rememberGood(_ buf: CVPixelBuffer, width: Int, height: Int, format: OSType) {
        lock.lock()
        lastGood = buf
        lastGoodW = width
        lastGoodH = height
        lastGoodFmt = format
        lastGoodEpoch = sourceEpoch
        lock.unlock()
    }

    private static func copyLastGood(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastGood,
              lastGoodEpoch == sourceEpoch,
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
