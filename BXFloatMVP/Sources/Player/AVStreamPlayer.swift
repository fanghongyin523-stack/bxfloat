import AVFoundation
import UIKit

final class AVStreamPlayer: StreamPlayer {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let container = PlayerContainerView()
    private var statusObserver: NSKeyValueObservation?
    private var keepUpObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    var view: UIView { container }

    var isPlaying: Bool {
        player.rate != 0
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    init() {
        // 低延迟：不要为了少卡顿而多缓冲
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
        } else if let parsed = URL(string: trimmed) {
            url = parsed
        } else {
            throw StreamPlayerError.invalidURL
        }

        stop()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        let item = AVPlayerItem(asset: asset)
        // 直播向前缓冲压到约 1 秒，起播更快、延迟更低
        item.preferredForwardBufferDuration = 1.0
        if #available(iOS 14.0, *) {
            item.startsOnFirstEligibleVariant = true
        }
        player.replaceCurrentItem(with: item)

        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.jumpToLiveEdgeIfNeeded(item)
                if self.player.rate == 0 {
                    self.player.play()
                }
            } else if item.status == .failed {
                NSLog("BXFloat AVPlayer failed: \(String(describing: item.error))")
            }
        }

        keepUpObserver?.invalidate()
        keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            // 卡顿恢复后立刻继续播，并尽量贴直播沿
            if item.isPlaybackLikelyToKeepUp, self.player.rate == 0 {
                self.jumpToLiveEdgeIfNeeded(item)
                self.player.play()
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
            // 直播一般不会到 end；本地文件循环
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    func play() {
        if let item = player.currentItem {
            jumpToLiveEdgeIfNeeded(item)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        statusObserver?.invalidate()
        statusObserver = nil
        keepUpObserver?.invalidate()
        keepUpObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// HLS 直播：跳到可 seek 范围末尾，减少积压延迟
    private func jumpToLiveEdgeIfNeeded(_ item: AVPlayerItem) {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let duration = range.duration
        guard duration.isNumeric, duration.seconds > 0.3 else { return }
        let live = CMTimeAdd(range.start, duration)
        // 略微退后 0.3s，避免贴太死导致频繁卡
        let target = CMTimeSubtract(live, CMTimeMakeWithSeconds(0.3, preferredTimescale: 600))
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
