import AVFoundation
import UIKit

final class AVStreamPlayer: StreamPlayer {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let container = PlayerContainerView()
    private var statusObserver: NSKeyValueObservation?
    private var keepUpObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var liveCatchTimer: Timer?
    private var isLiveStream = false

    var view: UIView { container }

    var isPlaying: Bool {
        player.rate != 0
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        container.playerLayer = playerLayer
        container.layer.addSublayer(playerLayer)
    }

    deinit {
        stopLiveCatchTimer()
        statusObserver?.invalidate()
        keepUpObserver?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func load(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamPlayerError.emptyURL }

        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
            isLiveStream = false
        } else if let parsed = URL(string: trimmed) {
            url = parsed
            let lower = trimmed.lowercased()
            isLiveStream = lower.contains(".m3u8") || lower.hasPrefix("rtsp://") || lower.contains(":18888/")
        } else {
            throw StreamPlayerError.invalidURL
        }

        stop()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = isLiveStream ? 0.5 : 2.0
        if #available(iOS 14.0, *) {
            item.startsOnFirstEligibleVariant = true
        }
        player.replaceCurrentItem(with: item)

        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.jumpToLiveEdge(item, force: true)
                if self.player.rate == 0 {
                    self.player.play()
                }
                self.startLiveCatchTimer()
            } else if item.status == .failed {
                NSLog("BXFloat AVPlayer failed: \(String(describing: item.error))")
            }
        }

        keepUpObserver?.invalidate()
        keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.isPlaybackLikelyToKeepUp {
                self.jumpToLiveEdge(item, force: false)
                if self.player.rate == 0 {
                    self.player.play()
                }
            }
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    func play() {
        if let item = player.currentItem {
            jumpToLiveEdge(item, force: true)
        }
        player.play()
        startLiveCatchTimer()
    }

    func pause() {
        stopLiveCatchTimer()
        player.pause()
    }

    func stop() {
        stopLiveCatchTimer()
        statusObserver?.invalidate()
        statusObserver = nil
        keepUpObserver?.invalidate()
        keepUpObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func startLiveCatchTimer() {
        stopLiveCatchTimer()
        guard isLiveStream else { return }
        liveCatchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let item = self.player.currentItem else { return }
            self.jumpToLiveEdge(item, force: false)
            if item.isPlaybackLikelyToKeepUp, self.player.rate == 0 {
                self.player.play()
            }
        }
        if let liveCatchTimer {
            RunLoop.main.add(liveCatchTimer, forMode: .common)
        }
    }

    private func stopLiveCatchTimer() {
        liveCatchTimer?.invalidate()
        liveCatchTimer = nil
    }

    private func jumpToLiveEdge(_ item: AVPlayerItem, force: Bool) {
        guard isLiveStream else { return }
        guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let duration = range.duration
        guard duration.isNumeric, duration.seconds > 0.2 else { return }
        let live = CMTimeAdd(range.start, duration)
        let target = CMTimeSubtract(live, CMTimeMakeWithSeconds(0.25, preferredTimescale: 600))
        let current = player.currentTime()
        if current.isNumeric, target.isNumeric {
            let lag = CMTimeGetSeconds(CMTimeSubtract(target, current))
            if !force, lag < 1.2 { return }
            if lag.isNaN || lag < 0 { return }
        }
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    }
}

private final class PlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}
