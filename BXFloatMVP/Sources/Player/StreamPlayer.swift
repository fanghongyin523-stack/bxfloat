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
            return "请先在「设置」里填写电脑 IP（局域网）或完整地址"
        case .invalidURL:
            return "地址格式无效"
        case .rtspNotLinkedYet:
            return "当前包未打入 RTSP 引擎（请用带 VLC 的 BXFloatMVP.ipa 测试局域网/RTSP）"
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

enum StreamPlayerFactory {
    static func makePlayer(for urlString: String) throws -> StreamPlayer {
        switch StreamURLAnalyzer.kind(of: urlString) {
        case .localOrHTTP:
            return AVStreamPlayer()
        case .rtsp:
            #if canImport(MobileVLCKit)
            return VLCStreamPlayer()
            #else
            throw StreamPlayerError.rtspNotLinkedYet
            #endif
        case .unsupported:
            throw StreamPlayerError.invalidURL
        }
    }
}
