import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import UIKit

/// 本地视频 → 自有音画环（对标 VCamLocalPlayer：playFileURL / AVPlayer + VideoOutput + DisplayLink）。
/// 完全自包含，不加载参照 dylib。
final class LocalVideoPlayer {
    static let shared = LocalVideoPlayer()

    private let lock = NSLock()
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var runningURL: String?
    private var started = false
    private let audioPump = LocalAudioPump()

    private init() {}

    func start(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stop()
            return
        }
        lock.lock()
        if started, runningURL == trimmed {
            lock.unlock()
            return
        }
        lock.unlock()
        stop()

        let playURL: URL?
        if trimmed.hasPrefix("file://") {
            playURL = URL(string: trimmed)
        } else if trimmed.hasPrefix("/") {
            playURL = URL(fileURLWithPath: trimmed)
        } else {
            playURL = URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
        }
        guard let url = playURL else {
            NSLog("BXFloatCam LocalVideo bad url=%@", trimmed)
            return
        }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        playerItem.add(output)

        let p = AVPlayer(playerItem: playerItem)
        p.isMuted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemEnded(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        lock.lock()
        player = p
        item = playerItem
        videoOutput = output
        runningURL = trimmed
        started = true
        lock.unlock()

        audioPump.attach(asset: asset)
        p.play()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        lock.lock()
        displayLink = link
        lock.unlock()
        NSLog("BXFloatCam LocalVideo start %@", trimmed)
    }

    func stop() {
        lock.lock()
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        player = nil
        if let it = item {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: it)
        }
        item = nil
        videoOutput = nil
        runningURL = nil
        started = false
        lock.unlock()
        audioPump.stop()
    }

    @objc private func itemEnded(_ note: Notification) {
        lock.lock()
        player?.seek(to: .zero)
        player?.play()
        lock.unlock()
        audioPump.rewind()
    }

    @objc private func tick() {
        lock.lock()
        let output = videoOutput
        lock.unlock()
        guard let output else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard t.isValid, output.hasNewPixelBuffer(forItemTime: t) else { return }
        var displayTime = CMTime.zero
        guard let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &displayTime) else { return }
        let pts = CMTimeGetSeconds(displayTime)
        let mapped = AVSyncClock.shared.mapPTS(pts.isFinite ? pts : 0)
        let use = mapped >= 0 ? mapped : 0
        CamFrameStore.shared.publish(pb, pts: use)
        AVSyncClock.shared.noteVideoPTS(use)
    }
}

/// 本地音轨 PCM 泵（对标 VCam pumpAudioToPlayerTime 目标）
private final class LocalAudioPump {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var asset: AVURLAsset?
    private var running = false
    private let queue = DispatchQueue(label: "bx.local.audio")

    func attach(asset: AVURLAsset) {
        stop()
        self.asset = asset
        startReader()
    }

    func rewind() {
        stop()
        startReader()
    }

    func stop() {
        running = false
        reader?.cancelReading()
        reader = nil
        output = nil
    }

    private func startReader() {
        guard let asset else { return }
        guard let track = asset.tracks(withMediaType: .audio).first else { return }
        do {
            let r = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
            ]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            guard r.canAdd(out) else { return }
            r.add(out)
            r.startReading()
            reader = r
            output = out
            running = true
            queue.async { [weak self] in self?.pumpLoop() }
        } catch {
            NSLog("BXFloatCam LocalVideo audio reader fail %@", error.localizedDescription)
        }
    }

    private func pumpLoop() {
        while running {
            guard let out = output, let r = reader else { break }
            if r.status != .reading {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard let sb = out.copyNextSampleBuffer(), CMSampleBufferIsValid(sb),
                  let dataBuffer = CMSampleBufferGetDataBuffer(sb)
            else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            let len = CMBlockBufferGetDataLength(dataBuffer)
            guard len >= 2 else { continue }
            var data = [Int16](repeating: 0, count: len / 2)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: len, destination: base)
            }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            let mapped = AVSyncClock.shared.mapPTS(pts.isFinite ? pts : -1)
            data.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let frames = data.count / 2
                CamAudioStore.shared.publish(
                    samples: base,
                    frames: frames,
                    channels: 2,
                    sampleRate: 48_000,
                    pts: mapped
                )
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
    }
}
