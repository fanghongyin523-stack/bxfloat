import AudioToolbox
import Foundation

/// 带 PTS 的 PCM 块队列（mono Int16 @ 48k），按 mediaTime 取声，与画面共用时钟。
final class CamAudioStore {
    static let shared = CamAudioStore()

    private struct Chunk {
        var pts: Double
        var samples: [Int16]
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private let maxSeconds: Double = 1.5
    let storeRate = 48_000

    private(set) var packetCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    private(set) var lastPTS: Double = -1

    private init() {}

    var hasFreshAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !chunks.isEmpty && Date().timeIntervalSince(lastUpdate) < 2.5
    }

    func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        packetCount = 0
        lastUpdate = .distantPast
        lastPTS = -1
        lock.unlock()
    }

    /// frames = 每声道采样数；pts = 该块起始媒体时间（秒）
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
        let pcm: [Int16]
        let outPts: Double
        if rate == storeRate {
            pcm = mono
            outPts = pts
        } else {
            pcm = resampleLinear(mono, from: rate, to: storeRate)
            outPts = pts
        }
        guard !pcm.isEmpty else { return }

        lock.lock()
        chunks.append(Chunk(pts: outPts.isFinite && outPts >= 0 ? outPts : nextAppendPTS(), samples: pcm))
        packetCount += 1
        lastUpdate = Date()
        lastPTS = chunks.last!.pts + Double(pcm.count) / Double(storeRate)
        pruneLocked(before: lastPTS - maxSeconds)
        lock.unlock()

        if outPts.isFinite, outPts >= 0 {
            AVSyncClock.shared.noteAudioPTS(outPts)
        }
    }

    /// 兼容旧调用（无 PTS）
    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int) {
        publish(samples: samples, frames: frames, channels: channels, sampleRate: sampleRate, pts: -1)
    }

    /// 从 startPTS 起填充目标格式；与画面同一 mediaTime。
    @discardableResult
    func fill(into dst: UnsafeMutableRawPointer, byteCount: Int, asbd: AudioStreamBasicDescription, startPTS: Double) -> Bool {
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
        let needStore = max(1, Int((duration * Double(storeRate)).rounded(.up)))

        var src = [Int16](repeating: 0, count: needStore)
        let got = readStarting(at: startPTS, into: &src, frames: needStore)
        if got == 0 { return false }

        let played: [Int16]
        if dstRate == storeRate {
            played = Array(src.prefix(got))
        } else {
            played = resampleLinear(Array(src.prefix(got)), from: storeRate, to: dstRate)
        }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let realFrames = frameBytes > 0 ? byteCount / frameBytes : frames
        if isNonInterleaved {
            let planeBytes = realFrames * sampleBytes
            for c in 0..<channels {
                writePlane(
                    dst.advanced(by: c * planeBytes),
                    frames: realFrames,
                    samples: played,
                    isFloat: isFloat,
                    bytesPerSample: sampleBytes
                )
            }
        } else {
            writeInterleaved(
                dst,
                frames: realFrames,
                channels: channels,
                samples: played,
                isFloat: isFloat,
                bytesPerSample: sampleBytes
            )
        }
        return true
    }

    @discardableResult
    func fill(into dst: UnsafeMutableRawPointer, byteCount: Int, asbd: AudioStreamBasicDescription) -> Bool {
        fill(into: dst, byteCount: byteCount, asbd: asbd, startPTS: AVSyncClock.shared.mediaTime())
    }

    static func silence(into dst: UnsafeMutableRawPointer, byteCount: Int) {
        memset(dst, 0, byteCount)
    }

    // MARK: - private

    private func nextAppendPTS() -> Double {
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

    private func readStarting(at startPTS: Double, into buffer: inout [Int16], frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, !chunks.isEmpty else { return 0 }

        var t = startPTS
        if !startPTS.isFinite || startPTS < 0 {
            t = chunks.first!.pts
        }

        // 丢弃过时块
        pruneLocked(before: t - 0.02)

        var written = 0
        while written < frames {
            guard let idx = chunks.firstIndex(where: { chunk in
                let end = chunk.pts + Double(chunk.samples.count) / Double(storeRate)
                return end > t
            }) else { break }

            if idx > 0 {
                chunks.removeFirst(idx)
            }
            let chunk = chunks[0]
            let offsetSec = max(0, t - chunk.pts)
            var sampleIdx = Int(offsetSec * Double(storeRate))
            if sampleIdx >= chunk.samples.count {
                chunks.removeFirst()
                continue
            }
            let n = min(frames - written, chunk.samples.count - sampleIdx)
            for i in 0..<n {
                buffer[written + i] = chunk.samples[sampleIdx + i]
            }
            written += n
            sampleIdx += n
            t += Double(n) / Double(storeRate)
            if sampleIdx >= chunk.samples.count {
                chunks.removeFirst()
            } else {
                // 缩块头，避免重复读
                let left = Array(chunk.samples[sampleIdx...])
                chunks[0] = Chunk(pts: t, samples: left)
            }
        }
        return written
    }

    private func resampleLinear(_ input: [Int16], from srcRate: Int, to dstRate: Int) -> [Int16] {
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return input }
        if srcRate == dstRate { return input }
        let outCount = max(1, input.count * dstRate / srcRate)
        var out = [Int16](repeating: 0, count: outCount)
        let last = input.count - 1
        for i in 0..<outCount {
            let srcPos = Double(i) * Double(srcRate) / Double(dstRate)
            let i0 = min(Int(srcPos), last)
            let i1 = min(i0 + 1, last)
            let frac = srcPos - Double(i0)
            let a = Double(input[i0])
            let b = Double(input[i1])
            out[i] = Int16(clamping: Int(a + (b - a) * frac))
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
            let s = i < samples.count ? samples[i] : (samples.last ?? 0)
            for c in 0..<channels {
                let offset = (i * channels + c) * bytesPerSample
                writeSample(dst.advanced(by: offset), sample: s, isFloat: isFloat, bytesPerSample: bytesPerSample)
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
            let s = i < samples.count ? samples[i] : (samples.last ?? 0)
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
            withUnsafeBytes(of: &f) { raw in
                memcpy(dst, raw.baseAddress!, 4)
            }
        } else if bytesPerSample == 2 {
            var s = sample
            withUnsafeBytes(of: &s) { raw in
                memcpy(dst, raw.baseAddress!, 2)
            }
        } else if bytesPerSample == 4, !isFloat {
            var s32 = Int32(sample) << 16
            withUnsafeBytes(of: &s32) { raw in
                memcpy(dst, raw.baseAddress!, 4)
            }
        } else {
            var s = sample
            withUnsafeBytes(of: &s) { raw in
                memcpy(dst, raw.baseAddress!, min(2, bytesPerSample))
            }
        }
    }
}
