import Foundation
import Network

/// 无 SIM / 无个人热点的数据线方案：
/// 手机本机 `127.0.0.1:18888` 给 AVPlayer；
/// 电脑经 usbmux 连到手机 `19888`，再接到电脑 MediaMTX。
final class USBStreamBridge {
    static let shared = USBStreamBridge()

    static let localPlayPort: NWEndpoint.Port = 18888
    static let tunnelPort: NWEndpoint.Port = 19888

    private let queue = DispatchQueue(label: "com.baixiang.usb.bridge")
    private var localListener: NWListener?
    private var tunnelListener: NWListener?
    private var pendingTunnels: [NWConnection] = []
    private var activePairs: [(NWConnection, NWConnection)] = []
    private(set) var isRunning = false
    private var localReady = false
    private var tunnelReady = false

    private init() {}

    /// 启动桥接；尽量等两个监听就绪后再返回（最多约 2 秒）
    func startAndWait() {
        queue.async { self.startLocked() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var ok = false
            queue.sync { ok = self.localReady && self.tunnelReady }
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
            self.localReady = false
            self.tunnelReady = false
            self.localListener?.cancel()
            self.tunnelListener?.cancel()
            self.localListener = nil
            self.tunnelListener = nil
            for conn in self.pendingTunnels {
                conn.cancel()
            }
            self.pendingTunnels.removeAll()
            for (a, b) in self.activePairs {
                a.cancel()
                b.cancel()
            }
            self.activePairs.removeAll()
            NSLog("BXFloat USB bridge stopped")
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        isRunning = true
        startTunnelListener()
        startLocalListener()
        NSLog("BXFloat USB bridge starting :%@ / :%@", "\(Self.localPlayPort)", "\(Self.tunnelPort)")
    }

    private func startTunnelListener() {
        do {
            let listener = try NWListener(using: .tcp, on: Self.tunnelPort)
            listener.newConnectionHandler = { [weak self] conn in
                self?.queue.async {
                    guard let self, self.isRunning else {
                        conn.cancel()
                        return
                    }
                    self.waitReady(conn) { ready in
                        guard ready else {
                            conn.cancel()
                            return
                        }
                        self.pendingTunnels.append(conn)
                        NSLog("BXFloat USB tunnel ready, pending=%d", self.pendingTunnels.count)
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.queue.async { self?.tunnelReady = true }
                    NSLog("BXFloat USB tunnel listener READY")
                case .failed(let error):
                    NSLog("BXFloat USB tunnel listener failed: %@", "\(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            tunnelListener = listener
        } catch {
            NSLog("BXFloat USB tunnel listen error: %@", "\(error)")
        }
    }

    private func startLocalListener() {
        do {
            let listener = try NWListener(using: .tcp, on: Self.localPlayPort)
            listener.newConnectionHandler = { [weak self] playerConn in
                self?.queue.async {
                    self?.handlePlayerConnection(playerConn)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.queue.async { self?.localReady = true }
                    NSLog("BXFloat USB local listener READY")
                case .failed(let error):
                    NSLog("BXFloat USB local listener failed: %@", "\(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            localListener = listener
        } catch {
            NSLog("BXFloat USB local listen error: %@", "\(error)")
        }
    }

    private func handlePlayerConnection(_ playerConn: NWConnection) {
        guard isRunning else {
            playerConn.cancel()
            return
        }

        waitReady(playerConn) { [weak self] ready in
            guard let self, ready, self.isRunning else {
                playerConn.cancel()
                return
            }
            self.attachTunnel(to: playerConn, attemptsLeft: 75) // ~15s
        }
    }

    private func attachTunnel(to playerConn: NWConnection, attemptsLeft: Int) {
        if let tunnel = pendingTunnels.first {
            pendingTunnels.removeFirst()
            pipe(playerConn, tunnel)
            return
        }
        if attemptsLeft <= 0 || !isRunning {
            NSLog("BXFloat USB: no PC tunnel; keep BXFloat-USB助手 running")
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
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            if conn.state != .ready {
                finish(false)
            }
        }
    }

    private func pipe(_ a: NWConnection, _ b: NWConnection) {
        activePairs.append((a, b))
        NSLog("BXFloat USB pipe started")
        pump(from: a, to: b)
        pump(from: b, to: a)
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        from.cancel()
                        to.cancel()
                        return
                    }
                    self.queue.async {
                        self.pump(from: from, to: to)
                    }
                })
                return
            }
            if isComplete || error != nil {
                from.cancel()
                to.cancel()
            } else {
                self.queue.async {
                    self.pump(from: from, to: to)
                }
            }
        }
    }
}
