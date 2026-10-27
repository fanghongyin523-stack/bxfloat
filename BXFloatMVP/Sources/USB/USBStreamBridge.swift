import Foundation
import Network

/// 数据线方案（无 Wi‑Fi）：
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

    private init() {}

    func startAndWait() {
        queue.async { self.startLocked() }
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            var ok = false
            queue.sync {
                ok = self.isRunning && self.channels.allSatisfy(\.isReady)
            }
            if ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            for ch in self.channels { ch.stop() }
            self.channels.removeAll()
            NSLog("BXFloat USB bridge stopped")
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        isRunning = true
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
            let listener = try NWListener(using: .tcp, on: tunnelPort)
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
                if case .ready = state {
                    self?.queue.async { self?.tunnelReady = true }
                    NSLog("BXFloat USB[%@] tunnel listener READY", self?.name ?? "")
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
            let listener = try NWListener(using: .tcp, on: localPort)
            listener.newConnectionHandler = { [weak self] playerConn in
                self?.queue.async { self?.handlePlayerConnection(playerConn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.queue.async { self?.localReady = true }
                    NSLog("BXFloat USB[%@] local listener READY", self?.name ?? "")
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
            self.attachTunnel(to: playerConn, attemptsLeft: 75)
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
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
        queue.asyncAfter(deadline: .now() + 5) {
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
