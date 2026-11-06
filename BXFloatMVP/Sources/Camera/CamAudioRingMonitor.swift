import AudioToolbox
import AVFoundation
import Foundation

/// 环缓本地监听：环听(源环) / 注听(注入写出) 分锅，对照抖音录后。
/// 不改 AVAudioSession category/active，避免污染抖音录制轨。
final class CamAudioRingMonitor {
    static let shared = CamAudioRingMonitor()

    enum Source: Int {
        case off = 0
        case ring = 1
        case inject = 2
    }

    private(set) var source: Source = .off
    private var queue: AudioQueueRef?
    private var started = false
    private let lock = NSLock()
    private var asbd = AudioStreamBasicDescription()
    private let bufferFrames: UInt32 = 1024
    private let bufferCount = 3

    var statusLine: String {
        switch source {
        case .off: return "听:关"
        case .ring: return "听:环"
        case .inject: return "听:注"
        }
    }

    func cycleSource() {
        let next: Source
        switch source {
        case .off: next = .ring
        case .ring: next = .inject
        case .inject: next = .off
        }
        setSource(next)
    }

    func setSource(_ src: Source) {
        lock.lock()
        defer { lock.unlock() }
        if src == source { return }
        stopLocked()
        source = src
        if src != .off {
            startLocked()
        }
        NSLog("BXFloatMonitor source=%d (no session touch)", src.rawValue)
    }

    private func startLocked() {
        let fmt = CamAudioStore.shared.monitorFormat
        let rate = Float64(fmt.rate > 0 ? fmt.rate : 44100)
        let ch = UInt32(max(1, min(2, fmt.channels)))
        asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * ch,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * ch,
            mChannelsPerFrame: ch,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var q: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &asbd,
            { (_, aq, buf) in
                CamAudioRingMonitor.shared.render(aq: aq, buffer: buf)
            },
            nil,
            nil,
            nil,
            0,
            &q
        )
        guard status == noErr, let q else {
            NSLog("BXFloatMonitor AQ create fail %d", status)
            source = .off
            return
        }
        queue = q
        // 监听音量略低，减少外放窜入（注入轨仍走 AU 写，不经此 AQ）
        var vol: Float32 = 0.85
        AudioQueueSetParameter(q, kAudioQueueParam_Volume, vol)

        let bytes = bufferFrames * asbd.mBytesPerFrame
        for _ in 0..<bufferCount {
            var buf: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(q, bytes, &buf) == noErr, let buf else { continue }
            buf.pointee.mAudioDataByteSize = bytes
            memset(buf.pointee.mAudioData, 0, Int(bytes))
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }
        // 关键：不 setCategory / setActive，沿用抖音已开的 session，避免录制轨被改路由
        let st = AudioQueueStart(q, nil)
        started = (st == noErr)
        if !started {
            NSLog("BXFloatMonitor AQ start fail %d (session may block output)", st)
            AudioQueueDispose(q, true)
            queue = nil
            source = .off
        }
    }

    private func stopLocked() {
        if let q = queue {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
        }
        queue = nil
        started = false
        // 不 deactivate session
    }

    private func render(aq: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let frames = Int(bufferFrames)
        let ch = Int(asbd.mChannelsPerFrame)
        let bytes = frames * ch * 2
        guard buffer.pointee.mAudioDataByteSize >= bytes else {
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
            return
        }
        let dst = buffer.pointee.mAudioData.bindMemory(to: Int16.self, capacity: frames * ch)
        for i in 0..<(frames * ch) { dst[i] = 0 }
        lock.lock()
        let src = source
        lock.unlock()
        switch src {
        case .ring:
            _ = CamAudioStore.shared.pullMonitorRingS16(into: dst, frames: frames, channels: ch)
        case .inject:
            _ = CamAudioStore.shared.pullMonitorInjectS16(into: dst, frames: frames, channels: ch)
        case .off:
            break
        }
        buffer.pointee.mAudioDataByteSize = UInt32(bytes)
        AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
    }
}
