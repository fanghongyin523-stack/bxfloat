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

    private init() {}

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

    /// 门控结果（不改 shouldAccept 本身；仅记账）
    func noteAudioGate(accepted: Bool, endPTS: Double) {
        lock.lock()
        lastGateEndPTS = endPTS
        if accepted {
            gateAccept += 1
        } else {
            gateReject += 1
            aClockDiscard += 1
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
        let p = String(
            format: "Paint max%d avg%d ms · main回调%d/s",
            snapPaintMax, snapPaintAvg, snapPaintMain
        )
        lock.unlock()
        return (v, a, p)
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
        paintMsMax = 0
        paintMsSum = 0
        paintCostN = 0
        paintOnMainN = 0
        let acc = Int(gateAccept - prevGateAccept)
        let rej = Int(gateReject - prevGateReject)
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
        windowInPeak = 0
        windowOutPeak = 0
        lastTick = now
        let paintMax = snapPaintMax
        let paintAvg = snapPaintAvg
        let paintMain = snapPaintMain
        let vLine = String(
            format: "BXFloatDiag V dec=%d cache=%d out=%d wait=%d prune=%d fail=%d | A inPk=%.2f outPk=%.2f clip=%d/%d und=%d disc=%d | paintMax=%d paintAvg=%d mainCb=%d",
            snapVDec, snapVCache, snapVOut, snapVWait, snapVPrune, snapVFail,
            Double(snapAInPk) / 32768.0, Double(snapAOutPk) / 32768.0,
            snapAInClip, snapAOutClip, snapAUnd, snapADisc,
            paintMax, paintAvg, paintMain
        )
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
            format: "BXFloatGate aRaw=%lld tb=%d/%d aRawSec=%.6f aEnd=%.6f vRaw=%lld tb=%d/%d vRawSec=%.6f vMap=%.6f dEndV=%.6f epoch=%.6f acc=%d rej=%d aRingMs=%d auCb=%lld auPaint=%lld",
            aTick, aN, aD, aRS, aEnd,
            vTick, vN, vD, vRS, clock.lastVideoPTS,
            dEndV, clock.epoch,
            acc, rej, aRingMs, auCb, auPaint
        )
        NSLog("%@", vLine)
        NSLog("%@", gateLine)
        appendLogLines([vLine, gateLine])
    }

    // MARK: - Windows 可取回：内存环形 + 可写路径落盘

    /// 注入抖音时 /var/mobile/Documents 常不可写；优先内存，其次沙盒/tmp。
    private let logQueue = DispatchQueue(label: "bx.float.gate.log")
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

    private func appendLogLines(_ lines: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let stamped = lines.map { "\(stamp) \($0)" }
        let body = stamped.joined(separator: "\n") + "\n"
        logQueue.async {
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
    }
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
