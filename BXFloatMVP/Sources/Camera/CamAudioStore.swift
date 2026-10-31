import AudioToolbox
import Foundation

/// 音频 ring + 连续播放头。
/// - 立体声保真：解码后保 2ch 交错 s16，注入时再按 AU 声道布局写出（禁止过早压 mono）
/// - 超前视频：有界 pending + rebase
/// - 欠载：慢衰减包络，避免音乐忽大忽小；禁止末样死循环
final class CamAudioStore {
    static let shared = CamAudioStore()

    private struct Chunk {
        var pts: Double
        /// 交错 PCM：mono=[s0,s1,…]；stereo=[L0,R0,L1,R1,…]
        var samples: [Int16]
        var channels: Int
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var pending: [Chunk] = []
    private let maxSeconds: Double = 3.5
    private let maxPendingSeconds: Double = 1.20
    let storeRate = 48_000
    /// 环缓声道（1 或 2）；由首包决定，会话内不变
    private(set) var storeChannels = 1

    private var playhead: Double = -1
    private let maxPlayheadSlew: Double = 0.012
    private var lastL: Int16 = 0
    private var lastR: Int16 = 0
    /// 1=正常；欠载时向 0 衰减；恢复后淡入
    private var envelope: Double = 1.0

    private var scratchStore: [Int16] = Array(repeating: 0, count: 8192)
    private var scratchOut: [Int16] = Array(repeating: 0, count: 4096)

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
        let end = last.pts + frameDuration(last)
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
        lastL = 0
        lastR = 0
        envelope = 1.0
        storeChannels = 1
        lastFormatNote = ""
        lock.unlock()
    }

    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int, pts: Double) {
        guard frames > 0, channels > 0 else { return }
        // 最多保 2ch；>2 时折成立体声（L=ch0, R=ch1），禁止全声道平均压 mono
        let srcCh = min(2, max(1, channels))
        var interleaved = [Int16](repeating: 0, count: frames * srcCh)
        if channels == 1 {
            interleaved.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, samples, frames * MemoryLayout<Int16>.size)
            }
        } else if channels == 2 {
            interleaved.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, samples, frames * 2 * MemoryLayout<Int16>.size)
            }
        } else {
            for i in 0..<frames {
                interleaved[i * 2] = samples[i * channels]
                interleaved[i * 2 + 1] = samples[i * channels + 1]
            }
        }

        let rate = sampleRate > 0 ? sampleRate : storeRate
        // 解码后音质：用第一声道峰/DC 代表源
        var probe = [Int16](repeating: 0, count: frames)
        for i in 0..<frames { probe[i] = interleaved[i * srcCh] }
        probe.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                CamPipelineDiag.shared.noteAudioQuality(
                    stage: .decode,
                    samples: base,
                    count: buf.count,
                    rateIn: rate
                )
            }
        }

        let pcm: [Int16]
        if rate == storeRate {
            pcm = interleaved
        } else {
            pcm = resampleHermiteInterleaved(interleaved, channels: srcCh, from: rate, to: storeRate)
        }
        guard !pcm.isEmpty else { return }

        lock.lock()
        if chunks.isEmpty, pending.isEmpty {
            storeChannels = srcCh
        }
        let ringCh = storeChannels
        lock.unlock()

        let ringPCM: [Int16]
        if srcCh == ringCh {
            ringPCM = pcm
        } else if srcCh == 1, ringCh == 2 {
            var up = [Int16](repeating: 0, count: (pcm.count) * 2)
            for i in 0..<pcm.count {
                up[i * 2] = pcm[i]
                up[i * 2 + 1] = pcm[i]
            }
            ringPCM = up
        } else {
            // ring mono, src stereo → 仅此会话首包前不应发生；兜底平均
            let framesN = pcm.count / 2
            var down = [Int16](repeating: 0, count: framesN)
            for i in 0..<framesN {
                down[i] = Int16(clamping: (Int(pcm[i * 2]) + Int(pcm[i * 2 + 1])) / 2)
            }
            ringPCM = down
        }

        let note = "\(ringCh)ch \(storeRate)Hz s16 (src \(channels)ch \(rate)Hz)"
        if lastFormatNote != note {
            lastFormatNote = note
            CamPipelineDiag.shared.noteAudioFormat(note)
        }

        let mapped = pts >= 0 ? AVSyncClock.shared.mapPTS(pts) : -1
        let frameCount = ringPCM.count / max(1, ringCh)
        let duration = Double(frameCount) / Double(storeRate)
        var startPTS: Double
        if mapped >= 0 {
            startPTS = mapped
        } else {
            lock.lock()
            startPTS = nextAppendPTSLocked()
            lock.unlock()
        }
        var endPTS = startPTS + duration

        if mapped < 0 {
            commitToRing(ringPCM, channels: ringCh, startPTS: startPTS, endPTS: endPTS, reason: "nopts")
            return
        }

        switch AVSyncClock.shared.admitAudio(endPTS: endPTS, duration: duration) {
        case .accept:
            commitToRing(ringPCM, channels: ringCh, startPTS: startPTS, endPTS: endPTS, reason: "accept")
        case .pending(let lead):
            enqueuePending(ringPCM, channels: ringCh, startPTS: startPTS, endPTS: endPTS, lead: lead)
        case .rebase(let newStart, let lead):
            startPTS = newStart
            endPTS = startPTS + duration
            CamPipelineDiag.shared.noteAudioGate(
                accepted: true,
                endPTS: endPTS,
                reason: "rebase",
                leadMs: lead * 1000.0
            )
            commitToRing(
                ringPCM,
                channels: ringCh,
                startPTS: startPTS,
                endPTS: endPTS,
                reason: "rebase",
                gateAlreadyNoted: true
            )
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
            let dur = frameDuration(chunk)
            let end = chunk.pts + dur
            switch AVSyncClock.shared.admitAudio(endPTS: end, duration: dur) {
            case .accept:
                commitToRing(
                    chunk.samples,
                    channels: chunk.channels,
                    startPTS: chunk.pts,
                    endPTS: end,
                    reason: "flush"
                )
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
                    channels: chunk.channels,
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
        let auCh = max(1, Int(asbd.mChannelsPerFrame))
        var isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var sampleBytes = max(1, Int(asbd.mBitsPerChannel) / 8)
        if isFloat, sampleBytes < 4 { sampleBytes = 4 }
        if !isFloat, sampleBytes == 4, (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0 {
            isFloat = true
        }
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        // 约定：byteCount = frames * auCh * sampleBytes（交错临时缓冲或多平面总字节）
        guard sampleBytes > 0, auCh > 0 else { return false }
        let outFrames = byteCount / (sampleBytes * auCh)
        guard outFrames > 0 else { return false }

        let dstRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : storeRate
        let duration = Double(outFrames) / Double(dstRate)
        let ringCh = max(1, storeChannels)
        let needStore = max(1, Int((duration * Double(storeRate)).rounded(.up)) + 2)

        let target = AVSyncClock.shared.mediaTime()
        // 视频真停：干净静音（禁止末样衰减电流声）；短 hold-last 不走这里
        if AVSyncClock.shared.shouldFreezeAudio() {
            CamPipelineDiag.shared.noteAudioUnderrun()
            Self.silence(into: dst, byteCount: byteCount)
            return false
        }
        let startPTS = advancePlayhead(target: target, duration: duration)

        ensureScratch(store: needStore * ringCh, out: outFrames * max(auCh, ringCh))
        let got: Int
        if lock.lock(before: Date().addingTimeInterval(0.002)) {
            got = peekStartingLocked(at: startPTS, into: &scratchStore, frames: needStore)
            lock.unlock()
        } else {
            CamPipelineDiag.shared.noteAudioUnderrun()
            fillWithEnvelope(
                into: dst,
                frames: outFrames,
                auChannels: auCh,
                isFloat: isFloat,
                sampleBytes: sampleBytes,
                nonInterleaved: isNonInterleaved,
                decaying: true
            )
            return false
        }

        if got <= 0 {
            CamPipelineDiag.shared.noteAudioUnderrun()
            fillWithEnvelope(
                into: dst,
                frames: outFrames,
                auChannels: auCh,
                isFloat: isFloat,
                sampleBytes: sampleBytes,
                nonInterleaved: isNonInterleaved,
                decaying: true
            )
            return false
        }

        // 环缓 → AU 采样率（按声道独立 Hermite，保留立体声）
        let rateConverted: [Int16]
        if dstRate == storeRate {
            let n = min(needStore, got) * ringCh
            rateConverted = Array(scratchStore.prefix(n))
        } else {
            rateConverted = resampleHermiteInterleaved(
                Array(scratchStore.prefix(got * ringCh)),
                channels: ringCh,
                from: storeRate,
                to: dstRate
            )
        }

        // 声道布局：ringCh → auCh
        var laid = layoutChannels(rateConverted, fromCh: ringCh, toCh: auCh, frames: outFrames)
        if laid.count < outFrames * auCh {
            let seedL = lastL
            let seedR = lastR
            let start = laid.count / auCh
            laid.append(contentsOf: repeatElement(Int16(0), count: outFrames * auCh - laid.count))
            fadePadInterleaved(&laid, channels: auCh, fromFrame: start, toFrame: outFrames, seedL: seedL, seedR: seedR)
        } else if laid.count > outFrames * auCh {
            laid = Array(laid.prefix(outFrames * auCh))
        }
        for i in 0..<(outFrames * auCh) { scratchOut[i] = laid[i] }

        // 慢淡入：~20ms，减轻音乐忽大忽小
        if envelope < 0.999 {
            let fade = min(max(1, dstRate / 50), outFrames)
            for i in 0..<fade {
                let a = envelope + (1.0 - envelope) * (Double(i + 1) / Double(fade))
                for c in 0..<auCh {
                    let idx = i * auCh + c
                    scratchOut[idx] = Int16(clamping: Int(Double(scratchOut[idx]) * a))
                }
            }
            envelope = 1.0
        }

        if outFrames > 0 {
            lastL = scratchOut[(outFrames - 1) * auCh]
            lastR = auCh > 1 ? scratchOut[(outFrames - 1) * auCh + 1] : lastL
        }

        writePCM(
            dst,
            frames: outFrames,
            channels: auCh,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: isNonInterleaved
        )

        // 注入峰：取第一声道
        var probe = [Int16](repeating: 0, count: outFrames)
        for i in 0..<outFrames { probe[i] = scratchOut[i * auCh] }
        CamPipelineDiag.shared.noteAudioOutput(samples: probe)
        probe.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                let asbdBits = Int(asbd.mBitsPerChannel)
                let asbdFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                let mismatch = (asbdBits > 0 && asbdBits / 8 != sampleBytes)
                    || ((asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger)) != 0
                        && asbdFloat != isFloat)
                CamPipelineDiag.shared.noteAudioQuality(
                    stage: .inject,
                    samples: base,
                    count: outFrames,
                    rateIn: storeRate,
                    rateOut: dstRate,
                    bytesPerSample: sampleBytes,
                    isFloat: isFloat,
                    formatMismatch: mismatch
                )
            }
        }
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

    private func frameDuration(_ chunk: Chunk) -> Double {
        let ch = max(1, chunk.channels)
        return Double(chunk.samples.count / ch) / Double(storeRate)
    }

    private func commitToRing(
        _ pcm: [Int16],
        channels: Int,
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
        chunks.append(Chunk(pts: startPTS, samples: pcm, channels: channels))
        packetCount += 1
        lastUpdate = Date()
        lastPTS = endPTS
        pruneLocked(before: endPTS - maxSeconds)
        lock.unlock()
        AVSyncClock.shared.noteAudioEndPTS(endPTS)
    }

    private func enqueuePending(
        _ pcm: [Int16],
        channels: Int,
        startPTS: Double,
        endPTS: Double,
        lead: Double
    ) {
        CamPipelineDiag.shared.noteAudioGate(
            accepted: false,
            endPTS: endPTS,
            reason: "pending",
            leadMs: lead * 1000.0
        )
        pcm.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                CamPipelineDiag.shared.noteAudioInput(samples: base, count: buf.count)
            }
        }
        lock.lock()
        pending.append(Chunk(pts: startPTS, samples: pcm, channels: channels))
        lastUpdate = Date()
        trimPendingLocked()
        lock.unlock()
    }

    private func trimPendingLocked() {
        while pendingSecondsLocked() > maxPendingSeconds, !pending.isEmpty {
            let old = pending.removeFirst()
            let dur = frameDuration(old)
            let start = nextAppendPTSLocked()
            let end = start + dur
            chunks.append(Chunk(pts: start, samples: old.samples, channels: old.channels))
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
        let end = last.pts + frameDuration(last)
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

    private func fillWithEnvelope(
        into dst: UnsafeMutableRawPointer,
        frames: Int,
        auChannels: Int,
        isFloat: Bool,
        sampleBytes: Int,
        nonInterleaved: Bool,
        decaying: Bool
    ) {
        ensureScratch(store: 1, out: frames * auChannels)
        // ~40ms 时间常数：真无包时慢落，避免和短抖叠成连续泵动
        let decayPerFrame = exp(-1.0 / (0.040 * Double(storeRate)))
        for i in 0..<frames {
            if decaying {
                envelope = max(0.0, envelope * decayPerFrame)
            }
            let l = Int16(clamping: Int(Double(lastL) * envelope))
            let r = Int16(clamping: Int(Double(lastR) * envelope))
            scratchOut[i * auChannels] = l
            if auChannels > 1 {
                scratchOut[i * auChannels + 1] = r
                for c in 2..<auChannels { scratchOut[i * auChannels + c] = l }
            }
        }
        if frames > 0 {
            lastL = scratchOut[(frames - 1) * auChannels]
            lastR = auChannels > 1 ? scratchOut[(frames - 1) * auChannels + 1] : lastL
        }
        writePCM(
            dst,
            frames: frames,
            channels: auChannels,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: nonInterleaved
        )
    }

    private func advancePlayhead(target: Double, duration: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if playhead < 0 || !playhead.isFinite {
            playhead = max(0, target)
        } else {
            let err = target - playhead
            if err > 0.04 {
                // 目标超前：软追上
                if err > 0.35 {
                    playhead += min(0.04, err * 0.15)
                } else {
                    playhead += min(maxPlayheadSlew, err * 0.18)
                }
            } else if err < -0.04 {
                // 目标落后：常见于画面 hold-last 钉住 mediaTime。
                // 禁止回拉播放头（回拉会反复读同一段 → 连续短断）；音频继续往前消耗 ring。
                // 仅当严重超前视频很多时才轻微刹一下，避免音画永久拉开。
                if err < -0.50 {
                    playhead += max(-0.008, err * 0.02)
                }
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
        isFloat: Bool,
        sampleBytes: Int,
        nonInterleaved: Bool
    ) {
        if nonInterleaved {
            let planeBytes = frames * sampleBytes
            for c in 0..<channels {
                let plane = dst.advanced(by: c * planeBytes)
                for i in 0..<frames {
                    let s = scratchOut[i * channels + c]
                    writeSample(plane.advanced(by: i * sampleBytes), sample: s, isFloat: isFloat, bytesPerSample: sampleBytes)
                }
            }
        } else {
            for i in 0..<frames {
                for c in 0..<channels {
                    let s = scratchOut[i * channels + c]
                    writeSample(
                        dst.advanced(by: (i * channels + c) * sampleBytes),
                        sample: s,
                        isFloat: isFloat,
                        bytesPerSample: sampleBytes
                    )
                }
            }
        }
    }

    /// 取出 frames 帧交错 PCM 到 buffer（长度 frames * storeChannels）
    private func peekStartingLocked(at startPTS: Double, into buffer: inout [Int16], frames: Int) -> Int {
        let ch = max(1, storeChannels)
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
            let chunkCh = max(1, chunk.channels)
            let chunkFrames = chunk.samples.count / chunkCh
            let chunkEnd = chunk.pts + Double(chunkFrames) / Double(storeRate)
            if chunkEnd <= cursor { continue }
            if chunk.pts > cursor + 0.02 {
                let gapFrames = min(
                    frames - written,
                    max(0, Int(((chunk.pts - cursor) * Double(storeRate)).rounded(.down)))
                )
                for i in 0..<gapFrames {
                    let a = 1.0 - Double(i + 1) / Double(gapFrames + 1)
                    let l = Int16(clamping: Int(Double(lastL) * max(envelope, 0.2) * a))
                    let r = Int16(clamping: Int(Double(lastR) * max(envelope, 0.2) * a))
                    let base = (written + i) * ch
                    buffer[base] = l
                    if ch > 1 { buffer[base + 1] = r }
                }
                written += gapFrames
                cursor = chunk.pts
                if written >= frames { break }
            }
            let offsetSec = max(0, cursor - chunk.pts)
            var sampleIdx = Int((offsetSec * Double(storeRate)).rounded(.down))
            if sampleIdx < 0 { sampleIdx = 0 }
            if sampleIdx >= chunkFrames { continue }
            let n = min(frames - written, chunkFrames - sampleIdx)
            for i in 0..<n {
                let dstBase = (written + i) * ch
                let srcBase = (sampleIdx + i) * chunkCh
                if chunkCh == ch {
                    for c in 0..<ch { buffer[dstBase + c] = chunk.samples[srcBase + c] }
                } else if chunkCh == 2, ch == 1 {
                    buffer[dstBase] = Int16(clamping: (Int(chunk.samples[srcBase]) + Int(chunk.samples[srcBase + 1])) / 2)
                } else {
                    buffer[dstBase] = chunk.samples[srcBase]
                    if ch > 1 { buffer[dstBase + 1] = chunk.samples[srcBase] }
                }
            }
            written += n
            cursor += Double(n) / Double(storeRate)
        }
        return written
    }

    private func nextAppendPTSLocked() -> Double {
        if let last = chunks.last {
            return last.pts + frameDuration(last)
        }
        return 0
    }

    private func pruneLocked(before pts: Double) {
        while let first = chunks.first {
            let end = first.pts + frameDuration(first)
            if end < pts {
                chunks.removeFirst()
            } else {
                break
            }
        }
    }

    private func layoutChannels(_ input: [Int16], fromCh: Int, toCh: Int, frames: Int) -> [Int16] {
        let fCh = max(1, fromCh)
        let tCh = max(1, toCh)
        let inFrames = input.count / fCh
        let use = min(frames, inFrames)
        var out = [Int16](repeating: 0, count: frames * tCh)
        for i in 0..<use {
            let l = input[i * fCh]
            let r = fCh > 1 ? input[i * fCh + 1] : l
            if tCh == 1 {
                out[i] = fCh > 1 ? Int16(clamping: (Int(l) + Int(r)) / 2) : l
            } else {
                out[i * tCh] = l
                out[i * tCh + 1] = r
                for c in 2..<tCh { out[i * tCh + c] = l }
            }
        }
        return out
    }

    private func fadePadInterleaved(
        _ buf: inout [Int16],
        channels: Int,
        fromFrame: Int,
        toFrame: Int,
        seedL: Int16,
        seedR: Int16
    ) {
        let n = toFrame - fromFrame
        guard n > 0 else { return }
        let ch = max(1, channels)
        for i in 0..<n {
            let a = 1.0 - Double(i + 1) / Double(n + 1)
            let base = (fromFrame + i) * ch
            buf[base] = Int16(clamping: Int(Double(seedL) * a))
            if ch > 1 {
                buf[base + 1] = Int16(clamping: Int(Double(seedR) * a))
            }
        }
    }

    private func resampleHermiteInterleaved(
        _ input: [Int16],
        channels: Int,
        from srcRate: Int,
        to dstRate: Int
    ) -> [Int16] {
        let ch = max(1, channels)
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return input }
        if srcRate == dstRate { return input }
        let inFrames = input.count / ch
        let outFrames = max(1, Int((Double(inFrames) * Double(dstRate) / Double(srcRate)).rounded()))
        var out = [Int16](repeating: 0, count: outFrames * ch)
        let last = inFrames - 1
        for c in 0..<ch {
            for i in 0..<outFrames {
                let srcPos = Double(i) * Double(srcRate) / Double(dstRate)
                let i1 = min(max(Int(srcPos), 0), last)
                let i0 = max(i1 - 1, 0)
                let i2 = min(i1 + 1, last)
                let i3 = min(i1 + 2, last)
                let t = srcPos - Double(i1)
                let y0 = Double(input[i0 * ch + c])
                let y1 = Double(input[i1 * ch + c])
                let y2 = Double(input[i2 * ch + c])
                let y3 = Double(input[i3 * ch + c])
                let c0 = y1
                let c1 = 0.5 * (y2 - y0)
                let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
                let v = ((c3 * t + c2) * t + c1) * t + c0
                out[i * ch + c] = Int16(clamping: Int(v.rounded()))
            }
        }
        return out
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
