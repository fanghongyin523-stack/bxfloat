import Foundation

@_silgen_name("BXFloatFFIsAvailable")
func BXFloatFFIsAvailable() -> Bool

@_silgen_name("BXFloatFFStartUTF8")
func BXFloatFFStartUTF8(_ urlUTF8: UnsafePointer<CChar>)

@_silgen_name("BXFloatFFStop")
func BXFloatFFStop()

/// 优先 FFmpeg（单 dylib 内嵌）；不可用时回退手写 VT 拉流。
enum FFRTSPController {
    static var isAvailable: Bool { BXFloatFFIsAvailable() }

    /// 当前已请求拉流的 URL；同 URL 重复 start 不得 reset ring/clock。
    private static var activePullURL: String?

    static func start(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // URL 未变且仍视为在拉：完全不重置（避免 Timer 每秒 syncPuller 清缓冲）
        if activePullURL == trimmed {
            return
        }
        CamFrameStore.shared.reset()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
        CamPipelineDiag.shared.reset()
        activePullURL = trimmed
        if isAvailable {
            trimmed.withCString { BXFloatFFStartUTF8($0) }
            NSLog("BXFloatCam puller=ffmpeg url=%@", trimmed)
        } else {
            RTSPVTPuller.shared.start(urlString: trimmed)
            NSLog("BXFloatCam puller=vt-fallback url=%@", trimmed)
        }
    }

    static func stop() {
        activePullURL = nil
        if isAvailable {
            BXFloatFFStop()
        }
        RTSPVTPuller.shared.stop()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
    }
}
