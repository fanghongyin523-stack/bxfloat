import AVFoundation
import UIKit

final class AVStreamPlayer: StreamPlayer {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let container = PlayerContainerView()
    private var statusObserver: NSKeyValueObservation?
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
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        container.playerLayer = playerLayer
        container.layer.addSublayer(playerLayer)
    }

    deinit {
        statusObserver?.invalidate()
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
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                NSLog("BXFloat AVPlayer failed: \(String(describing: item.error))")
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
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

private final class PlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}
