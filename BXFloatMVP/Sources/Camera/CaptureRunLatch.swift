import Foundation

/// 拍摄启停计数。代替在主线程读 `AVCaptureSession.isRunning`。
///
/// `startRunning` / `stopRunning` 会占着会话锁，并且在回调队列是主队列时一直等到主队列空出来。
/// 黄色麦克风指示出现时，主线程的窗口/前后台通知会走到 `isCaptureSessionRunning()`。
/// 若那里再读 `isRunning`，就和还没返回的 start/stop 对死，界面不再响应。
/// 分段拍会马上再 start，所以 stop 返回后的计数为 0 仍要等几轮，不能一停就拆闩锁。
struct CaptureRunLatch {
    private(set) var runningSessions = 0
    private(set) var startInFlight = 0
    /// start 还没返回时，另一条线已经 stop 完。等这次 start 返回后抵消，避免计数变负或卡住。
    private var pendingStops = 0

    /// 进入原始 startRunning 之前。
    mutating func beginStart() {
        startInFlight += 1
    }

    /// 原始 startRunning 已返回。
    mutating func endStart() {
        if startInFlight > 0 {
            startInFlight -= 1
        }
        if pendingStops > 0 {
            pendingStops -= 1
        } else {
            runningSessions += 1
        }
    }

    /// 原始 stopRunning 已返回。停的过程中不减，调用方不要在 stop 返回前查这个值来拆闩锁。
    mutating func endStop() {
        if runningSessions > 0 {
            runningSessions -= 1
        } else if startInFlight > 0 {
            pendingStops += 1
        }
    }

    /// 还有会话在跑，或有一次 start 还没返回。两种都不许再去摸 AVCaptureSession。
    var captureAppearsRunning: Bool {
        runningSessions > 0 || startInFlight > pendingStops
    }

    /// 重复启停的纯逻辑检查。失败原因非空即回归。
    static func regressionFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        var latch = CaptureRunLatch()
        check("idle", latch.captureAppearsRunning == false)

        latch.beginStart()
        check("start-in-flight-visible", latch.captureAppearsRunning)
        latch.endStart()
        check("one-running", latch.captureAppearsRunning && latch.runningSessions == 1 && latch.startInFlight == 0)

        latch.endStop()
        check("one-stopped", latch.captureAppearsRunning == false && latch.runningSessions == 0)

        for _ in 0..<8 {
            latch.beginStart()
            check("cycle-in-flight", latch.captureAppearsRunning)
            latch.endStart()
            check("cycle-up", latch.runningSessions == 1)
            latch.endStop()
            check("cycle-down", latch.runningSessions == 0 && latch.captureAppearsRunning == false)
        }
        check("cycles-clean", latch.pendingStops == 0 && latch.startInFlight == 0)

        // 分段：上一轮已停，下一轮 start 还在飞。轮询必须看见「还在采集」。
        latch.beginStart()
        latch.endStart()
        latch.endStop()
        latch.beginStart()
        check("segment-restart-holds", latch.captureAppearsRunning && latch.runningSessions == 0 && latch.startInFlight == 1)
        latch.endStart()
        check("segment-restart-up", latch.runningSessions == 1 && latch.captureAppearsRunning)

        // 两个会话：停一个不能拆闩锁。
        latch.beginStart()
        latch.endStart()
        check("two-up", latch.runningSessions == 2)
        latch.endStop()
        check("one-of-two", latch.runningSessions == 1 && latch.captureAppearsRunning)
        latch.endStop()
        check("both-down", latch.captureAppearsRunning == false)

        // stop 抢在 start 返回之前：最终不能剩一个幽灵会话，过程中也不许出现负计数。
        latch.beginStart()
        let mid = latch.captureAppearsRunning
        latch.endStop()
        let during = latch.runningSessions >= 0 && latch.pendingStops >= 0
        latch.endStart()
        check("stop-during-start", mid && during && latch.captureAppearsRunning == false && latch.runningSessions == 0)

        // 多余的 stop 不能把计数打成负数。
        latch.endStop()
        latch.endStop()
        check("extra-stop", latch.runningSessions == 0 && latch.captureAppearsRunning == false)

        return failures
    }
}

#if CAPTURE_LATCH_TEST
@main
enum CaptureRunLatchTest {
    static func main() {
        let failures = CaptureRunLatch.regressionFailures()
        if failures.isEmpty {
            print("capture-run-latch ok")
            return
        }
        for item in failures {
            FileHandle.standardError.write(Data("FAIL \(item)\n".utf8))
        }
        exit(1)
    }
}
#endif
