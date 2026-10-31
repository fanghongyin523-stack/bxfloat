import Foundation
import QuartzCore

/// 轻量分阶段诊断：累计计数 + 每秒快照，供面板/日志看瓶颈。
/// 不改时钟阈值、不改原麦路径逻辑。
final class CamPipelineDiag {
    static let shared = CamPipelineDiag()

    private let lock = NSLock()

    private var vDecodeOK: Int64 = 0
    private var vDecodeFail: Int64 = 0
    private var vCacheWrite: Int64 = 0
    private var vCachePrune: Int64 = 0
    private var vSlotWait: Int64 = 0
    private var vReplaceOK: Int64 = 0
    private var vReplaceFail: Int64 = 0

    private var aInPeak: Int32 = 0
    private var aOutPeak: Int32 = 0
    private var aInClip: Int64 = 0
    private var aOutClip: Int64 = 0
    private var aUnderrun: Int64 = 0
    private var aClockDiscard: Int64 = 0
    private var aInBlocks: Int64 = 0
    private var aOutBlocks: Int64 = 0

    // 最近一路 raw（桥接写入；门控日志用）
    private var aRawTick: Int64 = 0
    private var aTbNum: Int32 = 0
    private var aTbDen: Int32 = 0
    private var aRawSec: Double = -1
    private var vRawTick: Int64 = 0
    private var vTbNum: Int32 = 0
    private var vTbDen: Int32 = 0
    private var vRawSec: Double = -1

    // 本秒门控
    private var gateAccept: Int64 = 0
    private var gateReject: Int64 = 0
    private var lastGateEndPTS: Double = -1
    private var prevGateAccept: Int64 = 0
    private var prevGateReject: Int64 = 0

    private var lastTick = CACurrentMediaTime()
    private var snapVDec = 0
    private var snapVCache = 0
    private var snapVOut = 0
    private var snapVWait = 0
    private var snapVPrune = 0
    private var snapVFail = 0
    private var snapAInPk = 0
    private var snapAOutPk = 0
    private var snapAInClip = 0
    private var snapAOutClip = 0
    private var snapAUnd = 0
    private var snapADisc = 0

    private var prevVDec: Int64 = 0
    private var prevVCache: Int64 = 0
    private var prevVOut: Int64 = 0
    private var prevVWait: Int64 = 0
    private var prevVPrune: Int64 = 0
    private var prevVFail: Int64 = 0
    private var prevAInClip: Int64 = 0
    private var prevAOutClip: Int64 = 0
    private var prevAUnd: Int64 = 0
    private var prevADisc: Int64 = 0
    private var windowInPeak: Int32 = 0
    private var windowOutPeak: Int32 = 0

    // 交互卡顿：paint 耗时 / 主线程回调
    private var paintMsMax: Double = 0
    private var paintMsSum: Double = 0
    private var paintCostN: Int = 0
    private var paintOnMainN: Int = 0
    private var snapPaintMax = 0
    private var snapPaintAvg = 0
    private var snapPaintMain = 0

    private var watchdogStarted = false
    private var mainProbeSentAt: CFTimeInterval = 0
    private var mainProbeAckAt: CFTimeInterval = 0
    private var snapMainStallMs = 0

    private init() {
        startMainWatchdogIfNeeded()
    }

    /// 会话事件自动落盘（不依赖面板按钮；卡住时仍可能有后台 tick 写入）
    func noteSessionEvent(_ message: String) {
        let line = "BXFloatSession \(message)"
        NSLog("%@", line)
        appendLogLines([line], syncFlush: true)
    }

    private func startMainWatchdogIfNeeded() {
        lock.lock()
        if watchdogStarted {
            lock.unlock()
            return
        }
        watchdogStarted = true
        lock.unlock()
        // 独立队列探测主线程停顿；结果写入 gate 日志，无需点面板
        let q = DispatchQueue(label: "bx.float.main.watchdog")
        q.async {
            while true {
                let sent = CACurrentMediaTime()
                self.lock.lock()
                self.mainProbeSentAt = sent
                self.lock.unlock()
                DispatchQueue.main.async {
                    let ack = CACurrentMediaTime()
                    self.lock.lock()
                    self.mainProbeAckAt = ack
                    let stall = Int(max(0, (ack - sent) * 1000.0).rounded())
                    if stall > self.snapMainStallMs { self.snapMainStallMs = stall }
                    self.lock.unlock()
                    if stall >= 80 {
                        self.appendLogLines([
                            String(format: "BXFloatMainStall ms=%d", stall)
                        ])
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
                self.lock.lock()
                let sentAt = self.mainProbeSentAt
                let ackAt = self.mainProbeAckAt
                self.lock.unlock()
                // 主线程半秒仍未 ack：记一笔（UI 已卡时面板不可用，靠文件/内存环）
                if sentAt > ackAt, (CACurrentMediaTime() - sentAt) >= 0.45 {
                    let pending = Int(((CACurrentMediaTime() - sentAt) * 1000.0).rounded())
                    self.appendLogLines([
                        String(format: "BXFloatMainStall pendingMs=%d (no-ack)", pending)
                    ])
                }
            }
        }
    }

    func reset() {
        lock.lock()
        vDecodeOK = 0; vDecodeFail = 0; vCacheWrite = 0; vCachePrune = 0
        vSlotWait = 0; vReplaceOK = 0; vReplaceFail = 0
        aInPeak = 0; aOutPeak = 0; aInClip = 0; aOutClip = 0
        aUnderrun = 0; aClockDiscard = 0; aInBlocks = 0; aOutBlocks = 0
        aRawTick = 0; aTbNum = 0; aTbDen = 0; aRawSec = -1
        vRawTick = 0; vTbNum = 0; vTbDen = 0; vRawSec = -1
        gateAccept = 0; gateReject = 0; lastGateEndPTS = -1
        prevGateAccept = 0; prevGateReject = 0
        gatePending = 0; gateRebase = 0; prevGatePending = 0; prevGateRebase = 0
        lastGateReason = ""; lastGateLeadMs = 0; audioFormatNote = ""
        prevVDec = 0; prevVCache = 0; prevVOut = 0; prevVWait = 0
        prevVPrune = 0; prevVFail = 0
        prevAInClip = 0; prevAOutClip = 0; prevAUnd = 0; prevADisc = 0
        windowInPeak = 0; windowOutPeak = 0
        paintMsMax = 0; paintMsSum = 0; paintCostN = 0; paintOnMainN = 0
        lastTick = CACurrentMediaTime()
        lock.unlock()
        appendLogLines(["BXFloatGate --- reset ---"])
    }

    func notePaintCost(ms: Double, onMain: Bool) {
        lock.lock()
        paintCostN += 1
        paintMsSum += ms
        if ms > paintMsMax { paintMsMax = ms }
        if onMain { paintOnMainN += 1 }
        lock.unlock()
        tickIfNeeded()
    }

    func noteVideoDecodeOK() { bump { vDecodeOK += 1 } }
    func noteVideoDecodeFail() { bump { vDecodeFail += 1 } }
    func noteVideoCacheWrite() { bump { vCacheWrite += 1 } }
    func noteVideoCachePrune(_ n: Int) { guard n > 0 else { return }; bump { vCachePrune += Int64(n) } }
    func noteVideoSlotWait() { bump { vSlotWait += 1 } }
    func noteVideoReplaceOK() { bump { vReplaceOK += 1 } }
    func noteVideoReplaceFail() { bump { vReplaceFail += 1 } }

    func noteVideoRaw(tick: Int64, tbNum: Int32, tbDen: Int32, rawSec: Double) {
        lock.lock()
        vRawTick = tick
        vTbNum = tbNum
        vTbDen = tbDen
        vRawSec = rawSec
        lock.unlock()
    }

    func noteAudioRaw(tick: Int64, tbNum: Int32, tbDen: Int32, rawSec: Double) {
        lock.lock()
        aRawTick = tick
        aTbNum = tbNum
        aTbDen = tbDen
        aRawSec = rawSec
        lock.unlock()
    }

    private var gatePending: Int64 = 0
    private var gateRebase: Int64 = 0
    private var lastGateReason: String = ""
    private var lastGateLeadMs: Double = 0
    private var snapGatePending = 0
    private var snapGateRebase = 0
    private var prevGatePending: Int64 = 0
    private var prevGateRebase: Int64 = 0
    private var audioFormatNote: String = ""

    /// 门控记账。pending/rebase 不算硬丢包 disc；仅 reject/flush-drop 计 disc。
    func noteAudioGate(
        accepted: Bool,
        endPTS: Double,
        reason: String = "",
        leadMs: Double = 0
    ) {
        lock.lock()
        lastGateEndPTS = endPTS
        lastGateReason = reason
        lastGateLeadMs = leadMs
        if accepted {
            gateAccept += 1
            if reason.contains("rebase") { gateRebase += 1 }
        } else if reason == "pending" {
            gatePending += 1
        } else {
            gateReject += 1
            aClockDiscard += 1
        }
        lock.unlock()
        tickIfNeeded()
    }

    func noteAudioFormat(_ note: String) {
        lock.lock()
        audioFormatNote = note
        lock.unlock()
        appendLogLines(["BXFloatAudioFormat \(note)"], syncFlush: false)
        NSLog("BXFloatAudioFormat %@", note)
    }

    // 音质分阶段：decode=注入前（贴近推流源），inject=AU 写出后，mic=原麦对照
    private var aqSrcPeak: Float = 0
    private var aqSrcRms: Float = 0
    private var aqSrcDc: Float = 0
    private var aqSrcZcr: Float = 0
    private var aqOutPeak: Float = 0
    private var aqOutRms: Float = 0
    private var aqOutDc: Float = 0
    private var aqOutZcr: Float = 0
    private var aqMicPeak: Float = 0
    private var aqMicRms: Float = 0
    private var aqMicDc: Float = 0
    private var aqMicZcr: Float = 0
    private var aqRateIn: Int = 0
    private var aqRateOut: Int = 0
    private var aqBps: Int = 0
    private var aqFloat: Int = 0
    private var aqMismatch: Int = 0
    private var aqSrcN: Int = 0
    private var aqOutN: Int = 0
    private var aqMicN: Int = 0

    enum AudioQualityStage: String {
        case decode
        case inject
        case mic
    }

    func noteAUFormatMeta(
        rateOut: Int,
        bytesPerSample: Int,
        isFloat: Bool,
        formatMismatch: Bool
    ) {
        lock.lock()
        if rateOut > 0 { aqRateOut = rateOut }
        if bytesPerSample > 0 { aqBps = bytesPerSample }
        aqFloat = isFloat ? 1 : 0
        if formatMismatch { aqMismatch += 1 }
        lock.unlock()
        tickIfNeeded()
    }

    /// 音质探针：区分「源头已有杂音」vs「注入路径引入」
    func noteAudioQuality(
        stage: AudioQualityStage,
        samples: UnsafePointer<Int16>,
        count: Int,
        rateIn: Int = 0,
        rateOut: Int = 0,
        bytesPerSample: Int = 0,
        isFloat: Bool = false,
        formatMismatch: Bool = false
    ) {
        guard count > 8 else {
            if formatMismatch || rateOut > 0 || bytesPerSample > 0 {
                noteAUFormatMeta(
                    rateOut: rateOut,
                    bytesPerSample: bytesPerSample,
                    isFloat: isFloat,
                    formatMismatch: formatMismatch
                )
            }
            return
        }
        var peak: Int32 = 0
        var sum: Int64 = 0
        var sumSq: Double = 0
        var zc = 0
        var prev = samples[0]
        for i in 0..<count {
            let s = samples[i]
            let a = abs(Int32(s))
            if a > peak { peak = a }
            sum += Int64(s)
            sumSq += Double(Int(s) * Int(s))
            if (prev >= 0 && s < 0) || (prev < 0 && s >= 0) { zc += 1 }
            prev = s
        }
        let n = Double(count)
        let dc = Float(Double(sum) / n / 32768.0)
        let rms = Float(sqrt(sumSq / n) / 32768.0)
        let pk = Float(Double(peak) / 32768.0)
        let zcr = Float(Double(zc) / n)

        lock.lock()
        switch stage {
        case .decode:
            aqSrcPeak = max(aqSrcPeak, pk)
            aqSrcRms = max(aqSrcRms, rms)
            aqSrcDc = dc
            aqSrcZcr = zcr
            aqSrcN += 1
            if rateIn > 0 { aqRateIn = rateIn }
        case .inject:
            aqOutPeak = max(aqOutPeak, pk)
            aqOutRms = max(aqOutRms, rms)
            aqOutDc = dc
            aqOutZcr = zcr
            aqOutN += 1
            if rateOut > 0 { aqRateOut = rateOut }
            if bytesPerSample > 0 { aqBps = bytesPerSample }
            aqFloat = isFloat ? 1 : 0
            if formatMismatch { aqMismatch += 1 }
        case .mic:
            aqMicPeak = max(aqMicPeak, pk)
            aqMicRms = max(aqMicRms, rms)
            aqMicDc = dc
            aqMicZcr = zcr
            aqMicN += 1
        }
        lock.unlock()
        tickIfNeeded()
    }

    func noteAudioUnderrun() { bump { aUnderrun += 1 } }

    func noteAudioInput(samples: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        var peak: Int32 = 0
        var clips = 0
        for i in 0..<count {
            let a = abs(Int32(samples[i]))
            if a > peak { peak = a }
            if samples[i] == Int16.max || samples[i] == Int16.min { clips += 1 }
        }
        lock.lock()
        aInBlocks += 1
        if peak > aInPeak { aInPeak = peak }
        if peak > windowInPeak { windowInPeak = peak }
        aInClip += Int64(clips)
        lock.unlock()
        tickIfNeeded()
    }

    func noteAudioOutput(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var peak: Int32 = 0
        var clips = 0
        for s in samples {
            let a = abs(Int32(s))
            if a > peak { peak = a }
            if s == Int16.max || s == Int16.min { clips += 1 }
        }
        lock.lock()
        aOutBlocks += 1
        if peak > aOutPeak { aOutPeak = peak }
        if peak > windowOutPeak { windowOutPeak = peak }
        aOutClip += Int64(clips)
        lock.unlock()
        tickIfNeeded()
    }

    /// 面板：视频每秒 / 音频每秒 / paint 卡顿
    func panelLines() -> (String, String, String) {
        tickIfNeeded()
        lock.lock()
        let v = String(
            format: "V/s 解%d 入环%d 出%d 等%d 剪%d 败%d",
            snapVDec, snapVCache, snapVOut, snapVWait, snapVPrune, snapVFail
        )
        let a = String(
            format: "A/s in%.2f out%.2f clip%d/%d und%d disc%d",
            Double(snapAInPk) / 32768.0,
            Double(snapAOutPk) / 32768.0,
            snapAInClip, snapAOutClip, snapAUnd, snapADisc
        )
        let stall = snapMainStallMs
        let p = String(
            format: "Paint max%d avg%d ms · main回调%d/s · 主线程卡%d ms",
            snapPaintMax, snapPaintAvg, snapPaintMain, stall
        )
        lock.unlock()
        return (v, a, p)
    }

    /// 音质对照行：源(decode) / 注入(out) / 原麦(mic)
    func audioQualityPanelLine() -> String {
        tickIfNeeded()
        lock.lock()
        let ch = CamAudioStore.shared.storeChannels
        let line = String(
            format: "AQ 源pk%.2f rms%.2f dc%.3f | 注入pk%.2f rms%.2f dc%.3f | 麦pk%.2f | %dch %d→%d bps%d f%d mis%d",
            aqSrcPeak, aqSrcRms, aqSrcDc,
            aqOutPeak, aqOutRms, aqOutDc,
            aqMicPeak,
            ch, aqRateIn, aqRateOut, aqBps, aqFloat, aqMismatch
        )
        lock.unlock()
        return line
    }

    private func bump(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
        tickIfNeeded()
    }

    private func tickIfNeeded() {
        let now = CACurrentMediaTime()
        lock.lock()
        let dt = now - lastTick
        guard dt >= 1.0 else { lock.unlock(); return }
        snapVDec = Int(vDecodeOK - prevVDec)
        snapVCache = Int(vCacheWrite - prevVCache)
        snapVOut = Int(vReplaceOK - prevVOut)
        snapVWait = Int(vSlotWait - prevVWait)
        snapVPrune = Int(vCachePrune - prevVPrune)
        snapVFail = Int(vDecodeFail - prevVFail)
        snapAInClip = Int(aInClip - prevAInClip)
        snapAOutClip = Int(aOutClip - prevAOutClip)
        snapAUnd = Int(aUnderrun - prevAUnd)
        snapADisc = Int(aClockDiscard - prevADisc)
        snapAInPk = Int(windowInPeak)
        snapAOutPk = Int(windowOutPeak)
        snapPaintMax = Int(paintMsMax.rounded())
        snapPaintAvg = paintCostN > 0 ? Int((paintMsSum / Double(paintCostN)).rounded()) : 0
        snapPaintMain = paintOnMainN
        let mainStall = snapMainStallMs
        paintMsMax = 0
        paintMsSum = 0
        paintCostN = 0
        paintOnMainN = 0
        snapMainStallMs = 0
        let acc = Int(gateAccept - prevGateAccept)
        let rej = Int(gateReject - prevGateReject)
        snapGatePending = Int(gatePending - prevGatePending)
        snapGateRebase = Int(gateRebase - prevGateRebase)
        let pend = snapGatePending
        let reb = snapGateRebase
        let gateReason = lastGateReason
        let gateLead = lastGateLeadMs
        let fmtNote = audioFormatNote
        let aTick = aRawTick
        let aN = aTbNum
        let aD = aTbDen
        let aRS = aRawSec
        let aEnd = lastGateEndPTS
        let vTick = vRawTick
        let vN = vTbNum
        let vD = vTbDen
        let vRS = vRawSec
        prevVDec = vDecodeOK
        prevVCache = vCacheWrite
        prevVOut = vReplaceOK
        prevVWait = vSlotWait
        prevVPrune = vCachePrune
        prevVFail = vDecodeFail
        prevAInClip = aInClip
        prevAOutClip = aOutClip
        prevAUnd = aUnderrun
        prevADisc = aClockDiscard
        prevGateAccept = gateAccept
        prevGateReject = gateReject
        prevGatePending = gatePending
        prevGateRebase = gateRebase
        windowInPeak = 0
        windowOutPeak = 0
        lastTick = now
        let paintMax = snapPaintMax
        let paintAvg = snapPaintAvg
        let paintMain = snapPaintMain
        let vLine = String(
            format: "BXFloatDiag V dec=%d cache=%d out=%d wait=%d prune=%d fail=%d | A inPk=%.2f outPk=%.2f clip=%d/%d und=%d disc=%d | paintMax=%d paintAvg=%d mainCb=%d mainStall=%d",
            snapVDec, snapVCache, snapVOut, snapVWait, snapVPrune, snapVFail,
            Double(snapAInPk) / 32768.0, Double(snapAOutPk) / 32768.0,
            snapAInClip, snapAOutClip, snapAUnd, snapADisc,
            paintMax, paintAvg, paintMain, mainStall
        )
        // AQ 快照在锁内；窗口峰重置后解锁再打日志
        let aqLine = String(
            format: "BXFloatAQ srcPk=%.3f srcRms=%.3f srcDc=%.4f srcZcr=%.3f outPk=%.3f outRms=%.3f outDc=%.4f outZcr=%.3f micPk=%.3f micRms=%.3f micDc=%.4f rate=%d->%d bps=%d float=%d mismatch=%d srcN=%d outN=%d micN=%d",
            aqSrcPeak, aqSrcRms, aqSrcDc, aqSrcZcr,
            aqOutPeak, aqOutRms, aqOutDc, aqOutZcr,
            aqMicPeak, aqMicRms, aqMicDc,
            aqRateIn, aqRateOut, aqBps, aqFloat, aqMismatch,
            aqSrcN, aqOutN, aqMicN
        )
        aqSrcPeak = 0; aqSrcRms = 0; aqOutPeak = 0; aqOutRms = 0
        aqMicPeak = 0; aqMicRms = 0; aqMismatch = 0
        aqSrcN = 0; aqOutN = 0; aqMicN = 0
        lock.unlock()

        let clock = AVSyncClock.shared.diagSnapshot()
        let aRingMs = Int(CamAudioStore.shared.bufferedSeconds() * 1000)
        let auCb = BXFloatMicAUCallbackCount()
        let auPaint = BXFloatMicAUPaintCount()
        let dEndV: Double
        if aEnd >= 0, clock.lastVideoPTS >= 0 {
            dEndV = aEnd - clock.lastVideoPTS
        } else {
            dEndV = .nan
        }
        let gateLine = String(
            format: "BXFloatGate aRaw=%lld tb=%d/%d aRawSec=%.6f aEnd=%.6f vRaw=%lld tb=%d/%d vRawSec=%.6f vMap=%.6f dEndV=%.6f epoch=%.6f acc=%d rej=%d pend=%d rebase=%d leadMs=%.0f reason=%@ aRingMs=%d auCb=%lld auPaint=%lld fmt=%@",
            aTick, aN, aD, aRS, aEnd,
            vTick, vN, vD, vRS, clock.lastVideoPTS,
            dEndV, clock.epoch,
            acc, rej, pend, reb, gateLead, gateReason as NSString,
            aRingMs, auCb, auPaint,
            (fmtNote.isEmpty ? "-" : fmtNote) as NSString
        )
        NSLog("%@", vLine)
        NSLog("%@", gateLine)
        NSLog("%@", aqLine)
        appendLogLines([vLine, gateLine, aqLine])
    }

    // MARK: - Windows 可取回：内存环形 + 可写路径落盘

    /// 注入抖音时 /var/mobile/Documents 常不可写；优先内存，其次沙盒/tmp。
    private let logQueue: DispatchQueue = {
        let q = DispatchQueue(label: "bx.float.gate.log")
        q.setSpecific(key: CamPipelineDiag.logQueueKey, value: 1)
        return q
    }()
    private let maxMemLines = 240
    private let maxLogBytes = 512 * 1024
    private var memLines: [String] = []
    private var activeLogPath: String = "(memory-only)"

    private func candidateLogPaths() -> [String] {
        var paths: [String] = []
        let home = NSHomeDirectory()
        paths.append((home as NSString).appendingPathComponent("Documents/BXFloat/gate.log"))
        paths.append((home as NSString).appendingPathComponent("tmp/BXFloat-gate.log"))
        paths.append(NSTemporaryDirectory() + "BXFloat-gate.log")
        paths.append("/tmp/BXFloat-gate.log")
        paths.append("/var/mobile/Documents/BXFloat/gate.log")
        return paths
    }

    /// 供面板「复制Gate日志」：内存优先（不依赖文件权限），便于微信传到 Windows。
    func exportLogText(maxBytes: Int = 80_000) -> (text: String, path: String, exists: Bool) {
        logQueue.sync {
            let header = "BXFloatGateExport path=\(activeLogPath) lines=\(memLines.count)\n"
            if !memLines.isEmpty {
                var body = memLines.joined(separator: "\n") + "\n"
                if body.utf8.count > maxBytes {
                    let data = Data(body.utf8)
                    body = String(data: data.suffix(maxBytes), encoding: .utf8) ?? body
                    body = "…(截取尾部)\n" + body
                }
                return (header + body, activeLogPath, true)
            }
            // 内存空时再试文件（杀进程后仍可能有落盘）
            for path in candidateLogPaths() {
                guard FileManager.default.fileExists(atPath: path),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      !data.isEmpty
                else { continue }
                let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
                var text = String(data: slice, encoding: .utf8) ?? ""
                if data.count > maxBytes { text = "…(截取尾部)\n" + text }
                return (header + text, path, true)
            }
            return (
                header + "(尚无日志：请保持推流≥2秒后再点复制。若仍空=诊断未 tick)\n",
                activeLogPath,
                false
            )
        }
    }

    func clearLogFile() {
        logQueue.async {
            self.memLines.removeAll(keepingCapacity: true)
            for path in self.candidateLogPaths() {
                try? FileManager.default.removeItem(atPath: path)
            }
            self.activeLogPath = "(memory-only)"
        }
    }

    private func appendLogLines(_ lines: [String], syncFlush: Bool = false) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let stamped = lines.map { "\(stamp) \($0)" }
        let body = stamped.joined(separator: "\n") + "\n"
        let work: () -> Void = {
            self.memLines.append(contentsOf: stamped)
            if self.memLines.count > self.maxMemLines {
                self.memLines.removeFirst(self.memLines.count - self.maxMemLines)
            }
            guard let data = body.data(using: .utf8) else { return }
            let fm = FileManager.default
            for path in self.candidateLogPaths() {
                let dir = (path as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: dir) {
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                if !fm.fileExists(atPath: path) {
                    fm.createFile(atPath: path, contents: nil)
                }
                guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
                    continue
                }
                handle.seekToEndOfFile()
                handle.write(data)
                if syncFlush {
                    try? handle.synchronize()
                }
                let size = handle.offsetInFile
                handle.closeFile()
                self.activeLogPath = path
                if size > UInt64(self.maxLogBytes),
                   let all = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    try? Data(all.suffix(self.maxLogBytes / 2)).write(
                        to: URL(fileURLWithPath: path),
                        options: .atomic
                    )
                }
                return
            }
            // 全部写失败仍保留内存，剪贴板可导出
            self.activeLogPath = "(memory-only)"
        }
        if syncFlush {
            // 启停事件尽量立刻落盘，避免卡死杀进程后日志丢失
            if DispatchQueue.getSpecific(key: Self.logQueueKey) != nil {
                work()
            } else {
                logQueue.sync(execute: work)
            }
        } else {
            logQueue.async(execute: work)
        }
    }

    private static let logQueueKey = DispatchSpecificKey<UInt8>()
}

@_cdecl("BXFloatDiagVideoDecodeOK")
public func BXFloatDiagVideoDecodeOK() { CamPipelineDiag.shared.noteVideoDecodeOK() }

@_cdecl("BXFloatDiagVideoDecodeFail")
public func BXFloatDiagVideoDecodeFail() { CamPipelineDiag.shared.noteVideoDecodeFail() }

@_cdecl("BXFloatDiagVideoSlotWait")
public func BXFloatDiagVideoSlotWait() { CamPipelineDiag.shared.noteVideoSlotWait() }

@_cdecl("BXFloatDiagNoteVideoRaw")
public func BXFloatDiagNoteVideoRaw(_ tick: Int64, _ tbNum: Int32, _ tbDen: Int32, _ rawSec: Double) {
    CamPipelineDiag.shared.noteVideoRaw(tick: tick, tbNum: tbNum, tbDen: tbDen, rawSec: rawSec)
}

@_cdecl("BXFloatDiagNoteAudioRaw")
public func BXFloatDiagNoteAudioRaw(_ tick: Int64, _ tbNum: Int32, _ tbDen: Int32, _ rawSec: Double) {
    CamPipelineDiag.shared.noteAudioRaw(tick: tick, tbNum: tbNum, tbDen: tbDen, rawSec: rawSec)
}

/// AU 原麦抽检：把第一路 PCM 转成 s16 记 mic 阶段，用于和推流注入对照。
@_cdecl("BXFloatAQNoteMicTap")
public func BXFloatAQNoteMicTap(
    _ data: UnsafeRawPointer,
    _ frames: Int32,
    _ channels: Int32,
    _ bytesPerSample: Int32,
    _ isFloat: Int32
) {
    let f = Int(frames)
    let ch = max(1, Int(channels))
    var bps = Int(bytesPerSample)
    let floatMode = isFloat != 0
    if floatMode, bps < 4 { bps = 4 }
    if !floatMode, bps != 2, bps != 4 { bps = 2 }
    guard f > 8, bps > 0 else { return }
    // 限频：约每 8 次回调抽一帧，避免 AU 路径过重
    struct Gate { static var n: Int = 0 }
    Gate.n += 1
    if Gate.n % 8 != 0 { return }

    var mono = [Int16](repeating: 0, count: f)
    let base = data
    for i in 0..<f {
        let off = i * ch * bps
        let s: Int16
        if floatMode, bps == 4 {
            var fl: Float = 0
            memcpy(&fl, base.advanced(by: off), 4)
            s = Int16(clamping: Int((Double(fl) * 32767.0).rounded()))
        } else if bps == 2 {
            var v: Int16 = 0
            memcpy(&v, base.advanced(by: off), 2)
            s = v
        } else if bps == 4, !floatMode {
            var v: Int32 = 0
            memcpy(&v, base.advanced(by: off), 4)
            s = Int16(clamping: Int(v >> 16))
        } else {
            s = 0
        }
        mono[i] = s
    }
    mono.withUnsafeBufferPointer { buf in
        guard let p = buf.baseAddress else { return }
        CamPipelineDiag.shared.noteAudioQuality(stage: .mic, samples: p, count: f)
    }
}

/// AU 实际格式 vs 缓冲几何不一致时累计，便于定位电流声根因。
@_cdecl("BXFloatAQNoteAUFormat")
public func BXFloatAQNoteAUFormat(
    _ rate: Double,
    _ frames: Int32,
    _ bufBytes: Int32,
    _ channels: Int32,
    _ bytesPerSample: Int32,
    _ isFloat: Int32,
    _ asbdBits: Int32,
    _ asbdFlags: UInt32,
    _ mismatch: Int32
) {
    if mismatch != 0 {
        let note = String(
            format: "AU rate=%.0f frames=%d buf=%d ch=%d bps=%d float=%d asbdBits=%d flags=0x%x mis=%d",
            rate, frames, bufBytes, channels, bytesPerSample, isFloat, asbdBits, asbdFlags, mismatch
        )
        CamPipelineDiag.shared.noteAudioFormat(note)
    }
    CamPipelineDiag.shared.noteAUFormatMeta(
        rateOut: Int(rate.rounded()),
        bytesPerSample: Int(bytesPerSample),
        isFloat: isFloat != 0,
        formatMismatch: mismatch != 0
    )
}
