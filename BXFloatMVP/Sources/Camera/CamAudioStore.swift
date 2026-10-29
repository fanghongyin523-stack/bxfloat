import AudioToolbox
import Foundation

/// 音频 ring + 连续播放头。欠载用末样延持（非硬切零），避免电流声/爆音。
final class CamAudioStore {
    static let shared = CamAudioStore()

    private struct Chunk {
        var pts: Double
        var samples: [Int16]
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private let maxSeconds: Double = 3.5
    let storeRate = 48_000

    private var playhead: Double = -1
    private let maxPlayheadSlew: Double = 0.012
    private var lastSample: Int16 = 0

    private(set) var packetCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1

    private init() {}

    var hasFreshAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !chunks.isEmpty && Date().timeIntervalSince(lastUpdate) < 3.0
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
        packetCount = 0
        lastUpdate = .distantPast
        lastPTS = -1
        playhead = -1
        lastSample = 0
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

        let mapped = pts >= 0 ? AVSyncClock.shared.mapPTS(pts) : -1
        let startPTS: Double
        if mapped >= 0 {
            startPTS = mapped
        } else {
            lock.lock()
            startPTS = nextAppendPTSLocked()
            lock.unlock()
        }
        let endPTS = startPTS + Double(pcm.count) / Double(storeRate)
        // 视频还没跟上：丢掉超前音频，防止沿差涨到数秒
        if mapped >= 0, !AVSyncClock.shared.shouldAcceptAudioEndPTS(endPTS) {
            return
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

    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int) {
        publish(samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, pts: -1)
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

        // 先刷新 AVSYNC；硬 hold / 视频空窗：冻播放头，用末样延持（避免硬切零电流声）
        let target = AVSyncClock.shared.mediaTime()
        if AVSyncClock.shared.shouldFreezeAudio() {
            fillHoldSample(into: dst, frames: frames, channels: channels, isFloat: isFloat, sampleBytes: sampleBytes)
            return false
        }
        let startPTS = advancePlayhead(target: target, duration: duration)

        var src = [Int16](repeating: 0, count: needStore)
        let got = peekStarting(at: startPTS, into: &src, frames: needStore)

        var out: [Int16]
        if got <= 0 {
            out = [Int16](repeating: lastSample, count: frames)
        } else if dstRate == storeRate {
            out = Array(src.prefix(frames))
            if out.count < frames {
                let pad = lastSampleOf(out) ?? lastSample
                out.append(contentsOf: repeatElement(pad, count: frames - out.count))
            }
        } else {
            var rs = resampleLinear(Array(src.prefix(max(got, 1))), from: storeRate, to: dstRate)
            if rs.count < frames {
                let pad = lastSampleOf(rs) ?? lastSample
                rs.append(contentsOf: repeatElement(pad, count: frames - rs.count))
            } else if rs.count > frames {
                rs = Array(rs.prefix(frames))
            }
            out = rs
        }
        let prevSample = lastSample
        // 短淡入：从延持恢复时压掉台阶，减爆音/电流声
        if got > 0, !out.isEmpty, abs(Int(out[0]) - Int(prevSample)) > 10000 {
            let fade = min(48, out.count)
            for i in 0..<fade {
                let a = Double(i) / Double(fade)
                out[i] = Int16(clamping: Int(Double(prevSample) * (1 - a) + Double(out[i]) * a))
            }
        }
        if let s = lastSampleOf(out) { lastSample = s }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        writePCM(
            dst,
            frames: frames,
            channels: channels,
            samples: out,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: isNonInterleaved
        )
        return got > 0
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

    // MARK: - private

    private func advancePlayhead(target: Double, duration: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if playhead < 0 || !playhead.isFinite {
            playhead = max(0, target)
        } else {
            let err = target - playhead
            // 大跳只缓拉，禁止一次跳几十毫秒（会出电流声）
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

    private func lastSampleOf(_ samples: [Int16]) -> Int16? {
        guard let s = samples.last else { return nil }
        return s
    }

    private func fillHoldSample(
        into dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        isFloat: Bool,
        sampleBytes: Int
    ) {
        // 调用方 asbd 可能是非交错；这里按交错写一帧宽，AU 路径 ch=1 时等价
        let hold = [Int16](repeating: lastSample, count: frames)
        writePCM(
            dst,
            frames: frames,
            channels: channels,
            samples: hold,
            isFloat: isFloat,
            sampleBytes: sampleBytes,
            nonInterleaved: false
        )
    }

    private func writePCM(
        _ dst: UnsafeMutableRawPointer,
        frames: Int,
        channels: Int,
        samples: [Int16],
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
                    samples: samples,
                    isFloat: isFloat,
                    bytesPerSample: sampleBytes
                )
            }
        } else {
            writeInterleaved(
                dst,
                frames: frames,
                channels: channels,
                samples: samples,
                isFloat: isFloat,
                bytesPerSample: sampleBytes
            )
        }
    }

    private func peekStarting(at startPTS: Double, into buffer: inout [Int16], frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
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
                let gapFrames = min(
                    frames - written,
                    max(0, Int(((chunk.pts - cursor) * Double(storeRate)).rounded(.down)))
                )
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
        samples: [Int16],
        isFloat: Bool,
        bytesPerSample: Int
    ) {
        for i in 0..<frames {
            let s = i < samples.count ? samples[i] : 0
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
        samples: [Int16],
        isFloat: Bool,
        bytesPerSample: Int
    ) {
        for i in 0..<frames {
            let s = i < samples.count ? samples[i] : 0
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
