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

    static func start(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CamFrameStore.shared.reset()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
        if isAvailable {
            trimmed.withCString { BXFloatFFStartUTF8($0) }
            NSLog("BXFloatCam puller=ffmpeg url=%@", trimmed)
        } else {
            RTSPVTPuller.shared.start(urlString: trimmed)
            NSLog("BXFloatCam puller=vt-fallback url=%@", trimmed)
        }
    }

    static func stop() {
        if isAvailable {
            BXFloatFFStop()
        }
        RTSPVTPuller.shared.stop()
        CamAudioStore.shared.reset()
        AVSyncClock.shared.reset()
    }
}
