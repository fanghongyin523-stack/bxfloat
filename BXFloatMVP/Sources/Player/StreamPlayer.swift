import Foundation
import UIKit

enum StreamKind {
    case localOrHTTP
    case rtsp
    case unsupported
}

enum StreamPlayerError: LocalizedError {
    case emptyURL
    case invalidURL
    case rtspNotLinkedYet

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "请先填写播放地址"
        case .invalidURL:
            return "地址格式无效"
        case .rtspNotLinkedYet:
            return "RTSP 需要下一阶段接入 VLC/FFmpeg（当前可先用本地或 http/https）"
        }
    }
}

protocol StreamPlayer: AnyObject {
    var view: UIView { get }
    var isPlaying: Bool { get }
    var isMuted: Bool { get set }

    func load(urlString: String) throws
    func play()
    func pause()
    func stop()
}

enum StreamURLAnalyzer {
    static func kind(of urlString: String) -> StreamKind {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("rtsp://") || trimmed.hasPrefix("rtsps://") {
            return .rtsp
        }
        if trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://")
            || trimmed.hasPrefix("/")
        {
            return .localOrHTTP
        }
        return .unsupported
    }
}

/// 工厂：一期用 AVPlayer；RTSP 后续换成 VLC/FFmpeg 实现同一协议即可。
enum StreamPlayerFactory {
    static func makePlayer(for urlString: String) throws -> StreamPlayer {
        switch StreamURLAnalyzer.kind(of: urlString) {
        case .localOrHTTP:
            return AVStreamPlayer()
        case .rtsp:
            throw StreamPlayerError.rtspNotLinkedYet
        case .unsupported:
            throw StreamPlayerError.invalidURL
        }
    }
}
