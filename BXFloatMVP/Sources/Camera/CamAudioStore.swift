import AudioToolbox
import Foundation

/// 音频 ring + 连续播放头。
/// - 超前视频：有界 pending + rebase，禁止 shouldAccept 硬拒收导致连续断音
/// - 欠载：淡出到近静音再淡入，禁止硬切零 / 死循环末样
final class CamAudioStore {
    static let shared = CamAudioStore()

    private struct Chunk {
        var pts: Double
        var samples: [Int16]
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var pending: [Chunk] = []
    private let maxSeconds: Double = 3.5
    private let maxPendingSeconds: Double = 1.20
    let storeRate = 48_000

    private var playhead: Double = -1
    private let maxPlayheadSlew: Double = 0.012
    private var lastSample: Int16 = 0
    /// 1=正常；欠载时向 0 衰减；恢复后淡入
    private var envelope: Double = 1.0

    // 复用缓冲，避免 AU/采集回调每帧堆分配
    private var scratchStore: [Int16] = Array(repeating: 0, count: 4096)
    private var scratchOut: [Int16] = Array(repeating: 0, count: 2048)

    private(set) var packetCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1
    private(set) var lastFormatNote = ""

    private init() {}

    var hasFreshAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (!chunks.isEmpty || !pending.isEmpty) && Date().timeIntervalSince(lastUpdate) < 3.0
    }

    func bufferedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let first = chunks.first, let last = chunks.last else { return 0 }
        let end = last.pts + Double(last.samples.count) / Double(storeRate)
        return max(0, end - first.pts)
    }

    func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        packetCount = 0
        lastUpdate = .distantPast
        lastPTS = -1
        playhead = -1
        lastSample = 0
        envelope = 1.0
        lock.unlock()
    }

    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int, pts: Double) {
        guard frames > 0, channels > 0 else { return }
        let ch = max(1, channels)
        var mono = [Int16](repeating: 0, count: frames)
        if ch == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, samples, frames * MemoryLayout<Int16>.size)
            }
        } else {
            for i in 0..<frames {
                var acc = 0
                for c in 0..<ch {
                    acc += Int(samples[i * ch + c])
                }
                mono[i] = Int16(clamping: acc / ch)
            }
        }

        let rate = sampleRate > 0 ? sampleRate : storeRate
        let pcm = (rate == storeRate) ? mono : resampleLinear(mono, from: rate, to: storeRate)
        guard !pcm.isEmpty else { return }

        if lastFormatNote.isEmpty {
            lastFormatNote = "mono \(storeRate)Hz s16 (src \(ch)ch \(rate)Hz)"
            CamPipelineDiag.shared.noteAudioFormat(lastFormatNote)
        }

        let mapped = pts >= 0 ? AVSyncClock.shared.mapPTS(pts) : -1
        let duration = Double(pcm.count) / Double(storeRate)
        var startPTS: Double
        if mapped >= 0 {
            startPTS = mapped
        } else {
            lock.lock()
            startPTS = nextAppendPTSLocked()
            lock.unlock()
        }
        var endPTS = startPTS + duration

        // 无 PTS：直接入环
        if mapped < 0 {
            commitToRing(pcm, startPTS: startPTS, endPTS: endPTS, reason: "nopts")
            return
        }

        switch AVSyncClock.shared.admitAudio(endPTS: endPTS, duration: duration) {
        case .accept:
            commitToRing(pcm, startPTS: startPTS, endPTS: endPTS, reason: "accept")
        case .pending(let lead):
            enqueuePending(pcm, startPTS: startPTS, endPTS: endPTS, lead: lead)
        case .rebase(let newStart, let lead):
            startPTS = newStart
            endPTS = startPTS + duration
            CamPipelineDiag.shared.noteAudioGate(
                accepted: true,
                endPTS: endPTS,
                reason: "rebase",
                leadMs: lead * 1000.0
            )
            commitToRing(pcm, startPTS: startPTS, endPTS: endPTS, reason: "rebase", gateAlreadyNoted: true)
        case .reject:
            CamPipelineDiag.shared.noteAudioGate(
                accepted: false,
                endPTS: endPTS,
                reason: "reject",
                leadMs: AVSyncClock.shared.audioLeadSeconds(endPTS: endPTS) * 1000.0
            )
        }
    }

    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int) {
        publish(samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, pts: -1)
    }

    /// 视频 PTS 前进后调用：把可接纳的 pending 冲入 ring。
    func flushPendingAgainstVideo() {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }
        let snapshot = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        for chunk in snapshot {
            let dur = Double(chunk.samples.count) / Double(storeRate)
            let end = chunk.pts + dur
            switch AVSyncClock.shared.admitAudio(endPTS: end, duration: dur) {
            case .accept:
                commitToRing(chunk.samples, startPTS: chunk.pts, endPTS: end, reason: "flush")
            case .pending:
                lock.lock()
                pending.append(chunk)
                trimPendingLocked()
                lock.unlock()
            case .rebase(let newStart, let lead):
                let newEnd = newStart + dur
                CamPipelineDiag.shared.noteAudioGate(
                    accepted: true,
                    endPTS: newEnd,
                    reason: "flush-rebase",
                    leadMs: lead * 1000.0
                )
                commitToRing(
                    chunk.samples,
                    startPTS: newStart,
                    endPTS: newEnd,
                    reason: "flush-rebase",
                    gateAlreadyNoted: true
                )
            case .reject:
                CamPipelineDiag.shared.noteAudioGate(
                    accepted: false,
                    endPTS: end,
                    reason: "flush-drop",
                    leadMs: AVSyncClock.shared.audioLeadSeconds(endPTS: end) * 1000.0
                )
            }
        }
    }

    @discardableResult
    func fillContinuous(
        into dst: UnsafeMutableRawPointer,
        byteCount: Int,
        asbd: AudioStreamBasicDescription
    ) -> Bool {
        guard byteCount > 0 else { return false }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        var isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var sampleBytes = max(1, Int(asbd.mBitsPerChannel) / 8)
        if isFloat, sampleBytes < 4 { sampleBytes = 4 }
        if !isFloat, sampleBytes == 4, (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0 {
            isFloat = true
        }
        let frameBytes = sampleBytes * channels
        guard frameBytes > 0 else { return false }
        let frames = byteCount / frameBytes
        guard frames > 0 else { return false }

        let dstRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : storeRate
        let duration = Double(frames) / Double(dstRate)
        let needStore = max(1, Int((duration * Double(storeRate)).rounded(.up)) + 2)

        let target = AVSyncClock.shared.mediaTime()
        if AVSyncClock.shared.shouldFreezeAudio() {
            CamPipelineDiag.shared.noteAudioUnderrun()
            fillWithEnvelope(
                into: dst,
                frames: frames,
                channels: channels,
                isFloat: isFloat,
                sampleBytes: sampleBytes,
                decaying: true
            )
            return false
        }
        let startPTS = advancePlayhead(target: target, duration: duration)

        ensureScratch(store: needStore, out: frames)
        let got: Int
        if lock.lock(before: Date().addingTimeInterval(0.002)) {
            got = peekStartingLocked(at: startPTS, into: &scratchStore, frames: needStore)
            lock.unlock()
        } else {
            // 锁等待超时：淡出延持，避免回调堵死
            CamPipelineDiag.shared.noteAudioUnderrun()
            fillWithEnvelope(
                into: dst,
                frames: frames,
                channels: channels,
                isFloat: isFloat,
                sampleBytes: sampleBytes,
                decaying: true
            )
            return false
        }

        var outCount = frames
        if got <= 0 {
            CamPipelineDiag.shared.noteAudioUnderrun()
            fillWithEnvelope(
                into: dst,
                frames: frames,
                channels: channels,
                isFloat: isFloat,
                sampleBytes: sampleBytes,
                decaying: true
            )
            return false
        }

        if dstRate == storeRate {
            let n = min(frames, got)
            for i in 0..<n { scratchOut[i] = scratchStore[i] }
            if n < frames {
                let pad = scratchStore[n - 1]
                for i in n..<frames { scratchOut[i] = pad }
            }
        } else {
            var rs = resampleLinear(
                Array(scratchStore.prefix(max(got, 1))),
                from: storeRate,
                to: dstRate
            )
            if rs.count < frames {
                let pad = rs.last ?? lastSample
                rs.append(contentsOf: repeatElement(pad, count: frames - rs.count))
            } else if rs.count > frames {
                rs = Array(rs.prefix(frames))
            }
            outCount = rs.count
            for i in 0..<outCount { scratchOut[i] = rs[i] }
        }

        // 从欠载恢复：淡入，避免台阶
        if envelope < 0.999 {
            let fade = min(96, frames)
            for i in 0..<fade {
                let a = envelope + (1.0 - envelope) * (Double(i + 1) / Double(fade))
                scratchOut[i] = Int16(clamping: Int(Double(scratchOut[i]) * a))
            }
            envelope = 1.0
        }

        if frames > 0 { lastSample = scratchOut[frames - 1] }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        writePCM(
            dst,
            frames: frames,
            channels: channels,
            samplesPrefix: frames,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: isNonInterleaved
        )
        CamPipelineDiag.shared.noteAudioOutput(samples: Array(scratchOut.prefix(frames)))
        return true
    }

    @discardableResult
    func fill(
        into dst: UnsafeMutableRawPointer,
        byteCount: Int,
        asbd: AudioStreamBasicDescription,
        startPTS: Double
    ) -> Bool {
        _ = startPTS
        return fillContinuous(into: dst, byteCount: byteCount, asbd: asbd)
    }

    @discardableResult
    func fill(into dst: UnsafeMutableRawPointer, byteCount: Int, asbd: AudioStreamBasicDescription) -> Bool {
        fillContinuous(into: dst, byteCount: byteCount, asbd: asbd)
    }

    static func silence(into dst: UnsafeMutableRawPointer, byteCount: Int) {
        memset(dst, 0, byteCount)
    }

    // MARK: - admit / pending

    private func commitToRing(
        _ pcm: [Int16],
        startPTS: Double,
        endPTS: Double,
        reason: String,
        gateAlreadyNoted: Bool = false
    ) {
        if !gateAlreadyNoted {
            let lead = AVSyncClock.shared.audioLeadSeconds(endPTS: endPTS)
            CamPipelineDiag.shared.noteAudioGate(
                accepted: true,
                endPTS: endPTS,
                reason: reason,
                leadMs: lead * 1000.0
            )
        }
        pcm.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                CamPipelineDiag.shared.noteAudioInput(samples: base, count: buf.count)
            }
        }
        lock.lock()
        chunks.append(Chunk(pts: startPTS, samples: pcm))
        packetCount += 1
        lastUpdate = Date()
        lastPTS = endPTS
        pruneLocked(before: endPTS - maxSeconds)
        lock.unlock()
        AVSyncClock.shared.noteAudioEndPTS(endPTS)
    }

    private func enqueuePending(_ pcm: [Int16], startPTS: Double, endPTS: Double, lead: Double) {
        CamPipelineDiag.shared.noteAudioGate(
            accepted: false,
            endPTS: endPTS,
            reason: "pending",
            leadMs: lead * 1000.0
        )
        // pending 仍计入输入峰，便于对照「收了但未出」
        pcm.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                CamPipelineDiag.shared.noteAudioInput(samples: base, count: buf.count)
            }
        }
        lock.lock()
        pending.append(Chunk(pts: startPTS, samples: pcm))
        lastUpdate = Date()
        trimPendingLocked()
        lock.unlock()
    }

    private func trimPendingLocked() {
        while pendingSecondsLocked() > maxPendingSeconds, !pending.isEmpty {
            // 溢出：rebase 最旧一包接到 ring 尾，而不是扔掉造成断音
            let old = pending.removeFirst()
            let dur = Double(old.samples.count) / Double(storeRate)
            let start = nextAppendPTSLocked()
            let end = start + dur
            chunks.append(Chunk(pts: start, samples: old.samples))
            packetCount += 1
            lastPTS = end
            pruneLocked(before: end - maxSeconds)
            CamPipelineDiag.shared.noteAudioGate(
                accepted: true,
                endPTS: end,
                reason: "pending-overflow-rebase",
                leadMs: AVSyncClock.shared.audioLeadSeconds(endPTS: end) * 1000.0
            )
            AVSyncClock.shared.noteAudioEndPTS(end)
        }
    }

    private func pendingSecondsLocked() -> Double {
        guard let first = pending.first, let last = pending.last else { return 0 }
        let end = last.pts + Double(last.samples.count) / Double(storeRate)
        return max(0, end - first.pts)
    }

    // MARK: - fill helpers

    private func ensureScratch(store: Int, out: Int) {
        if scratchStore.count < store {
            scratchStore = Array(repeating: 0, count: max(store, scratchStore.count * 2))
        }
        if scratchOut.count < out {
            scratchOut = Array(repeating: 0, count: max(out, scratchOut.count * 2))
        }
    }

    /// 欠载：末样 × 衰减包络 → 近静音，再保持低电平（非死循环满幅末样、非硬切零）
    private func fillWithEnvelope(
        into dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        isFloat: Bool,
        sampleBytes: Int,
        decaying: Bool
    ) {
        ensureScratch(store: 1, out: frames)
        // ~8ms 时间常数淡出到近静音（非硬切零、非满幅末样死循环）
        let decayPerFrame = exp(-1.0 / (0.008 * Double(storeRate)))
        for i in 0..<frames {
            if decaying {
                envelope = max(0.0, envelope * decayPerFrame)
            }
            let s = Int16(clamping: Int(Double(lastSample) * envelope))
            scratchOut[i] = s
        }
        if frames > 0 { lastSample = scratchOut[frames - 1] }
        writePCM(
            dst,
            frames: frames,
            channels: channels,
            samplesPrefix: frames,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: false
        )
    }

    private func advancePlayhead(target: Double, duration: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if playhead < 0 || !playhead.isFinite {
            playhead = max(0, target)
        } else {
            let err = target - playhead
            if abs(err) > 0.35 {
                playhead += max(-0.04, min(0.04, err * 0.15))
            } else if abs(err) > 0.04 {
                playhead += max(-maxPlayheadSlew, min(maxPlayheadSlew, err * 0.18))
            }
        }
        let start = playhead
        playhead += max(0, duration)
        return start
    }

    private func writePCM(
        _ dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        samplesPrefix: Int,
        isFloat: Bool,
        sampleBytes: Int,
        nonInterleaved: Bool
    ) {
        if nonInterleaved {
            let planeBytes = frames * sampleBytes
            for c in 0..<channels {
                writePlane(
                    dst.advanced(by: c * planeBytes),
                    frames: frames,
                    samplesPrefix: samplesPrefix,
                    isFloat: isFloat,
                    bytesPerSample: sampleBytes
                )
            }
        } else {
            writeInterleaved(
                dst,
                frames: frames,
                channels: channels,
                samplesPrefix: samplesPrefix,
                isFloat: isFloat,
                bytesPerSample: sampleBytes
            )
        }
    }

    private func peekStartingLocked(at startPTS: Double, into buffer: inout [Int16], frames: Int) -> Int {
        guard frames > 0, !chunks.isEmpty else { return 0 }

        var t = startPTS
        if !startPTS.isFinite || startPTS < 0 {
            t = chunks.first!.pts
        }
        pruneLocked(before: t - 0.5)

        var written = 0
        var cursor = t
        for chunk in chunks {
            if written >= frames { break }
            let chunkEnd = chunk.pts + Double(chunk.samples.count) / Double(storeRate)
            if chunkEnd <= cursor { continue }
            if chunk.pts > cursor + 0.02 {
                // 间隙：用衰减末样填，不做满幅重复
                let gapFrames = min(
                    frames - written,
                    max(0, Int(((chunk.pts - cursor) * Double(storeRate)).rounded(.down)))
                )
                let hold = Int16(clamping: Int(Double(lastSample) * max(envelope, 0.15)))
                for i in 0..<gapFrames {
                    buffer[written + i] = hold
                }
                written += gapFrames
                cursor = chunk.pts
                if written >= frames { break }
            }
            let offsetSec = max(0, cursor - chunk.pts)
            var sampleIdx = Int((offsetSec * Double(storeRate)).rounded(.down))
            if sampleIdx < 0 { sampleIdx = 0 }
            if sampleIdx >= chunk.samples.count { continue }
            let n = min(frames - written, chunk.samples.count - sampleIdx)
            for i in 0..<n {
                buffer[written + i] = chunk.samples[sampleIdx + i]
            }
            written += n
            cursor += Double(n) / Double(storeRate)
        }
        return written
    }

    private func nextAppendPTSLocked() -> Double {
        if let last = chunks.last {
            return last.pts + Double(last.samples.count) / Double(storeRate)
        }
        return 0
    }

    private func pruneLocked(before pts: Double) {
        while let first = chunks.first {
            let end = first.pts + Double(first.samples.count) / Double(storeRate)
            if end < pts {
                chunks.removeFirst()
            } else {
                break
            }
        }
    }

    private func resampleLinear(_ input: [Int16], from srcRate: Int, to dstRate: Int) -> [Int16] {
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return input }
        if srcRate == dstRate { return input }
        let outCount = max(1, Int((Double(input.count) * Double(dstRate) / Double(srcRate)).rounded()))
        var out = [Int16](repeating: 0, count: outCount)
        let last = input.count - 1
        for i in 0..<outCount {
            let srcPos = Double(i) * Double(srcRate) / Double(dstRate)
            let i0 = min(Int(srcPos), last)
            let i1 = min(i0 + 1, last)
            let frac = srcPos - Double(i0)
            let a = Double(input[i0])
            let b = Double(input[i1])
            out[i] = Int16(clamping: Int((a + (b - a) * frac).rounded()))
        }
        return out
    }

    private func writeInterleaved(
        _ dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        samplesPrefix: Int,
        isFloat: Bool,
        bytesPerSample: Int
    ) {
        for i in 0..<frames {
            let s = i < samplesPrefix ? scratchOut[i] : 0
            for c in 0..<channels {
                writeSample(
                    dst.advanced(by: (i * channels + c) * bytesPerSample),
                    sample: s,
                    isFloat: isFloat,
                    bytesPerSample: bytesPerSample
                )
            }
        }
    }

    private func writePlane(
        _ dst: UnsafeMutableRawPointer,
        frames: Int,
        samplesPrefix: Int,
        isFloat: Bool,
        bytesPerSample: Int
    ) {
        for i in 0..<frames {
            let s = i < samplesPrefix ? scratchOut[i] : 0
            writeSample(dst.advanced(by: i * bytesPerSample), sample: s, isFloat: isFloat, bytesPerSample: bytesPerSample)
        }
    }

    private func writeSample(
        _ dst: UnsafeMutableRawPointer,
        sample: Int16,
        isFloat: Bool,
        bytesPerSample: Int
    ) {
        if isFloat, bytesPerSample == 4 {
            var f = Float(sample) / 32768.0
            withUnsafeBytes(of: &f) { raw in memcpy(dst, raw.baseAddress!, 4) }
        } else if bytesPerSample == 2 {
            var s = sample
            withUnsafeBytes(of: &s) { raw in memcpy(dst, raw.baseAddress!, 2) }
        } else if bytesPerSample == 4, !isFloat {
            var s32 = Int32(sample) << 16
            withUnsafeBytes(of: &s32) { raw in memcpy(dst, raw.baseAddress!, 4) }
        } else {
            var z: UInt8 = 0
            for i in 0..<bytesPerSample {
                memcpy(dst.advanced(by: i), &z, 1)
            }
        }
    }
}
