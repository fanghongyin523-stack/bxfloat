import AudioToolbox
import Foundation

/// 音频 ring + 固定延迟连续拷贝（对标 VCamTang fillAudioBufferList）。
/// - AVSYNC：play/hold/freeze-audio/drop-old——禁止 soft-rate 拧播头
/// - AU 锁定后入环 SRC 一次；注入侧直拷连续 PCM
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
    /// 环上限；超则 drop-old（对标 capLiveLatency / backlog）
    private let maxSeconds: Double = 2.50
    private let maxPendingSeconds: Double = 1.20
    /// 入环后活延迟上限：超过则剪旧，保持 ~目标延迟可读
    private let capLiveLatencySec: Double = 1.80
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
    /// 固定目标延迟连续读（~1.2s，对标参考 1～1.5s）
    private let fixedLatencySec: Double = 1.20
    private var lastL: Int16 = 0
    private var lastR: Int16 = 0
    /// DC 阻断状态（消面板大 dc，非增益/NR）
    private var dcX1L: Double = 0
    private var dcY1L: Double = 0
    private var dcX1R: Double = 0
    private var dcY1R: Double = 0
    /// 监听专用读头（不抢注入 playhead）
    private var monitorPlayhead: Double = -1
    /// 注入写出后的环听缓冲（~2s 交错 s16）——听:注 与录制同内容
    private var injectTap: [Int16] = []
    private var injectTapFrames: Int = 0
    private var injectTapWrite: Int = 0
    private var injectTapRead: Int = 0
    private var injectTapCh: Int = 1
    private var injectTapRate: Int = 0
    /// 1=正常；欠载时向 0 衰减；恢复后淡入
    private var envelope: Double = 1.0

    private var scratchStore: [Int16] = Array(repeating: 0, count: 8192)
    private var scratchOut: [Int16] = Array(repeating: 0, count: 4096)

    private(set) var packetCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1
    private(set) var lastFormatNote = ""

    private init() {}

    /// AU/采集首次（或变更）锁定目标格式：之后入环按此采样率，注入侧直拷
    func lockTargetFromAU(sampleRate: Int, channels: Int, isFloat: Bool) {
        let rate = sampleRate > 0 ? sampleRate : defaultRate
        let ch = max(1, min(2, channels))
        lock.lock()
        let prevRate = lockedRate > 0 ? lockedRate : defaultRate
        let rateChanged = targetLocked && lockedRate > 0 && lockedRate != rate
        let firstLock = !targetLocked
        if firstLock || rateChanged {
            lockedRate = rate
            lockedAUChannels = ch
            targetLocked = true
            // 首次 AU 锁到与默认/旧环不同的速率时也清环：否则 48k 块按 44.1k 读 PTS，peek 易空/静音
            let mustFlush = rateChanged || (firstLock && prevRate != rate && (!chunks.isEmpty || !pending.isEmpty))
            if mustFlush {
                chunks.removeAll(keepingCapacity: true)
                pending.removeAll(keepingCapacity: true)
                playhead = -1
                monitorPlayhead = -1
                envelope = 1.0
                dcX1L = 0; dcY1L = 0; dcX1R = 0; dcY1R = 0
            }
            let note = String(
                format: "AU-lock %dHz %dch float=%d → ring@%dHz flush=%d",
                rate, ch, isFloat ? 1 : 0, storeRate, mustFlush ? 1 : 0
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
        monitorPlayhead = -1
        lastL = 0
        lastR = 0
        envelope = 1.0
        dcX1L = 0; dcY1L = 0; dcX1R = 0; dcY1R = 0
        storeChannels = 1
        lockedRate = 0
        lockedAUChannels = 0
        targetLocked = false
        lastFormatNote = ""
        injectTap.removeAll(keepingCapacity: true)
        injectTapFrames = 0
        injectTapWrite = 0
        injectTapRead = 0
        injectTapCh = 1
        injectTapRate = 0
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

        // 入环一次块级 SRC 对齐 AU 率（格式平面）；禁止在播出时钟上 soft-rate
        let pcm: [Int16]
        if rate == ringRate {
            pcm = interleaved
        } else {
            pcm = resampleLinearInterleaved(interleaved, channels: srcCh, from: rate, to: ringRate)
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

        let rs = (rate == ringRate) ? "rsamp=1:1" : "rsamp=in→ring"
        let note = "\(ringCh)ch \(ringRate)Hz s16 \(rs) (src \(channels)ch \(rate)Hz lock=\(targetLocked ? 1 : 0))"
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

    /// 拉交错 s16：固定延迟连续拷贝 ring（禁止软拉伸/每帧 force）。返回峰。
    @discardableResult
    func pullInterleavedS16(
        into dst: UnsafeMutablePointer<Int16>,
        frames: Int,
        channels: Int,
        sampleRate: Int
    ) -> Int32 {
        let auCh = max(1, min(8, channels))
        let dstRate = sampleRate > 0 ? sampleRate : storeRate
        lockTargetFromAU(sampleRate: dstRate, channels: min(2, auCh), isFloat: false)

        let ringRate = storeRate
        let ringCh = max(1, storeChannels)
        let duration = Double(frames) / Double(dstRate)
        // 1:1 时精确 frames；异率才多取边沿
        let needStore = (dstRate == ringRate)
            ? max(1, frames)
            : max(1, Int((duration * Double(ringRate)).rounded(.up)) + 2)
        ensureScratch(store: needStore * ringCh + 64, out: frames * auCh)

        if AVSyncClock.shared.shouldFreezeAudio(), bufferedSeconds() < 0.05 {
            fillHoldSamples(dst, frames: frames, channels: auCh)
            CamPipelineDiag.shared.notePaintGate(ringPk: 0, peekPk: 0, convPk: 0, dstPk: 0, forced: false)
            return max(1, abs(Int32(lastL)))
        }

        var got = 0
        var seamJump = false
        var startPTS = 0.0
        var ringPk: Int32 = 0
        var peekPk: Int32 = 0
        var localStore: [Int16] = []

        lock.lock()
        ringPk = max(peakOfLastChunkLocked(), peakOfAnyChunkLocked())
        guard let first = chunks.first, let last = chunks.last, ringPk > 0 else {
            lock.unlock()
            fillHoldSamples(dst, frames: frames, channels: auCh)
            CamPipelineDiag.shared.notePaintGate(ringPk: 0, peekPk: 0, convPk: 0, dstPk: 0, forced: false)
            return max(1, abs(Int32(lastL)))
        }
        let lastEnd = last.pts + frameDuration(last)
        let firstPts = first.pts
        // 连续传声：播头只随已读 PCM 前进，禁止「追 desired」硬跳（听感会一帧帧蹦）。
        // 仅在未初始化 / 被 drop-old 剪到窗外 / 跑出环尾 时对齐一次。
        let desired = max(firstPts, lastEnd - fixedLatencySec)
        let hi = max(firstPts, lastEnd - max(duration, 0.004))
        if playhead < 0 || !playhead.isFinite {
            playhead = desired
            seamJump = true
        } else if playhead < firstPts - 0.001 {
            playhead = firstPts
            seamJump = true
        } else if playhead > lastEnd + 0.001 {
            playhead = hi
            seamJump = true
        }
        if playhead > hi {
            playhead = hi
        }
        startPTS = playhead
        var endPTS = startPTS
        got = peekStartingLocked(at: startPTS, into: &scratchStore, frames: needStore, endPTS: &endPTS)
        peekPk = Self.peakOf(scratchStore, frames: got, channels: ringCh)
        // 欠载：不重锚定；有多少吃多少，其余 hold
        let consumed = min(needStore, max(0, got))
        if consumed > 0 {
            localStore = Array(scratchStore.prefix(consumed * ringCh))
            if endPTS > startPTS + 0.0001 {
                playhead = endPTS
            } else {
                playhead = startPTS + Double(consumed) / Double(ringRate)
            }
        }
        lock.unlock()

        if consumed <= 0 || localStore.isEmpty {
            fillHoldSamples(dst, frames: frames, channels: auCh)
            CamPipelineDiag.shared.notePaintGate(
                ringPk: ringPk, peekPk: peekPk, convPk: 0, dstPk: 0, forced: false
            )
            // 已写 hold：峰按末样；禁回 0 触发 AU 侧静音垫
            return max(1, abs(Int32(lastL)))
        }

        // 环率=AU：直拷连续 PCM；异率仅块级线性 SRC（非 soft-rate 追环）
        let rateConverted: [Int16]
        if dstRate == ringRate, consumed >= frames {
            rateConverted = Array(localStore.prefix(frames * ringCh))
        } else if dstRate == ringRate {
            rateConverted = localStore
        } else {
            rateConverted = resampleLinearInterleaved(
                localStore, channels: ringCh, from: ringRate, to: dstRate
            )
        }
        var laid = layoutChannels(rateConverted, fromCh: ringCh, toCh: auCh, frames: frames)
        let haveFrames = min(frames, rateConverted.count / max(1, ringCh))
        if haveFrames < frames {
            let seedL = haveFrames > 0 ? laid[(haveFrames - 1) * auCh] : lastL
            let seedR = haveFrames > 0
                ? (auCh > 1 ? laid[(haveFrames - 1) * auCh + 1] : seedL)
                : lastR
            // 欠载：末样 hold；不标 seamJump，避免每欠载交叉淡把声拧碎
            holdPadInterleaved(
                &laid, channels: auCh,
                fromFrame: haveFrames, toFrame: frames,
                seedL: seedL, seedR: seedR
            )
        } else if laid.count > frames * auCh {
            laid = Array(laid.prefix(frames * auCh))
        }

        // 接缝 / 硬跳：~10ms 交叉淡；相邻块大台阶也抹 ~2ms（消 30ms 级微断听感）
        let stepL = frames > 0 ? abs(Int(laid[0]) - Int(lastL)) : 0
        let needFade = seamJump || stepL > 2500
        if needFade {
            let fadeN = min(frames, max(1, seamJump ? (dstRate / 100) : (dstRate / 500)))
            for i in 0..<fadeN {
                let a = Double(i + 1) / Double(fadeN)
                let inv = 1.0 - a
                let idxL = i * auCh
                laid[idxL] = Int16(clamping: Int(Double(laid[idxL]) * a + Double(lastL) * inv))
                if auCh > 1 {
                    let idxR = idxL + 1
                    laid[idxR] = Int16(clamping: Int(Double(laid[idxR]) * a + Double(lastR) * inv))
                }
            }
        }

        // 一阶 DC 阻断（R≈0.995），消大直流/电流感；不改增益曲线
        applyDCBlocker(&laid, frames: frames, channels: auCh)
        // 禁止顶满削波：软顶 ~-1.2dBFS（消全频尖刺/脏写，非调音质）
        applyPeakCeiling(&laid, frames: frames, channels: auCh)

        if frames > 0 {
            lastL = laid[(frames - 1) * auCh]
            lastR = auCh > 1 ? laid[(frames - 1) * auCh + 1] : lastL
        }
        envelope = 1.0

        let convPk = Self.peakOf(laid, frames: frames, channels: auCh)
        for i in 0..<(frames * auCh) { dst[i] = laid[i] }
        // 预写 tap；AU 写后还会用真实缓冲覆盖（听:注=录轨）
        noteInjectTap(laid, frames: frames, channels: auCh, rate: dstRate)

        CamPipelineDiag.shared.notePaintGate(
            ringPk: ringPk, peekPk: peekPk, convPk: convPk, dstPk: convPk, forced: false
        )
        if convPk > 0 {
            var mono = [Int16](repeating: 0, count: frames)
            for i in 0..<frames { mono[i] = laid[i * auCh] }
            CamPipelineDiag.shared.noteAudioOutput(samples: mono)
            mono.withUnsafeBufferPointer { buf in
                if let p = buf.baseAddress {
                    CamPipelineDiag.shared.noteAudioQuality(
                        stage: .inject,
                        samples: p,
                        count: frames,
                        rateIn: ringRate,
                        rateOut: dstRate,
                        bytesPerSample: 2,
                        isFloat: false
                    )
                }
            }
        }
        return convPk
    }

    /// 欠载：续 lastL/R，禁止交还原麦 / 静音块
    private func fillHoldSamples(_ dst: UnsafeMutablePointer<Int16>, frames: Int, channels: Int) {
        let ch = max(1, channels)
        for i in 0..<frames {
            dst[i * ch] = lastL
            if ch > 1 { dst[i * ch + 1] = lastR }
            for c in 2..<ch { dst[i * ch + c] = lastL }
        }
    }

    private func applyDCBlocker(_ buf: inout [Int16], frames: Int, channels: Int) {
        let ch = max(1, channels)
        let r = 0.995
        for i in 0..<frames {
            let xL = Double(buf[i * ch])
            let yL = xL - dcX1L + r * dcY1L
            dcX1L = xL
            dcY1L = yL
            buf[i * ch] = Int16(clamping: Int(yL.rounded()))
            if ch > 1 {
                let xR = Double(buf[i * ch + 1])
                let yR = xR - dcX1R + r * dcY1R
                dcX1R = xR
                dcY1R = yR
                buf[i * ch + 1] = Int16(clamping: Int(yR.rounded()))
            }
        }
    }

    /// 硬顶满：给抖音编码留余量。录回放顶 0dBFS=注入过烫→削波/电流尖刺。
    /// 目标约 -8dBFS（±13000），不是「调响」，是传声不脏。
    private func applyPeakCeiling(_ buf: inout [Int16], frames: Int, channels: Int) {
        let lim = 13_000.0
        let knee = 9_000.0
        let ch = max(1, channels)
        for i in 0..<(frames * ch) {
            let x = Double(buf[i])
            let ax = abs(x)
            if ax <= knee {
                continue
            }
            let y: Double
            if ax >= lim {
                y = lim
            } else {
                // knee→lim 软过渡，过 lim 硬夹
                let t = (ax - knee) / (lim - knee)
                y = knee + (lim - knee) * (t * (2.0 - t))
            }
            buf[i] = Int16(clamping: Int((x < 0 ? -y : y).rounded()))
        }
    }

    /// AU 写后回灌听:注（与录制轨同内容）
    func noteInjectPCMFromAU(_ samples: [Int16], frames: Int, channels: Int, rate: Int) {
        noteInjectTap(samples, frames: frames, channels: channels, rate: rate)
    }

    /// 环听：与注入同策略——环尾前固定延迟连续读，不抢注入 playhead
    @discardableResult
    func pullMonitorRingS16(
        into dst: UnsafeMutablePointer<Int16>,
        frames: Int,
        channels: Int
    ) -> Int32 {
        let outCh = max(1, min(2, channels))
        let ringRate = storeRate
        let ringCh = max(1, storeChannels)
        guard frames > 0, ringRate > 0 else { return 0 }
        ensureScratch(store: frames * ringCh + 64, out: frames * outCh)
        lock.lock()
        defer { lock.unlock() }
        guard let first = chunks.first, let last = chunks.last else { return 0 }
        let lastEnd = last.pts + frameDuration(last)
        let dur = Double(frames) / Double(ringRate)
        let desired = max(first.pts, lastEnd - fixedLatencySec)
        let hi = max(first.pts, lastEnd - max(dur, 0.004))
        if monitorPlayhead < 0 || !monitorPlayhead.isFinite {
            monitorPlayhead = desired
        } else if monitorPlayhead < first.pts - 0.001 {
            monitorPlayhead = first.pts
        } else if monitorPlayhead > lastEnd + 0.001 {
            monitorPlayhead = hi
        }
        if monitorPlayhead > hi { monitorPlayhead = hi }
        let start = monitorPlayhead
        var endPTS = start
        let got = peekStartingLocked(at: start, into: &scratchStore, frames: frames, endPTS: &endPTS)
        if got <= 0 {
            return 0
        }
        if endPTS > start + 0.0001 {
            monitorPlayhead = endPTS
        } else {
            monitorPlayhead = start + Double(got) / Double(ringRate)
        }
        var laid = layoutChannels(
            Array(scratchStore.prefix(got * ringCh)),
            fromCh: ringCh, toCh: outCh, frames: frames
        )
        let have = min(frames, got)
        if have < frames {
            let seedL = have > 0 ? laid[(have - 1) * outCh] : 0
            let seedR = (outCh > 1 && have > 0) ? laid[(have - 1) * outCh + 1] : seedL
            holdPadInterleaved(
                &laid, channels: outCh,
                fromFrame: have, toFrame: frames,
                seedL: seedL, seedR: seedR
            )
        }
        for i in 0..<(frames * outCh) { dst[i] = laid[i] }
        return Self.peakOf(laid, frames: frames, channels: outCh)
    }

    /// 注听：独立读头连续消耗注入 tap（与环听对照分锅）
    @discardableResult
    func pullMonitorInjectS16(
        into dst: UnsafeMutablePointer<Int16>,
        frames: Int,
        channels: Int
    ) -> Int32 {
        let outCh = max(1, min(2, channels))
        lock.lock()
        defer { lock.unlock() }
        guard injectTapFrames > 0, injectTapCh > 0, !injectTap.isEmpty else { return 0 }
        let ch = injectTapCh
        let cap = injectTapFrames
        // 可读帧：写头追上读头的环距；落后太多则跳到写头后 0.25s
        var avail = injectTapWrite - injectTapRead
        if avail < 0 { avail += cap }
        if avail > cap - (cap / 8) {
            // 读太慢：跳到近写头，留 ~0.25s
            let keep = min(cap / 4, max(1, (injectTapRate > 0 ? injectTapRate : storeRate) / 4))
            injectTapRead = injectTapWrite - keep
            while injectTapRead < 0 { injectTapRead += cap }
            avail = keep
        }
        let take = min(frames, max(0, avail))
        for i in 0..<take {
            let srcFrame = (injectTapRead + i) % cap
            let l = injectTap[srcFrame * ch]
            let r = ch > 1 ? injectTap[srcFrame * ch + 1] : l
            if outCh == 1 {
                dst[i] = ch > 1 ? Int16(clamping: (Int(l) + Int(r)) / 2) : l
            } else {
                dst[i * outCh] = l
                dst[i * outCh + 1] = r
            }
        }
        injectTapRead = (injectTapRead + take) % cap
        if take < frames {
            let seedL = take > 0 ? dst[(take - 1) * outCh] : 0
            let seedR = (outCh > 1 && take > 0) ? dst[(take - 1) * outCh + 1] : seedL
            for i in take..<frames {
                let a = 1.0 - Double(i - take + 1) / Double(frames - take + 1)
                dst[i * outCh] = Int16(clamping: Int(Double(seedL) * a))
                if outCh > 1 {
                    dst[i * outCh + 1] = Int16(clamping: Int(Double(seedR) * a))
                }
            }
        }
        var peak: Int32 = 0
        for i in 0..<frames {
            let a = abs(Int32(dst[i * outCh]))
            if a > peak { peak = a }
        }
        return peak
    }

    var monitorFormat: (rate: Int, channels: Int) {
        (storeRate, max(1, storeChannels))
    }

    private func noteInjectTap(_ samples: [Int16], frames: Int, channels: Int, rate: Int) {
        let ch = max(1, min(2, channels))
        let want = max(rate * 2, 8192) // ~2s
        lock.lock()
        defer { lock.unlock() }
        if injectTapRate != rate || injectTapCh != ch || injectTapFrames != want {
            injectTap = Array(repeating: 0, count: want * ch)
            injectTapFrames = want
            injectTapWrite = 0
            injectTapRead = 0
            injectTapCh = ch
            injectTapRate = rate
        }
        guard injectTapFrames > 0 else { return }
        for i in 0..<frames {
            let dstBase = injectTapWrite * ch
            let srcBase = i * channels
            injectTap[dstBase] = samples[srcBase]
            if ch > 1 {
                injectTap[dstBase + 1] = channels > 1 ? samples[srcBase + 1] : samples[srcBase]
            }
            injectTapWrite += 1
            if injectTapWrite >= injectTapFrames { injectTapWrite = 0 }
        }
    }

    /// 把已拉好的交错 s16 按 asbd 写入 dst（旧 PaintFrames 兜底）
    @discardableResult
    func fillFromInterleavedS16(
        _ samples: [Int16],
        into dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        asbd: AudioStreamBasicDescription
    ) -> Bool {
        let auCh = max(1, channels)
        var isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var sampleBytes = max(1, Int(asbd.mBitsPerChannel) / 8)
        if isFloat, sampleBytes < 4 { sampleBytes = 4 }
        if !isFloat, sampleBytes == 4, (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0 {
            isFloat = true
        }
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        ensureScratch(store: 1, out: frames * auCh)
        let n = min(samples.count, frames * auCh)
        for i in 0..<n { scratchOut[i] = samples[i] }
        for i in n..<(frames * auCh) { scratchOut[i] = 0 }
        writePCM(
            dst,
            frames: frames,
            channels: auCh,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: isNonInterleaved
        )
        let dstPk = Self.peakOfRaw(
            dst, frames: frames, channels: auCh,
            isFloat: isFloat, sampleBytes: sampleBytes, nonInterleaved: isNonInterleaved
        )
        return dstPk > 0
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
        guard sampleBytes > 0, auCh > 0 else { return false }
        let outFrames = byteCount / (sampleBytes * auCh)
        guard outFrames > 0 else { return false }

        let dstRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : storeRate
        // 与 AU PullS16 同一路：固定延迟连续拷贝，禁止 mediaTime soft-rate 追环
        ensureScratch(store: outFrames * max(1, storeChannels) + 64, out: outFrames * auCh)
        let pk = scratchOut.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return pullInterleavedS16(
                into: base,
                frames: outFrames,
                channels: auCh,
                sampleRate: dstRate
            )
        }
        if pk <= 0 {
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
        writePCM(
            dst,
            frames: outFrames,
            channels: auCh,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: isNonInterleaved
        )
        return true
    }
    /// 从 ring 尾部取最近 frames（failsafe，不跟 mediaTime）
    private func peekRingTailLocked(into buffer: inout [Int16], frames: Int) -> Int {
        guard frames > 0, let first = chunks.first, let last = chunks.last else { return 0 }
        let lastEnd = last.pts + frameDuration(last)
        let dur = Double(frames) / Double(storeRate)
        let start = max(first.pts, lastEnd - dur)
        var end = start
        let got = peekStartingLocked(at: start, into: &buffer, frames: frames, endPTS: &end)
        playhead = got > 0 ? end : lastEnd
        return got
    }

    private func peakOfLastChunkLocked() -> Int32 {
        guard let last = chunks.last else { return 0 }
        return Self.peakOf(last.samples, frames: last.samples.count / max(1, last.channels), channels: last.channels)
    }

    private func peakOfAnyChunkLocked() -> Int32 {
        var best: Int32 = 0
        for chunk in chunks.suffix(8) {
            let pk = Self.peakOf(
                chunk.samples,
                frames: chunk.samples.count / max(1, chunk.channels),
                channels: chunk.channels
            )
            if pk > best { best = pk }
            if best > 4000 { break }
        }
        return best
    }

    /// 从最新 chunk 往前拼够 frames（忽略 PTS，专治 peek 空读）
    private func copyLatestFramesLocked(into buffer: inout [Int16], frames: Int) -> Int {
        let ch = max(1, storeChannels)
        guard frames > 0, !chunks.isEmpty else { return 0 }
        if buffer.count < frames * ch {
            buffer = Array(repeating: 0, count: frames * ch)
        }
        var need = frames
        var pieces: [(samples: [Int16], frames: Int, channels: Int)] = []
        for chunk in chunks.reversed() {
            if need <= 0 { break }
            let cch = max(1, chunk.channels)
            let cf = chunk.samples.count / cch
            guard cf > 0 else { continue }
            let take = min(need, cf)
            let start = (cf - take) * cch
            let slice = Array(chunk.samples[start..<(start + take * cch)])
            pieces.append((slice, take, cch))
            need -= take
        }
        guard need < frames else { return 0 }
        // pieces 从新到旧；反转成时间正序
        pieces.reverse()
        var written = 0
        for piece in pieces {
            let laid = layoutChannels(piece.samples, fromCh: piece.channels, toCh: ch, frames: piece.frames)
            for i in 0..<piece.frames {
                let dstBase = (written + i) * ch
                let srcBase = i * ch
                for c in 0..<ch {
                    buffer[dstBase + c] = laid[srcBase + c]
                }
            }
            written += piece.frames
        }
        return written
    }

    private static func peakOf(_ buf: [Int16], frames: Int, channels: Int) -> Int32 {
        let ch = max(1, channels)
        let n = min(max(0, frames), buf.count / ch)
        guard n > 0 else { return 0 }
        var peak: Int32 = 0
        let step = max(1, n / 128)
        var i = 0
        while i < n {
            let a = abs(Int32(buf[i * ch]))
            if a > peak { peak = a }
            i += step
        }
        return peak
    }

    private static func peakOfRaw(
        _ dst: UnsafeRawPointer,
        frames: Int,
        channels: Int,
        isFloat: Bool,
        sampleBytes: Int,
        nonInterleaved: Bool
    ) -> Int32 {
        let ch = max(1, channels)
        guard frames > 0, sampleBytes > 0 else { return 0 }
        var peak: Int32 = 0
        let step = max(1, frames / 128)
        var i = 0
        while i < frames {
            let s: Int16
            if nonInterleaved {
                // 第一平面
                let off = i * sampleBytes
                if isFloat, sampleBytes == 4 {
                    var fl: Float = 0
                    memcpy(&fl, dst.advanced(by: off), 4)
                    s = Int16(clamping: Int((Double(fl) * 32767.0).rounded()))
                } else if sampleBytes == 2 {
                    var v: Int16 = 0
                    memcpy(&v, dst.advanced(by: off), 2)
                    s = v
                } else {
                    s = 0
                }
            } else {
                let off = (i * ch) * sampleBytes
                if isFloat, sampleBytes == 4 {
                    var fl: Float = 0
                    memcpy(&fl, dst.advanced(by: off), 4)
                    s = Int16(clamping: Int((Double(fl) * 32767.0).rounded()))
                } else if sampleBytes == 2 {
                    var v: Int16 = 0
                    memcpy(&v, dst.advanced(by: off), 2)
                    s = v
                } else {
                    s = 0
                }
            }
            let a = abs(Int32(s))
            if a > peak { peak = a }
            i += step
        }
        return peak
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
        capLiveLatencyLocked(endPTS: endPTS)
        lock.unlock()
        AVSyncClock.shared.noteAudioEndPTS(endPTS)
    }

    /// 对标 VCamTang capLiveLatency：积压过大剪旧，禁止靠软变速消化 backlog
    private func capLiveLatencyLocked(endPTS: Double) {
        guard let first = chunks.first else { return }
        let buffered = endPTS - first.pts
        guard buffered > capLiveLatencySec else { return }
        let keepFrom = endPTS - capLiveLatencySec
        pruneLocked(before: keepFrom)
        if playhead >= 0, playhead < keepFrom {
            playhead = keepFrom
        }
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
        // fillContinuous 兜底：与 pull 同策略——只前进，不追 desired
        if let last = chunks.last, let first = chunks.first {
            let lastEnd = last.pts + frameDuration(last)
            let desired = max(first.pts, lastEnd - fixedLatencySec)
            let hi = max(first.pts, lastEnd - max(duration, 0.004))
            if playhead < 0 || !playhead.isFinite {
                playhead = desired
            } else if playhead < first.pts - 0.001 {
                playhead = first.pts
            } else if playhead > lastEnd + 0.001 {
                playhead = hi
            }
            if playhead > hi { playhead = hi }
        } else if let snap = clampPlayheadIntoRingLocked(target: target, duration: duration) {
            playhead = snap
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

    /// 取出 frames 帧交错 PCM 到 buffer（长度 frames * storeChannels）。
    /// endPTS = 媒体读头真实终点（含包间 hold），供 playhead 连续推进。
    private func peekStartingLocked(
        at startPTS: Double,
        into buffer: inout [Int16],
        frames: Int,
        endPTS: inout Double
    ) -> Int {
        let ch = max(1, storeChannels)
        guard frames > 0, !chunks.isEmpty else {
            endPTS = startPTS
            return 0
        }
        let need = frames * ch
        if buffer.count < need {
            buffer = Array(repeating: 0, count: need)
        }

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
        guard !chunks.isEmpty else {
            endPTS = t
            return 0
        }

        var written = 0
        var cursor = t
        var holdL = lastL
        var holdR = lastR
        for chunk in chunks {
            if written >= frames { break }
            let chunkCh = max(1, chunk.channels)
            let chunkFrames = chunk.samples.count / chunkCh
            let chunkEnd = chunk.pts + Double(chunkFrames) / Double(storeRate)
            if chunkEnd <= cursor { continue }
            if chunk.pts > cursor + 0.001 {
                // 包间缺口必须占时间轴（禁跳读甩后 playhead→短剁）
                // <80ms：末样 hold 抹微缝；≥80ms：静音占位（切歌等源侧长洞原样保留）
                let gapSec = chunk.pts - cursor
                let gapFrames = min(frames - written, max(0, Int((gapSec * Double(storeRate)).rounded())))
                let micro = gapSec < 0.080
                if gapFrames > 0 {
                    for i in 0..<gapFrames {
                        let base = (written + i) * ch
                        if micro {
                            buffer[base] = holdL
                            if ch > 1 { buffer[base + 1] = holdR }
                        } else {
                            buffer[base] = 0
                            if ch > 1 { buffer[base + 1] = 0 }
                        }
                    }
                    written += gapFrames
                    cursor += Double(gapFrames) / Double(storeRate)
                }
                if written >= frames { break }
                cursor = max(cursor, chunk.pts)
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
            if n > 0 {
                holdL = buffer[(written - 1) * ch]
                if ch > 1 { holdR = buffer[(written - 1) * ch + 1] }
            }
        }
        endPTS = cursor
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

    /// 欠载垫：末样 hold，禁止淡向 0（静音缝=可闻短剁）
    private func holdPadInterleaved(
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
        if buf.count < toFrame * ch {
            buf.append(contentsOf: repeatElement(Int16(0), count: toFrame * ch - buf.count))
        }
        for i in 0..<n {
            let base = (fromFrame + i) * ch
            buf[base] = seedL
            if ch > 1 { buf[base + 1] = seedR }
            for c in 2..<ch { buf[base + c] = seedL }
        }
    }

    /// 块级 SRC（仅格式对齐，禁止当播头 soft-rate）。
    /// 用 Catmull-Rom，比线性少发闷/齿音；仍只在入环或异率 AU 时调用一次。
    private func resampleLinearInterleaved(
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
        let last = max(0, inFrames - 1)
        func at(_ frame: Int, _ c: Int) -> Double {
            let f = min(max(frame, 0), last)
            return Double(input[f * ch + c])
        }
        for c in 0..<ch {
            for i in 0..<outFrames {
                let srcPos = Double(i) * Double(srcRate) / Double(dstRate)
                let i1 = min(max(Int(srcPos.rounded(.down)), 0), last)
                let i0 = max(i1 - 1, 0)
                let i2 = min(i1 + 1, last)
                let i3 = min(i1 + 2, last)
                let t = srcPos - Double(i1)
                let y0 = at(i0, c), y1 = at(i1, c), y2 = at(i2, c), y3 = at(i3, c)
                let a0 = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
                let a1 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                let a2 = -0.5 * y0 + 0.5 * y2
                let a3 = y1
                let y = ((a0 * t + a1) * t + a2) * t + a3
                out[i * ch + c] = Int16(clamping: Int(y.rounded()))
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
