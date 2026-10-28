import AudioToolbox
import AVFoundation
import CoreMedia
import ObjectiveC

/// 麦克风真替换：挂钩 AVCaptureAudioDataOutput，把推流 PCM / 静音写入采集 buffer。
enum MicReplaceHooks {
    private static var installed = false
    private static let lock = NSLock()
    private static var trackedOutputs = NSHashTable<AVCaptureAudioDataOutput>.weakObjects()
    private static let retainedProxies = NSMapTable<AVCaptureAudioDataOutput, MicSampleBufferProxy>.weakToStrongObjects()
    private static var injectActive = false
    private static var currentMode: AudioCaptureMode = .microphone

    private(set) static var wrapCount: Int64 = 0
    private(set) static var callbackCount: Int64 = 0
    private(set) static var paintCount: Int64 = 0
    private(set) static var paintFailCount: Int64 = 0
    private(set) static var retainedProxyCount: Int = 0

    static func noteCallback() { callbackCount += 1 }
    static func notePaintOK() { paintCount += 1 }
    static func notePaintFail() { paintFailCount += 1 }

    static func activeMode() -> AudioCaptureMode {
        lock.lock()
        defer { lock.unlock() }
        return currentMode
    }

    static func isInjectActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return injectActive
    }

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleAudioDataOutput()
        swizzleSessionAddOutput()
        // 注意：不在启动时 fishhook，避免只读 GOT 写崩导致抖音闪退
        NSLog("BXFloatMic AVCapture hooks installed (AU deferred)")
    }

    /// mode=推流/静音时注入；原麦则 unwrap 透传。
    static func applyAudioMode(_ mode: AudioCaptureMode) {
        installIfNeeded()
        let onCamera = ShootSurfaceDetector.isCameraSurfaceVisible()
        // 仅在拍摄/开播界面注入，避免启动首页就 fishhook
        let want = onCamera && (mode == .stream || mode == .mute)

        lock.lock()
        currentMode = mode
        injectActive = want
        lock.unlock()

        // AudioUnit 路径：仅在需要推流/静音时才 fishhook（且延迟到主线程空闲）
        let auMode: Int32
        if !want {
            auMode = 0
        } else if mode == .mute {
            auMode = 2
        } else {
            auMode = 1
        }
        BXFloatMicAUSetMode(auMode)
        if want {
            DispatchQueue.main.async {
                BXFloatMicAUInstall()
            }
        }

        let outputs = trackedOutputs.allObjects
        for output in outputs {
            if want {
                let q = output.sampleBufferCallbackQueue ?? DispatchQueue.main
                q.async { ensureWrapped(output) }
            } else {
                unwrap(output)
            }
        }
        retainedProxyCount = retainedProxies.count
        NSLog(
            "BXFloatMic apply mode=%@ cam=%d active=%d tracked=%d retain=%d auMode=%d auPaint=%lld",
            mode.rawValue,
            onCamera ? 1 : 0,
            want ? 1 : 0,
            outputs.count,
            retainedProxyCount,
            auMode,
            BXFloatMicAUPaintCount()
        )
    }

    private static func track(_ output: AVCaptureAudioDataOutput) {
        trackedOutputs.add(output)
    }

    private static func swizzleAudioDataOutput() {
        let cls: AnyClass = AVCaptureAudioDataOutput.self
        let sel = NSSelectorFromString("setSampleBufferDelegate:queue:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?, DispatchQueue?) -> Void = { obj, delegate, queue in
            if let aout = obj as? AVCaptureAudioDataOutput {
                track(aout)
            }
            var finalDelegate = delegate
            if isInjectActive(),
               let aout = obj as? AVCaptureAudioDataOutput,
               let d = delegate,
               !(d is MicSampleBufferProxy)
            {
                let proxy = MicSampleBufferProxy(target: d)
                retainedProxies.setObject(proxy, forKey: aout)
                retainedProxyCount = retainedProxies.count
                finalDelegate = proxy
                wrapCount += 1
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, DispatchQueue?) -> Void
            let call = unsafeBitCast(original, to: Fn.self)
            call(obj, sel, finalDelegate, queue)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func swizzleSessionAddOutput() {
        let cls: AnyClass = AVCaptureSession.self
        let sel = NSSelectorFromString("addOutput:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AVCaptureOutput) -> Void = { obj, output in
            typealias Fn = @convention(c) (AnyObject, Selector, AVCaptureOutput) -> Void
            let call = unsafeBitCast(original, to: Fn.self)
            call(obj, sel, output)
            if let aout = output as? AVCaptureAudioDataOutput {
                track(aout)
                if isInjectActive() {
                    DispatchQueue.main.async { ensureWrapped(aout) }
                }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func ensureWrapped(_ output: AVCaptureAudioDataOutput) {
        track(output)
        guard isInjectActive() else { return }
        if let existing = output.sampleBufferDelegate as? MicSampleBufferProxy {
            retainedProxies.setObject(existing, forKey: output)
            retainedProxyCount = retainedProxies.count
            return
        }
        guard let delegate = output.sampleBufferDelegate else {
            NSLog("BXFloatMic ensureWrapped skip: delegate=nil")
            return
        }
        let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
        let proxy = MicSampleBufferProxy(target: delegate)
        retainedProxies.setObject(proxy, forKey: output)
        retainedProxyCount = retainedProxies.count
        output.setSampleBufferDelegate(proxy, queue: queue)
        wrapCount += 1
        NSLog("BXFloatMic ensureWrapped retained=%d", retainedProxyCount)
    }

    private static func unwrap(_ output: AVCaptureAudioDataOutput) {
        let proxy =
            (output.sampleBufferDelegate as? MicSampleBufferProxy)
            ?? retainedProxies.object(forKey: output)
        if let proxy {
            let queue = output.sampleBufferCallbackQueue ?? DispatchQueue.global(qos: .userInteractive)
            BXFloatRestoreSampleBufferDelegateAny(output, proxy.originalTarget, queue)
            NSLog("BXFloatMic unwrapped")
        }
        retainedProxies.removeObject(forKey: output)
        retainedProxyCount = retainedProxies.count
    }
}

final class MicSampleBufferProxy: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
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

    @objc(captureOutput:didOutputSampleBuffer:fromConnection:)
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        MicReplaceHooks.noteCallback()
        if MicReplaceHooks.isInjectActive() {
            let mode = MicReplaceHooks.activeMode()
            if MicBufferPainter.paintInPlace(sampleBuffer, mode: mode) {
                MicReplaceHooks.notePaintOK()
            } else if mode != .microphone {
                MicReplaceHooks.notePaintFail()
            }
        }
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

enum MicBufferPainter {
    private static var loggedFormat = false

    @discardableResult
    static func paintInPlace(_ sampleBuffer: CMSampleBuffer, mode: AudioCaptureMode) -> Bool {
        switch mode {
        case .microphone:
            return true
        case .mute, .stream:
            break
        }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return false }
        let asbd = asbdPtr.pointee

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let data = dataPointer, totalLength > 0 else { return false }

        if !loggedFormat {
            loggedFormat = true
            NSLog(
                "BXFloatMic paint rate=%.0f ch=%u bits=%u float=%d bytes=%d",
                asbd.mSampleRate,
                asbd.mChannelsPerFrame,
                asbd.mBitsPerChannel,
                (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0,
                totalLength
            )
        }

        if mode == .mute {
            CamAudioStore.silence(into: UnsafeMutableRawPointer(data), byteCount: totalLength)
            return true
        }

        // stream：有推流 PCM 就写；没有则静音，避免漏出原麦
        if CamAudioStore.shared.hasFreshAudio {
            return CamAudioStore.shared.fill(
                into: UnsafeMutableRawPointer(data),
                byteCount: totalLength,
                asbd: asbd
            )
        }
        CamAudioStore.silence(into: UnsafeMutableRawPointer(data), byteCount: totalLength)
        return true
    }
}

@_silgen_name("BXFloatRestoreSampleBufferDelegateAny")
func BXFloatRestoreSampleBufferDelegateAny(
    _ output: AnyObject,
    _ delegate: AnyObject?,
    _ queue: DispatchQueue?
)

@_silgen_name("BXFloatMicAUInstall")
func BXFloatMicAUInstall()

@_silgen_name("BXFloatMicAUSetMode")
func BXFloatMicAUSetMode(_ mode: Int32)

@_silgen_name("BXFloatMicAUPaintCount")
func BXFloatMicAUPaintCount() -> Int64

@_silgen_name("BXFloatMicAUCallbackCount")
func BXFloatMicAUCallbackCount() -> Int64

@_cdecl("BXFloatInstallMicHooks")
public func BXFloatInstallMicHooks() {
    MicReplaceHooks.installIfNeeded()
}
