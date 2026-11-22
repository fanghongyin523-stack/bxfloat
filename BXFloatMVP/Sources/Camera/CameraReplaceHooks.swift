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

/// 把 `startRunning` / `stopRunning` 从主线程拿开。
///
/// 拍摄页的样本回调经常就在主队列。原始 start/stop 会占着会话锁，并一直等到这条队列空出来。
/// 调用栈还在主线程上时，队列永远空不了，拍照/拍视频按一下整页卡住。
/// 主线程把原始 start/stop 丢到串行队列，自己只转 RunLoop 等到它结束。回调仍留在宿主原来的队列上，不改挂 paintQueue。
/// 非主线程仍在调用线程里同步跑，避免和回调队列叠成 sync。
/// 启停还没结束时，紧跟着的 begin/commit/add 若发生在主线程，排到同一条队列后面，避免抢会话锁。
private final class SessionGateDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func mark() {
        lock.lock()
        done = true
        lock.unlock()
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func isDone() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

enum SessionControlGate {
    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "com.baixiang.cam.session-control", qos: .userInitiated)
        q.setSpecific(key: specificKey, value: 1)
        return q
    }()
    private static let specificKey = DispatchSpecificKey<UInt8>()

    private static var mainPumpDepth = 0

    static func callOriginal(label: String, _ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: specificKey) != nil {
            body()
            return
        }
        if Thread.isMainThread {
            // 已经在替上一次启停转 RunLoop：再等会和当前这次对死。排队即可。
            if mainPumpDepth > 0 {
                queue.async(execute: body)
                return
            }
            mainPumpDepth += 1
            defer { mainPumpDepth -= 1 }
            ShootSurfaceDetector.beginControlHop()
            NSLog("BXFloatCam %@ leave main", label)
            let flag = SessionGateDone()
            queue.async {
                body()
                ShootSurfaceDetector.endControlHop()
                flag.mark()
            }
            // 原始 start/stop 会 dispatch_sync 回主队列。这里转 RunLoop 让它跑完再回到抖音，
            // 预览层才接得上正在跑的会话。直接 return 时抖音会以为会话已开，画面停在黑屏。
            // 上限避免「等主队列完全空闲」把整页钉死。
            let start = CFAbsoluteTimeGetCurrent()
            while !flag.isDone() {
                if CFAbsoluteTimeGetCurrent() - start > 2.0 {
                    NSLog("BXFloatCam %@ main pump cap", label)
                    return
                }
                RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
            }
            return
        }
        // 已经不在主线程：就地跑。再 sync 到别的队列会和「回调队列就是这条线」对死。
        // 计数在 body 里、原始调用之前加上，主线程这时读 isRunning 会走闩锁。
        body()
    }

    /// 空闲时留在调用线程，配置括号的时序不变。
    /// 只有启停还占着锁时才改道，保证排在那次 start/stop 后面。
    static func runMutationIfBusy(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: specificKey) != nil {
            body()
            return
        }
        if !ShootSurfaceDetector.isSessionControlBusy() {
            body()
            return
        }
        if Thread.isMainThread {
            queue.async(execute: body)
            return
        }
        queue.sync(execute: body)
    }
}

@_silgen_name("BXFloatRestoreSampleBufferDelegate")
func BXFloatRestoreSampleBufferDelegate(
    _ output: AVCaptureVideoDataOutput,
    _ delegate: AnyObject?,
    _ queue: DispatchQueue?
)

/// 真替换（对齐 VCam 稳态挂钩）：
/// - 只在宿主 setSampleBufferDelegate 时包一层 proxy；采集跑起来后绝不重绑
/// - 保留宿主原回调队列（禁止改挂 paintQueue 再回灌 main → 二次拍摄卡死）
/// - 安静窗只盖切会话短窗：期内只转发，不 paint / 不 hold（防定格与假死）
/// - 主线程只合入 blitter 已准备好的最新帧；副线程才 ring/hold 兜底
/// - stop/start 只改武装标志，不 unwrap、不 apply 重绑
/// - 主线程上的 start/stop 不在调用栈里同步跑：回调队列也是主队列时，同步启停会等主队列排空，整页卡住
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

    /// 安静结束后短暂关融合，降低点直播首秒主线程叠画压力（稳定后自动恢复）
    private static var blendMuteUntil: CFAbsoluteTime = 0

    static func markSessionQuiet(seconds: CFAbsoluteTime) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        // 只盖住切会话那一小段；上限约 1.2s，勿恢复 3.5s（会定格拍摄页 / 低帧）
        let until = now + max(0.05, min(seconds, 1.20))
        if until > quietUntil { quietUntil = until }
        // 安静后再禁融合一小段即可，勿长时间挡住画面
        let mute = until + 0.28
        if mute > blendMuteUntil { blendMuteUntil = mute }
        lock.unlock()
    }

    static func shouldMuteBlend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() < blendMuteUntil
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
        swizzleIsRunning()
        swizzleIsInterrupted()
        swizzleCanAddInput()
        swizzleCanAddOutput()
        swizzleQueuedMutation("addInput:")
        swizzleQueuedMutation("removeInput:")
        swizzleQueuedMutation("removeOutput:")
        swizzleQueuedMutation("setSessionPreset:")
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
            let invoke = {
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
            // 启停还在后台时，add 必须排到那次调用后面，不能在主线程上跟会话锁对撞。
            SessionControlGate.runMutationIfBusy(invoke)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// add/remove/setPreset。空闲时仍在调用线程同步执行，配置括号不变。
    /// 只有 start/stop 还占着会话锁时才改排到同一条后台队列。
    private static func swizzleQueuedMutation(_ selectorName: String) {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { obj, arg in
            let invoke = {
                typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
                unsafeBitCast(original, to: Fn.self)(obj, sel, arg)
            }
            SessionControlGate.runMutationIfBusy(invoke)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionBeginConfiguration() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("beginConfiguration")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            // 切分段拍会进这里：短安静窗内禁止 paint，让宿主改 session 不被 memcpy 拖死
            markSessionQuiet(seconds: 1.20)
            let invoke = {
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(original, to: Fn.self)(session, sel)
            }
            SessionControlGate.runMutationIfBusy(invoke)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionCommitConfiguration() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("commitConfiguration")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { session in
            let invoke = {
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(original, to: Fn.self)(session, sel)
                // commit 后再安静一小段，等首批回调过完（勿拉长定格）
                markSessionQuiet(seconds: 0.28)
            }
            SessionControlGate.runMutationIfBusy(invoke)
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
                // 类名没命中时，视频会话一开就保持闩锁，停表，直到采集真正结束。
                // 这里不 setDelegate，也不读 isRunning。
                ShootSurfaceDetector.noteHardwareCaptureBegan(session: s)
            }
            // 点「开始录制」会进这里。对齐 VCam：只武装标志，start 前后都禁止 setDelegate。
            // 上一版在 start 后 wrapMissingOutputsOnce → 整屏卡死。
            markSessionQuiet(seconds: 1.20)
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
            // 主线程不能同步等原始 start。回调队列是主队列时，start 会一直等到主队列空出来。
            SessionControlGate.callOriginal(label: "startRunning") {
                ShootSurfaceDetector.beginHardwareStartCount()
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(original, to: Fn.self)(session, sel)
                // 原始 start 返回之后才把「正在启动」收成「已在跑」。
                ShootSurfaceDetector.noteHardwareCaptureDidStart()
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
            // 只标 sticky，绝不 unwrap（VCam：stop 不拆注入）
            // 复查必须放在原始 stop 返回之后。停的过程中主线程若读 isRunning，
            // 会和「stop 等主队列」对死（分段拍摄点下去、黄麦标出现后整页卡住）。
            markSessionQuiet(seconds: 0.32)
            markPauseStickyFromStopRunning()
            MicReplaceHooks.markPauseStickyFromStopRunning()
            SessionControlGate.callOriginal(label: "stopRunning") {
                ShootSurfaceDetector.noteHardwareCaptureWillStop()
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(original, to: Fn.self)(session, sel)
                ShootSurfaceDetector.noteHardwareCaptureEnded()
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// 真属性会拿会话锁。start/stop 还没返回时，主线程再读就会和「等主队列」对死。
    /// 抖音自己的黄麦标 / 前后台通知也会读它，所以不能只改我们自己的调用点。
    private static func swizzleIsRunning() {
        swizzleBusyBoolQuery(selectorName: "isRunning", whenBusy: true)
    }

    private static func swizzleIsInterrupted() {
        swizzleBusyBoolQuery(selectorName: "isInterrupted", whenBusy: false)
    }

    private static func swizzleCanAddInput() {
        swizzleBusyBoolArgQuery(selectorName: "canAddInput:", whenBusy: true)
    }

    private static func swizzleCanAddOutput() {
        swizzleBusyBoolArgQuery(selectorName: "canAddOutput:", whenBusy: true)
    }

    private static func swizzleBusyBoolQuery(selectorName: String, whenBusy: Bool) {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Bool = { obj in
            if ShootSurfaceDetector.isSessionControlBusy() {
                return whenBusy
            }
            typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(original, to: Fn.self)(obj, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleBusyBoolArgQuery(selectorName: String, whenBusy: Bool) {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject) -> Bool = { obj, arg in
            if ShootSurfaceDetector.isSessionControlBusy() {
                return whenBusy
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
            return unsafeBitCast(original, to: Fn.self)(obj, sel, arg)
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
        // 对齐 VCam：宿主原回调队列同步处理（禁止改挂 paintQueue 再回灌 main）。
        // 安静窗：只转发、不 paint、不 hold（与 Mic 同口径；长 hold 会定格/假死）。
        // 替换关着：原样把真摄像头交回去，禁止用空缓冲盖成黑屏。
        if CameraReplaceHooks.isReplaceActive(),
           MediaConfigStore.shared.config.replaceCameraEnabled,
           !CameraReplaceHooks.isSessionQuiet()
        {
            let ok = CamBufferPainter.paintInPlace(sampleBuffer)
            if ok { CameraReplaceHooks.notePaintOK() } else { CameraReplaceHooks.notePaintFail() }
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
/// 主线程：只合入 prepared；失败/无帧则透传（保触摸）。副线程才可 hold 上一帧。
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

    /// 单帧软预算：超时则透传/副线程才 hold，避免主线程拖死触摸。
    private static let budgetSec: CFTimeInterval = 0.004
    private static var loggedBlend = false
    private static var lastMainPaintLogAt: CFAbsoluteTime = 0

    /// 主线程走 copy/透传时限频打点，便于 CamPipelineDiag 确认 true-blend onMain 不再出现。
    private static func logMainPaintPath(_ kind: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMainPaintLogAt < 2 { return }
        lastMainPaintLogAt = now
        NSLog("BXFloatCam paintInPlace main-thread %@ (no blend/ring/hold)", kind as NSString)
    }

    /// 副线程欠帧兜底：hold 上一成功帧；主线程禁止走这条（会定格/假死）。
    @discardableResult
    static func holdLastInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        let fmt = CVPixelBufferGetPixelFormatType(dst)
        if let good = copyLastGood(width: dw, height: dh, format: fmt),
           copyPixels(from: good, to: dst)
        {
            return true
        }
        return true // 无 hold 则透传，避免黑屏
    }

    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let t0 = CACurrentMediaTime()
        guard let dst = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let dw = CVPixelBufferGetWidth(dst)
        let dh = CVPixelBufferGetHeight(dst)
        guard dw > 0, dh > 0 else { return false }

        // 定时露真 / 未开替换：透传真摄像头
        if CamReplacePolicy.shouldPassThroughRealCamera() {
            return true
        }

        let fmt = CVPixelBufferGetPixelFormatType(dst)
        CamFrameBlitter.shared.noteTarget(width: dw, height: dh, format: fmt)
        let onMain = Thread.isMainThread
        // 主线程回调（录视频/拍摄页常见）：只拷已准备帧或透传，禁止融合/ring/hold，避免整机卡死。
        if onMain {
            if let prepared = CamFrameBlitter.shared.copyPrepared(width: dw, height: dh, format: fmt),
               copyPixels(from: prepared, to: dst)
            {
                logMainPaintPath("copy-prepared")
                return true
            }
            logMainPaintPath("passthrough")
            return true
        }
        // 真融合：dst 当前就是真机画面；推流帧叠上去 dst = stream*frac + real*(1-frac)
        // 禁止先 clone 再画（主线程会卡死）。未开融合则 frac=1 等价整帧替换。
        let blendFrac = CameraReplaceHooks.shouldMuteBlend() ? 1.0 : CamReplacePolicy.streamBlendFraction()
        let wantBlend = blendFrac < 0.999

        if !loggedFormat {
            loggedFormat = true
            NSLog("BXFloatCam paint dstFormat=%u %dx%d blend=%d frac=%.2f", fmt, dw, dh, wantBlend ? 1 : 0, Double(blendFrac))
        }

        // 取推流帧：
        // - 主线程：只合入已准备好的最新帧；没有则透传（禁止 ring / 长期 hold 旧帧）
        // - 副线程：prepared → ring → lastGood
        let stream: CVPixelBuffer? = {
            if let prepared = CamFrameBlitter.shared.copyPrepared(width: dw, height: dh, format: fmt) {
                return prepared
            }
            if onMain {
                return nil
            }
            if (CACurrentMediaTime() - t0) < budgetSec {
                let t = AVSyncClock.shared.mediaTime()
                if let src = CamFrameStore.shared.copyForMediaTimeIfLock(t),
                   CVPixelBufferGetWidth(src) == dw,
                   CVPixelBufferGetHeight(src) == dh,
                   CVPixelBufferGetPixelFormatType(src) == fmt
                {
                    return src
                }
            }
            return copyLastGood(width: dw, height: dh, format: fmt)
        }()

        guard let stream else {
            return true // 无就绪素材：透传真机（主线程尤其如此）
        }

        // 取帧后已超软预算：主线程透传；副线程才 hold
        if (CACurrentMediaTime() - t0) >= budgetSec {
            if onMain { return true }
            return holdLastInPlace(sampleBuffer)
        }

        if wantBlend {
            // 真融合：在真机 dst 上按占比叠推流（主/副线程同一路径，无 clone）
            let step = onMain ? 2 : 1 // 主线程隔行加速，观感仍是融合
            if blendStreamOntoReal(stream: stream, realDst: dst, streamFrac: blendFrac, rowStep: step) {
                if !loggedBlend {
                    loggedBlend = true
                    NSLog("BXFloatCam true-blend on fmt=%u frac=%.2f main=%d step=%d", fmt, Double(blendFrac), onMain ? 1 : 0, step)
                }
                // 主线程禁止 retainCopy（额外分配+整帧拷易卡触摸）；副线程才留 hold 底
                if !onMain, let kept = retainCopy(dst) {
                    rememberGood(kept, width: dw, height: dh, format: fmt)
                }
                return true
            }
            // 融合失败（格式不支持）退回整帧替换
        }

        if copyPixels(from: stream, to: dst) {
            if !onMain {
                rememberGood(stream, width: dw, height: dh, format: fmt)
            }
            return true
        }
        // 主线程拷失败也透传；副线程才 hold
        if onMain { return true }
        return holdLastInPlace(sampleBuffer)
    }

    /// 真融合：realDst 当前为真机；写入 stream*frac + real*(1-frac)。支持 BGRA / 420YpCbCr。
    @discardableResult
    private static func blendStreamOntoReal(
        stream: CVPixelBuffer,
        realDst: CVPixelBuffer,
        streamFrac: CGFloat,
        rowStep: Int
    ) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(realDst)
        guard CVPixelBufferGetPixelFormatType(stream) == fmt,
              CVPixelBufferGetWidth(stream) == CVPixelBufferGetWidth(realDst),
              CVPixelBufferGetHeight(stream) == CVPixelBufferGetHeight(realDst)
        else { return false }

        let a = max(0, min(1, streamFrac))
        let ai = Int((a * 256.0).rounded())
        let bi = 256 - ai
        let step = max(1, rowStep)

        CVPixelBufferLockBaseAddress(stream, .readOnly)
        CVPixelBufferLockBaseAddress(realDst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(realDst, [])
            CVPixelBufferUnlockBaseAddress(stream, .readOnly)
        }

        let planes = CVPixelBufferGetPlaneCount(realDst)
        if planes == 0 {
            // BGRA / 单平面
            guard fmt == kCVPixelFormatType_32BGRA else { return false }
            guard let sBase = CVPixelBufferGetBaseAddress(stream)?.assumingMemoryBound(to: UInt8.self),
                  let dBase = CVPixelBufferGetBaseAddress(realDst)?.assumingMemoryBound(to: UInt8.self)
            else { return false }
            let w = CVPixelBufferGetWidth(realDst)
            let h = CVPixelBufferGetHeight(realDst)
            let sRow = CVPixelBufferGetBytesPerRow(stream)
            let dRow = CVPixelBufferGetBytesPerRow(realDst)
            var y = 0
            while y < h {
                let sLine = sBase.advanced(by: y * sRow)
                let dLine = dBase.advanced(by: y * dRow)
                var x = 0
                while x < w {
                    let i = x * 4
                    for c in 0..<3 {
                        let ov = Int(sLine[i + c])
                        let rv = Int(dLine[i + c])
                        dLine[i + c] = UInt8((ov * ai + rv * bi) >> 8)
                    }
                    x += 1
                }
                y += step
            }
            return true
        }

        // NV12 / 420f / 420v：各平面按权重融合（Y+UV）
        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr8Planar
            || fmt == kCVPixelFormatType_420YpCbCr8PlanarFullRange
            || planes >= 2
        {
            for p in 0..<planes {
                guard let sBase = CVPixelBufferGetBaseAddressOfPlane(stream, p)?.assumingMemoryBound(to: UInt8.self),
                      let dBase = CVPixelBufferGetBaseAddressOfPlane(realDst, p)?.assumingMemoryBound(to: UInt8.self)
                else { return false }
                let rows = CVPixelBufferGetHeightOfPlane(realDst, p)
                let sRow = CVPixelBufferGetBytesPerRowOfPlane(stream, p)
                let dRow = CVPixelBufferGetBytesPerRowOfPlane(realDst, p)
                let bytes = min(sRow, dRow)
                var y = 0
                let pStep = (p == 0) ? step : max(1, step / 2)
                while y < rows {
                    let sLine = sBase.advanced(by: y * sRow)
                    let dLine = dBase.advanced(by: y * dRow)
                    var i = 0
                    while i < bytes {
                        let ov = Int(sLine[i])
                        let rv = Int(dLine[i])
                        dLine[i] = UInt8((ov * ai + rv * bi) >> 8)
                        i += 1
                    }
                    y += pStep
                }
            }
            return true
        }
        return false
    }

    private static func retainCopy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
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
        guard copyPixels(from: src, to: out) else { return nil }
        return out
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
