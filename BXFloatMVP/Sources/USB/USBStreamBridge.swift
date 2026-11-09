import Foundation
import Network

/// 数据线方案（无 Wi‑Fi）——自研 usbmux 隧道，对标 VCamUSBPuller「进画」目标，零依赖参照 dylib。
/// - RTSP：手机 `127.0.0.1:18554` ←隧道 19889← 电脑 MediaMTX RTSP（替换摄像头用）
/// - HLS：手机 `127.0.0.1:18888` ←隧道 19888← 电脑 MediaMTX HLS（兼容旧预览）
final class USBStreamBridge {
    static let shared = USBStreamBridge()

    static let hlsPlayPort: NWEndpoint.Port = 18888
    static let hlsTunnelPort: NWEndpoint.Port = 19888
    static let rtspPlayPort: NWEndpoint.Port = 18554
    static let rtspTunnelPort: NWEndpoint.Port = 19889

    private let queue = DispatchQueue(label: "com.baixiang.usb.bridge")
    private var channels: [Channel] = []
    private(set) var isRunning = false

    /// 面板诊断：本机 RTSP 监听是否起来 / PC 助手隧道是否已挂上
    private(set) var diagLocalReady = false
    private(set) var diagTunnelPending = 0
    private(set) var diagLastError: String = ""

    private init() {}

    /// 异步启动监听（选数据线模式即可起，不等于拉流）。禁止主线程忙等。
    func start() {
        queue.async { self.startLocked() }
    }

    /// 等本机 RTSP 监听就绪 +（尽量）PC 隧道已挂上，再回调开 FFmpeg。
    /// 旧逻辑只等 localReady 就拉流：FFmpeg 2s 超时经常等不到助手，表现为「数据线画面过不来」。
    func whenPullReady(timeoutSec: TimeInterval = 15.0, _ body: @escaping (_ tunnelArmed: Bool) -> Void) {
        queue.async {
            self.startLocked()
            self.pollPullReady(deadline: Date().addingTimeInterval(timeoutSec), body: body)
        }
    }

    /// 兼容旧名
    func whenLocalReady(timeoutSec: TimeInterval = 15.0, _ body: @escaping () -> Void) {
        whenPullReady(timeoutSec: timeoutSec) { _ in body() }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            for ch in self.channels { ch.stop() }
            self.channels.removeAll()
            self.diagLocalReady = false
            self.diagTunnelPending = 0
            NSLog("BXFloat USB bridge stopped")
        }
    }

    func statusLine() -> String {
        if !isRunning { return "USB隧道未启动" }
        if diagTunnelPending > 0 { return "USB助手已连 pending=\(diagTunnelPending)" }
        if diagLocalReady { return "USB本机已听，等助手…" }
        if !diagLastError.isEmpty { return "USB:\(diagLastError)" }
        return "USB启动中…"
    }

    private func startLocked() {
        guard !isRunning else { return }
        isRunning = true
        diagLastError = ""
        let specs: [(NWEndpoint.Port, NWEndpoint.Port, String)] = [
            (Self.rtspPlayPort, Self.rtspTunnelPort, "rtsp"),
            (Self.hlsPlayPort, Self.hlsTunnelPort, "hls"),
        ]
        channels = specs.map { local, tunnel, name in
            Channel(name: name, localPort: local, tunnelPort: tunnel, queue: queue) { [weak self] in
                self?.isRunning ?? false
            }
        }
        for ch in channels { ch.start() }
        NSLog("BXFloat USB bridge starting rtsp=:%@/%@ hls=:%@/%@",
              "\(Self.rtspPlayPort)", "\(Self.rtspTunnelPort)",
              "\(Self.hlsPlayPort)", "\(Self.hlsTunnelPort)")
    }

    private func pollPullReady(deadline: Date, body: @escaping (Bool) -> Void) {
        let rtsp = channels.first(where: { $0.name == "rtsp" })
        let localOK = rtsp?.localReady == true
        let pending = rtsp?.pendingTunnelCount ?? 0
        diagLocalReady = localOK
        diagTunnelPending = pending

        // 理想：本机已听 + PC 助手已有挂起隧道，再开 FFmpeg，管道可瞬时对接
        if localOK, pending > 0 {
            NSLog("BXFloat USB pull-ready local=1 pending=%d", pending)
            DispatchQueue.main.async { body(true) }
            return
        }
        if !isRunning || Date() >= deadline {
            if !localOK {
                diagLastError = "本机:18554未就绪"
                NSLog("BXFloat USB pull timeout: local not ready")
            } else if pending == 0 {
                diagLastError = "助手未连(开USB助手)"
                NSLog("BXFloat USB pull timeout: no PC tunnel; start USB助手")
            }
            DispatchQueue.main.async { body(localOK && pending > 0) }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollPullReady(deadline: deadline, body: body)
        }
    }
}

// MARK: - One local↔tunnel channel

private final class Channel {
    let name: String
    let localPort: NWEndpoint.Port
    let tunnelPort: NWEndpoint.Port
    private let queue: DispatchQueue
    private let running: () -> Bool

    private var localListener: NWListener?
    private var tunnelListener: NWListener?
    private var pendingTunnels: [NWConnection] = []
    private var activePairs: [(NWConnection, NWConnection)] = []
    private(set) var localReady = false
    private(set) var tunnelReady = false
    var pendingTunnelCount: Int { pendingTunnels.count }
    var isReady: Bool { localReady && tunnelReady }

    init(
        name: String,
        localPort: NWEndpoint.Port,
        tunnelPort: NWEndpoint.Port,
        queue: DispatchQueue,
        running: @escaping () -> Bool
    ) {
        self.name = name
        self.localPort = localPort
        self.tunnelPort = tunnelPort
        self.queue = queue
        self.running = running
    }

    func start() {
        startTunnelListener()
        startLocalListener()
    }

    func stop() {
        localReady = false
        tunnelReady = false
        localListener?.cancel()
        tunnelListener?.cancel()
        localListener = nil
        tunnelListener = nil
        for c in pendingTunnels { c.cancel() }
        pendingTunnels.removeAll()
        for (a, b) in activePairs {
            a.cancel()
            b.cancel()
        }
        activePairs.removeAll()
    }

    private func startTunnelListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: tunnelPort)
            listener.newConnectionHandler = { [weak self] conn in
                self?.queue.async {
                    guard let self, self.running() else {
                        conn.cancel()
                        return
                    }
                    self.waitReady(conn) { ready in
                        guard ready else {
                            conn.cancel()
                            return
                        }
                        self.pendingTunnels.append(conn)
                        NSLog("BXFloat USB[%@] tunnel ready pending=%d", self.name, self.pendingTunnels.count)
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.queue.async { self?.tunnelReady = true }
                    NSLog("BXFloat USB[%@] tunnel listener READY", self?.name ?? "")
                case .failed(let err):
                    NSLog("BXFloat USB[%@] tunnel listener FAIL %@", self?.name ?? "", "\(err)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            tunnelListener = listener
        } catch {
            NSLog("BXFloat USB[%@] tunnel listen error: %@", name, "\(error)")
        }
    }

    private func startLocalListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: localPort)
            listener.newConnectionHandler = { [weak self] playerConn in
                self?.queue.async { self?.handlePlayerConnection(playerConn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.queue.async { self?.localReady = true }
                    NSLog("BXFloat USB[%@] local listener READY", self?.name ?? "")
                case .failed(let err):
                    NSLog("BXFloat USB[%@] local listener FAIL %@", self?.name ?? "", "\(err)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            localListener = listener
        } catch {
            NSLog("BXFloat USB[%@] local listen error: %@", name, "\(error)")
        }
    }

    private func handlePlayerConnection(_ playerConn: NWConnection) {
        guard running() else {
            playerConn.cancel()
            return
        }
        waitReady(playerConn) { [weak self] ready in
            guard let self, ready, self.running() else {
                playerConn.cancel()
                return
            }
            // 50ms×300 ≈ 15s：等 PC 助手；与 FFmpeg USB 超时对齐
            self.attachTunnel(to: playerConn, attemptsLeft: 300)
        }
    }

    private func attachTunnel(to playerConn: NWConnection, attemptsLeft: Int) {
        if let tunnel = pendingTunnels.first {
            pendingTunnels.removeFirst()
            pipe(playerConn, tunnel)
            return
        }
        if attemptsLeft <= 0 || !running() {
            NSLog("BXFloat USB[%@]: no PC tunnel; keep USB助手 running", name)
            playerConn.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attachTunnel(to: playerConn, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func waitReady(_ conn: NWConnection, completion: @escaping (Bool) -> Void) {
        if conn.state == .ready {
            completion(true)
            return
        }
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            completion(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) {
            if conn.state != .ready { finish(false) }
        }
    }

    private func pipe(_ a: NWConnection, _ b: NWConnection) {
        activePairs.append((a, b))
        NSLog("BXFloat USB[%@] pipe started", name)
        pump(from: a, to: b)
        pump(from: b, to: a)
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        from.cancel()
                        to.cancel()
                        return
                    }
                    self.queue.async { self.pump(from: from, to: to) }
                })
                return
            }
            if isComplete || error != nil {
                from.cancel()
                to.cancel()
            } else {
                self.queue.async { self.pump(from: from, to: to) }
            }
        }
    }
}
