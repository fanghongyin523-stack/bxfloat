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

    private init() {}

    func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startTunnelListener()
            self.startLocalListener()
            NSLog("BXFloat USB bridge on 127.0.0.1:%@ <- tunnel :%@", "\(Self.localPlayPort)", "\(Self.tunnelPort)")
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
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

    private func startTunnelListener() {
        do {
            let listener = try NWListener(using: .tcp, on: Self.tunnelPort)
            listener.newConnectionHandler = { [weak self] conn in
                self?.queue.async {
                    guard let self, self.isRunning else {
                        conn.cancel()
                        return
                    }
                    conn.start(queue: self.queue)
                    self.pendingTunnels.append(conn)
                    NSLog("BXFloat USB tunnel ready, pending=%d", self.pendingTunnels.count)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("BXFloat USB tunnel listener failed: %@", "\(error)")
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
            // 本机 AVPlayer 连 127.0.0.1:18888；监听所有地址即可
            let listener = try NWListener(using: .tcp, on: Self.localPlayPort)
            listener.newConnectionHandler = { [weak self] playerConn in
                self?.queue.async {
                    self?.handlePlayerConnection(playerConn)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("BXFloat USB local listener failed: %@", "\(error)")
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
        playerConn.start(queue: queue)

        if let tunnel = pendingTunnels.first {
            pendingTunnels.removeFirst()
            pipe(playerConn, tunnel)
            return
        }

        // 等电脑助手连上来（最长 15 秒）
        let deadline = Date().addingTimeInterval(15)
        func waitLoop() {
            if let tunnel = self.pendingTunnels.first {
                self.pendingTunnels.removeFirst()
                self.pipe(playerConn, tunnel)
                return
            }
            if Date() > deadline || !self.isRunning {
                NSLog("BXFloat USB: no PC tunnel; open BXFloat-USB助手")
                playerConn.cancel()
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.2) {
                waitLoop()
            }
        }
        waitLoop()
    }

    private func pipe(_ a: NWConnection, _ b: NWConnection) {
        activePairs.append((a, b))
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
