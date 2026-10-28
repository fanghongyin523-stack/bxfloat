import AudioToolbox
import Foundation

/// RTSP 解码后的 PCM 环缓（固定 mono Int16 @ 48k），供麦克风替换读取。
final class CamAudioStore {
    static let shared = CamAudioStore()

    private let lock = NSLock()
    private let capacity = 48_000 * 2 // 2s @ 48k mono
    private var ring: [Int16]
    private var writeIdx = 0
    private var available = 0

    private(set) var packetCount: Int64 = 0
    private(set) var lastUpdate = Date.distantPast
    let storeRate = 48_000

    private init() {
        ring = [Int16](repeating: 0, count: capacity)
    }

    var hasFreshAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available > 0 && Date().timeIntervalSince(lastUpdate) < 2.5
    }

    func reset() {
        lock.lock()
        writeIdx = 0
        available = 0
        packetCount = 0
        lastUpdate = .distantPast
        lock.unlock()
    }

    /// frames = 每声道采样数；多声道会混成 mono。
    func publish(samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int) {
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
        if rate == storeRate {
            append(mono)
        } else {
            append(resampleLinear(mono, from: rate, to: storeRate))
        }
    }

    /// 按目标 ASBD 写入（静音或推流）；返回是否写入成功。
    @discardableResult
    func fill(into dst: UnsafeMutableRawPointer, byteCount: Int, asbd: AudioStreamBasicDescription) -> Bool {
        guard byteCount > 0 else { return false }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerSample = max(1, bits / 8)
        let frameBytes = bytesPerSample * channels
        guard frameBytes > 0 else { return false }
        let frames = byteCount / frameBytes
        guard frames > 0 else { return false }

        let dstRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : storeRate
        let needStoreFrames: Int
        if dstRate == storeRate {
            needStoreFrames = frames
        } else {
            needStoreFrames = max(1, frames * storeRate / dstRate)
        }

        var src = [Int16](repeating: 0, count: needStoreFrames)
        let got = read(into: &src, frames: needStoreFrames)
        if got == 0 { return false }

        let played: [Int16]
        if dstRate == storeRate {
            played = src
        } else {
            played = resampleLinear(Array(src.prefix(got)), from: storeRate, to: dstRate)
        }

        var isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        // 防电流声：声明 float 却按 16bit 写
        var sampleBytes = bytesPerSample
        if isFloat, sampleBytes < 4 {
            sampleBytes = 4
        }
        if !isFloat, sampleBytes == 4, (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0 {
            // 未标 integer 的 4 字节，按 float 处理（RemoteIO 常见）
            isFloat = true
        }
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // 用实际 sampleBytes 重算帧数，避免 bpf 算错
        let realFrameBytes = sampleBytes * channels
        let realFrames = realFrameBytes > 0 ? byteCount / realFrameBytes : frames

        if isNonInterleaved {
            let planeBytes = realFrames * sampleBytes
            for c in 0..<channels {
                let plane = dst.advanced(by: c * planeBytes)
                writePlane(plane, frames: realFrames, samples: played, isFloat: isFloat, bytesPerSample: sampleBytes)
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

    static func silence(into dst: UnsafeMutableRawPointer, byteCount: Int) {
        memset(dst, 0, byteCount)
    }

    // MARK: - private

    private func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            ring[writeIdx] = s
            writeIdx = (writeIdx + 1) % capacity
            if available < capacity {
                available += 1
            }
        }
        packetCount += 1
        lastUpdate = Date()
    }

    private func read(into buffer: inout [Int16], frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(frames, available)
        guard n > 0 else { return 0 }
        let start = (writeIdx - available + capacity) % capacity
        for i in 0..<n {
            buffer[i] = ring[(start + i) % capacity]
        }
        available -= n
        return n
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
