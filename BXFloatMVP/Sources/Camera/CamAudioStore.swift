import AudioToolbox
import Foundation

/// 音频 ring + 连续播放头。
/// - AU 目标格式一次锁定后，入环即对齐采样率 → 注入回调免短块重采样（接近原音关键）
/// - 立体声保真；超前视频 pending/rebase；真欠载才包络
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
    private let defaultRate = 48_000
    /// AU 锁定后的环缓采样率；未锁定前用 48k
    private var lockedRate: Int = 0
    private var lockedAUChannels: Int = 0
    private var targetLocked = false
    /// 对外：当前环缓采样率
    var storeRate: Int { lockedRate > 0 ? lockedRate : defaultRate }
    /// 环缓声道（1 或 2）；由首包 / AU 锁定决定
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

    /// AU/采集首次（或变更）锁定目标格式：之后入环按此采样率，注入侧免 Hermite
    func lockTargetFromAU(sampleRate: Int, channels: Int, isFloat: Bool) {
        let rate = sampleRate > 0 ? sampleRate : defaultRate
        let ch = max(1, min(2, channels))
        lock.lock()
        let rateChanged = targetLocked && lockedRate > 0 && lockedRate != rate
        let firstLock = !targetLocked
        if firstLock || rateChanged {
            lockedRate = rate
            lockedAUChannels = ch
            targetLocked = true
            if rateChanged {
                chunks.removeAll(keepingCapacity: true)
                pending.removeAll(keepingCapacity: true)
                playhead = -1
                envelope = 1.0
            }
            let note = String(
                format: "AU-lock %dHz %dch float=%d → ring@%dHz",
                rate, ch, isFloat ? 1 : 0, storeRate
            )
            lock.unlock()
            CamPipelineDiag.shared.noteAudioFormat(note)
            NSLog("BXFloatAudio %@", note)
        } else {
            if lockedAUChannels != ch { lockedAUChannels = ch }
            lock.unlock()
        }
    }

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
        lockedRate = 0
        lockedAUChannels = 0
        targetLocked = false
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

        let rate = sampleRate > 0 ? sampleRate : defaultRate
        let ringRate = storeRate
        // 解码后音质：用第一声道峰/DC 代表源（对齐前）
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

        // 入环一次重采样到 AU 锁定率（包级），注入回调不再 Hermite
        let pcm: [Int16]
        if rate == ringRate {
            pcm = interleaved
        } else {
            pcm = resampleHermiteInterleaved(interleaved, channels: srcCh, from: rate, to: ringRate)
        }
        guard !pcm.isEmpty else { return }

        lock.lock()
        if chunks.isEmpty, pending.isEmpty {
            // AU 已锁声道则优先跟 AU；否则跟源
            if lockedAUChannels > 0 {
                storeChannels = lockedAUChannels
            } else {
                storeChannels = srcCh
            }
        }
        let ringCh = storeChannels
        lock.unlock()

        let ringPCM: [Int16]
        if srcCh == ringCh {
            ringPCM = pcm
        } else if srcCh == 1, ringCh == 2 {
            var up = [Int16](repeating: 0, count: pcm.count * 2)
            for i in 0..<pcm.count {
                up[i * 2] = pcm[i]
                up[i * 2 + 1] = pcm[i]
            }
            ringPCM = up
        } else {
            let framesN = pcm.count / max(1, srcCh)
            var down = [Int16](repeating: 0, count: framesN)
            if srcCh >= 2 {
                for i in 0..<framesN {
                    down[i] = Int16(clamping: (Int(pcm[i * srcCh]) + Int(pcm[i * srcCh + 1])) / 2)
                }
            } else {
                down = pcm
            }
            ringPCM = down
        }

        let note = "\(ringCh)ch \(ringRate)Hz s16 (src \(channels)ch \(rate)Hz lock=\(targetLocked ? 1 : 0))"
        if lastFormatNote != note {
            lastFormatNote = note
            CamPipelineDiag.shared.noteAudioFormat(note)
        }

        let mapped = pts >= 0 ? AVSyncClock.shared.mapPTS(pts) : -1
        let frameCount = ringPCM.count / max(1, ringCh)
        let duration = Double(frameCount) / Double(ringRate)
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
        // 每次注入锁定 AU 目标，使后续入环一次对齐
        lockTargetFromAU(sampleRate: dstRate, channels: auCh, isFloat: isFloat)

        let ringRate = storeRate
        let duration = Double(outFrames) / Double(dstRate)
        let ringCh = max(1, storeChannels)
        let needStore = max(1, Int((duration * Double(ringRate)).rounded(.up)) + 2)

        let target = AVSyncClock.shared.mediaTime()
        // 视频短停不再整段静音：环里有声就继续读。否则 AU写++ 但注入 pk 恒 0。
        if AVSyncClock.shared.shouldFreezeAudio(), bufferedSeconds() < 0.05 {
            CamPipelineDiag.shared.noteAudioUnderrun()
            Self.silence(into: dst, byteCount: byteCount)
            return false
        }

        ensureScratch(store: needStore * ringCh, out: outFrames * max(auCh, ringCh))

        // 禁止 2ms 超时空写：锁不上就短等，避免「环满却整段静音」
        var startPTS = advancePlayhead(target: target, duration: duration)
        var got = 0
        var usedTail = false
        lock.lock()
        got = peekStartingLocked(at: startPTS, into: &scratchStore, frames: needStore)
        if got <= 0 || Self.isNearSilent(scratchStore, frames: got, channels: ringCh) {
            if let snap = clampPlayheadIntoRingLocked(target: target, duration: duration) {
                playhead = snap + max(0, duration)
                startPTS = snap
                got = peekStartingLocked(at: startPTS, into: &scratchStore, frames: needStore)
            }
        }
        // 同步窗仍静音：直接读 ring 尾（保注入能量；不改目标延迟参数）
        if got <= 0 || Self.isNearSilent(scratchStore, frames: got, channels: ringCh) {
            let tailGot = peekRingTailLocked(into: &scratchStore, frames: needStore)
            if tailGot > 0, !Self.isNearSilent(scratchStore, frames: tailGot, channels: ringCh) {
                got = tailGot
                usedTail = true
            }
        }
        lock.unlock()
        if usedTail {
            NSLog("BXFloatAudio fill ring-tail fallback got=%d need=%d", got, needStore)
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

        // 环率已对齐 AU 时零重采样；仅锁定期前偶发走 Hermite
        let rateConverted: [Int16]
        if dstRate == ringRate {
            let n = min(needStore, got) * ringCh
            rateConverted = Array(scratchStore.prefix(n))
        } else {
            rateConverted = resampleHermiteInterleaved(
                Array(scratchStore.prefix(got * ringCh)),
                channels: ringCh,
                from: ringRate,
                to: dstRate
            )
        }

        // 声道布局：ringCh → auCh；不足用静音垫（禁止末样平台）
        var laid = layoutChannels(rateConverted, fromCh: ringCh, toCh: auCh, frames: outFrames)
        if laid.count < outFrames * auCh {
            laid.append(contentsOf: repeatElement(Int16(0), count: outFrames * auCh - laid.count))
        } else if laid.count > outFrames * auCh {
            laid = Array(laid.prefix(outFrames * auCh))
        }
        for i in 0..<(outFrames * auCh) { scratchOut[i] = laid[i] }

        // 从真欠载恢复：~30ms 淡入
        if envelope < 0.999 {
            let fade = min(max(1, dstRate / 33), outFrames)
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
        // 注入峰改由 AU paint 后的真实 ioData 探针记账（区分空写 vs 探针采错）
        return true
    }

    /// 从 ring 尾部取最近 frames（failsafe，不跟 mediaTime）
    private func peekRingTailLocked(into buffer: inout [Int16], frames: Int) -> Int {
        guard frames > 0, let first = chunks.first, let last = chunks.last else { return 0 }
        let lastEnd = last.pts + frameDuration(last)
        let dur = Double(frames) / Double(storeRate)
        let start = max(first.pts, lastEnd - dur)
        playhead = lastEnd
        return peekStartingLocked(at: start, into: &buffer, frames: frames)
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
        // 面板「音频包」要反映「已收到推流音频」；pending 也算，避免有声却显示 0
        packetCount += 1
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
            // packetCount 已在 enqueuePending 计过，这里只转入 ring
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
        if let snap = clampPlayheadIntoRingLocked(target: target, duration: duration),
           playhead < 0 || !playhead.isFinite
            || playhead < snap - 0.08 || playhead > snap + 0.35 {
            // 读头未初始化或已偏离 ring 可读窗：硬对齐，避免整段静音垫当「有数据」
            playhead = snap
        } else if playhead < 0 || !playhead.isFinite {
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
            // 软追后仍夹在 ring 内，禁止跑出末端空读
            if let snap = clampPlayheadIntoRingLocked(target: playhead, duration: duration) {
                if playhead > snap + 0.02 {
                    playhead = snap
                } else if playhead < snap - 0.25 {
                    // 严重落后（软追太慢）：跳到窗内，修「环满却注入 pk=0」
                    playhead = snap
                }
            }
        }
        let start = playhead
        playhead += max(0, duration)
        return start
    }

    /// ring 可读起点：夹到 [first, lastEnd - duration]
    private func clampPlayheadIntoRingLocked(target: Double, duration: Double) -> Double? {
        guard let first = chunks.first, let last = chunks.last else { return nil }
        let firstPts = first.pts
        let lastEnd = last.pts + frameDuration(last)
        guard lastEnd > firstPts + 0.001 else { return nil }
        let hi = max(firstPts, lastEnd - max(duration, 0.02))
        let t = target.isFinite ? target : firstPts
        return min(max(t, firstPts), hi)
    }

    private static func isNearSilent(_ buf: [Int16], frames: Int, channels: Int) -> Bool {
        let ch = max(1, channels)
        let n = min(frames, buf.count / ch)
        guard n > 8 else { return frames > 0 }
        var peak: Int32 = 0
        let step = max(1, n / 64)
        var i = 0
        while i < n {
            let a = abs(Int32(buf[i * ch]))
            if a > peak { peak = a }
            if peak > 200 { return false }
            i += step
        }
        return peak <= 200
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
        // 起点远在首包之前：直接跳到首包，禁止整段静音垫冒充 got>0（注入 pk=0 根因）
        let firstPts = chunks.first!.pts
        if t < firstPts - 0.05 {
            t = firstPts
        }
        pruneLocked(before: t - 0.5)
        guard !chunks.isEmpty else { return 0 }

        var written = 0
        var cursor = t
        for chunk in chunks {
            if written >= frames { break }
            let chunkCh = max(1, chunk.channels)
            let chunkFrames = chunk.samples.count / chunkCh
            let chunkEnd = chunk.pts + Double(chunkFrames) / Double(storeRate)
            if chunkEnd <= cursor { continue }
            if chunk.pts > cursor + 0.02 {
                let gapSec = chunk.pts - cursor
                if gapSec > 0.08 {
                    // 大缺口：跳到包头继续读真 PCM，不填静音（静音垫会让注入探针记 0）
                    cursor = chunk.pts
                } else {
                    let gapFrames = min(
                        frames - written,
                        max(0, Int((gapSec * Double(storeRate)).rounded(.down)))
                    )
                    // 小缺口：静音，禁止末样平台造成电流/短断感
                    for i in 0..<gapFrames {
                        let base = (written + i) * ch
                        buffer[base] = 0
                        if ch > 1 { buffer[base + 1] = 0 }
                    }
                    written += gapFrames
                    cursor = chunk.pts
                    if written >= frames { break }
                }
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
