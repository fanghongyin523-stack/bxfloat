import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

/// 轻量 RTSP（TCP interleaved）+ VideoToolbox：专供注入单 dylib，不依赖 VLC/FFmpeg。
/// 面向 MediaMTX 常见 H264 流；失败时保持重连。
final class RTSPVTPuller {
    static let shared = RTSPVTPuller()

    private let queue = DispatchQueue(label: "com.baixiang.rtsp.pull", qos: .userInitiated)
    private var connection: NWConnection?
    private var running = false
    private var currentURL: String = ""
    private var sps: Data?
    private var pps: Data?
    private var decompressionSession: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var recvBuffer = Data()
    private var cseq = 1
    private var sessionId: String?
    private var interleavedChannel = 0
    private var awaitingRTP = false
    private var videoSetupURL: String = ""
    private var aggregateURL: String = ""
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var ptsTicks: Int64 = 0
    private var decodeOK: Int64 = 0
    private var decodeFail: Int64 = 0

    private init() {}

    func start(urlString: String) {
        queue.async {
            if self.running, self.currentURL == urlString { return }
            self.stopLocked()
            self.currentURL = urlString
            self.running = true
            self.connectAndPlay(urlString)
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        running = false
        awaitingRTP = false
        connection?.cancel()
        connection = nil
        if let s = decompressionSession {
            VTDecompressionSessionInvalidate(s)
        }
        decompressionSession = nil
        formatDesc = nil
        sps = nil
        pps = nil
        recvBuffer.removeAll(keepingCapacity: true)
        sessionId = nil
        cseq = 1
        videoSetupURL = ""
        aggregateURL = ""
        lastSPS = nil
        lastPPS = nil
        ptsTicks = 0
        decodeOK = 0
        decodeFail = 0
        fuBuffer.removeAll(keepingCapacity: false)
    }

    private func connectAndPlay(_ urlString: String) {
        guard let url = URL(string: urlString), let host = url.host else {
            NSLog("BXFloatCam RTSP bad url %@", urlString)
            return
        }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) ?? 554
        let path = url.path.isEmpty ? "/stream" : url.path
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async { self.handshake(host: host, path: path) }
            case .failed(let err):
                NSLog("BXFloatCam RTSP failed %@", err.localizedDescription)
                self.queue.async { self.scheduleReconnect() }
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard running else { return }
        let url = currentURL
        stopLocked()
        running = true
        currentURL = url
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.running else { return }
            self.connectAndPlay(url)
        }
    }

    private func handshake(host: String, path: String) {
        // MediaMTX: DESCRIBE aggregate, SETUP video trackID, PLAY aggregate
        let portSuffix: String
        if let u = URL(string: currentURL), let p = u.port {
            portSuffix = ":\(p)"
        } else {
            portSuffix = ":18554"
        }
        let base = "rtsp://\(host)\(portSuffix)\(path.hasPrefix("/") ? path : "/" + path)"
        aggregateURL = base
        sendRTSP(
            method: "DESCRIBE",
            url: base,
            extra: ["Accept: application/sdp"]
        ) { [weak self] status, headers, body in
            guard let self, self.running else { return }
            guard status == 200, let body else {
                NSLog("BXFloatCam DESCRIBE fail %d", status)
                self.scheduleReconnect()
                return
            }
            let contentBase = (headers["content-base"] ?? headers["Content-Base"] ?? base)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n "))
            self.parseSDP(body, contentBase: contentBase, aggregate: base)
            let setupURL = self.videoSetupURL.isEmpty ? "\(contentBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/trackID=0" : self.videoSetupURL
            NSLog("BXFloatCam SETUP %@", setupURL)
            self.sendRTSP(
                method: "SETUP",
                url: setupURL,
                extra: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"]
            ) { [weak self] status, headers, _ in
                guard let self, self.running else { return }
                guard status == 200 else {
                    NSLog("BXFloatCam SETUP fail %d url=%@", status, setupURL)
                    self.scheduleReconnect()
                    return
                }
                if let transport = headers["transport"] ?? headers["Transport"] {
                    if let r = transport.range(of: "interleaved=") {
                        let rest = transport[r.upperBound...]
                        if let n = rest.split(separator: "-").first, let ch = Int(n) {
                            self.interleavedChannel = ch
                        }
                    }
                }
                self.sessionId = headers["session"] ?? headers["Session"]
                if let sid = self.sessionId, let semi = sid.firstIndex(of: ";") {
                    self.sessionId = String(sid[..<semi])
                }
                var playExtra: [String] = []
                if let sid = self.sessionId {
                    playExtra.append("Session: \(sid)")
                }
                let playURL = self.aggregateURL.isEmpty ? base : self.aggregateURL
                self.sendRTSP(method: "PLAY", url: playURL, extra: playExtra) { [weak self] status, _, _ in
                    guard let self, self.running else { return }
                    guard status == 200 else {
                        NSLog("BXFloatCam PLAY fail %d", status)
                        self.scheduleReconnect()
                        return
                    }
                    NSLog("BXFloatCam RTSP playing %@", playURL)
                    self.awaitingRTP = true
                    self.readLoop()
                }
            }
        }
    }

    private func parseSDP(_ sdp: String, contentBase: String, aggregate: String) {
        aggregateURL = aggregate
        var inVideo = false
        var videoControl: String?
        for raw in sdp.split(whereSeparator: \.isNewline) {
            let s = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("m=video") {
                inVideo = true
                continue
            }
            if s.hasPrefix("m=") {
                inVideo = false
                continue
            }
            if inVideo, s.hasPrefix("a=control:") {
                videoControl = String(s.dropFirst("a=control:".count))
            }
            guard s.contains("sprop-parameter-sets=") else { continue }
            guard let range = s.range(of: "sprop-parameter-sets=") else { continue }
            var value = String(s[range.upperBound...])
            if let sc = value.firstIndex(of: ";") { value = String(value[..<sc]) }
            let parts = value.split(separator: ",")
            if parts.count >= 2,
               let spsData = Data(base64Encoded: String(parts[0])),
               let ppsData = Data(base64Encoded: String(parts[1]))
            {
                sps = spsData
                pps = ppsData
                rebuildFormat()
            }
        }
        let base = contentBase.hasSuffix("/") ? contentBase : contentBase + "/"
        if let ctrl = videoControl, !ctrl.isEmpty {
            if ctrl.lowercased().hasPrefix("rtsp://") {
                videoSetupURL = ctrl
            } else {
                videoSetupURL = base + ctrl
            }
        } else {
            videoSetupURL = base + "trackID=0"
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        // 关键：码流里反复出现 SPS/PPS 时不要重建 VT，否则参考帧丢失 → 只剩关键帧（幻灯片）
        if sps == lastSPS, pps == lastPPS, decompressionSession != nil, formatDesc != nil {
            return
        }
        lastSPS = sps
        lastPPS = pps
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else { return }
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                var desc: CMFormatDescription?
                let status = pointers.withUnsafeBufferPointer { buf -> OSStatus in
                    guard let base = buf.baseAddress else {
                        return OSStatus(-12710)
                    }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: base,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &desc
                    )
                }
                if status == noErr, let desc {
                    self.formatDesc = desc
                    self.createDecompression(desc)
                    NSLog("BXFloatCam VT session ready sps=%d pps=%d", sps.count, pps.count)
                } else {
                    NSLog("BXFloatCam format desc err %d", status)
                }
            }
        }
    }

    private func createDecompression(_ desc: CMFormatDescription) {
        if let old = decompressionSession {
            VTDecompressionSessionInvalidate(old)
        }
        var session: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard let refcon else { return }
                let puller = Unmanaged<RTSPVTPuller>.fromOpaque(refcon).takeUnretainedValue()
                if status == noErr, let imageBuffer {
                    puller.decodeOK += 1
                    CamFrameStore.shared.publish(imageBuffer)
                } else {
                    puller.decodeFail += 1
                    if puller.decodeFail <= 5 || puller.decodeFail % 60 == 0 {
                        NSLog("BXFloatCam VT decode status=%d fail=%lld ok=%lld", status, puller.decodeFail, puller.decodeOK)
                    }
                }
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        let err = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        if err == noErr {
            decompressionSession = session
        } else {
            NSLog("BXFloatCam VT create err %d", err)
        }
    }

    private func sendRTSP(
        method: String,
        url: String,
        extra: [String],
        completion: @escaping (Int, [String: String], String?) -> Void
    ) {
        let seq = cseq
        cseq += 1
        var req = "\(method) \(url) RTSP/1.0\r\nCSeq: \(seq)\r\nUser-Agent: BXFloatCam/1.0\r\n"
        for line in extra { req += line + "\r\n" }
        req += "\r\n"
        guard let conn = connection, let data = req.data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("BXFloatCam send err %@", error.localizedDescription)
                self.scheduleReconnect()
                return
            }
            self.readRTSPResponse(expectedCSeq: seq, completion: completion)
        })
    }

    private func readRTSPResponse(
        expectedCSeq: Int,
        completion: @escaping (Int, [String: String], String?) -> Void
    ) {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, _, error in
            guard let self else { return }
            if let error {
                NSLog("BXFloatCam recv err %@", error.localizedDescription)
                self.scheduleReconnect()
                return
            }
            if let content { self.recvBuffer.append(content) }
            if let parsed = self.tryParseRTSPResponse() {
                completion(parsed.status, parsed.headers, parsed.body)
            } else {
                self.readRTSPResponse(expectedCSeq: expectedCSeq, completion: completion)
            }
        }
    }

    private func tryParseRTSPResponse() -> (status: Int, headers: [String: String], body: String?)? {
        guard let range = recvBuffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        let headData = recvBuffer.subdata(in: 0..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        var status = 0
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        if let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
        }
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = val
                headers[key] = val
            }
        }
        let headerEnd = range.upperBound
        let contentLength = Int(headers["content-length"] ?? headers["Content-Length"] ?? "0") ?? 0
        if recvBuffer.count < headerEnd + contentLength { return nil }
        var body: String?
        if contentLength > 0 {
            let bodyData = recvBuffer.subdata(in: headerEnd..<(headerEnd + contentLength))
            body = String(data: bodyData, encoding: .utf8)
        }
        recvBuffer.removeSubrange(0..<(headerEnd + contentLength))
        return (status, headers, body)
    }

    private func readLoop() {
        guard running, awaitingRTP, let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("BXFloatCam rtp recv %@", error.localizedDescription)
                self.scheduleReconnect()
                return
            }
            if let content { self.recvBuffer.append(content) }
            self.consumeInterleaved()
            if self.running, !isComplete {
                self.readLoop()
            }
        }
    }

    private func consumeInterleaved() {
        while true {
            guard recvBuffer.count >= 4 else { return }
            // RTSP interleaved: '$' ch len_hi len_lo
            if recvBuffer[0] != 0x24 {
                // Possibly leftover RTSP text — skip one byte
                recvBuffer.removeFirst()
                continue
            }
            let channel = Int(recvBuffer[1])
            let length = (Int(recvBuffer[2]) << 8) | Int(recvBuffer[3])
            guard recvBuffer.count >= 4 + length else { return }
            let payload = recvBuffer.subdata(in: 4..<(4 + length))
            recvBuffer.removeSubrange(0..<(4 + length))
            if channel == interleavedChannel {
                handleRTP(payload)
            }
        }
    }

    private func handleRTP(_ packet: Data) {
        guard packet.count > 12 else { return }
        let cc = Int(packet[0] & 0x0F)
        let hasExt = (packet[0] & 0x10) != 0
        let hasPadding = (packet[0] & 0x20) != 0
        var offset = 12 + cc * 4
        guard packet.count > offset else { return }
        if hasExt {
            guard packet.count >= offset + 4 else { return }
            let extLen = ((Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])) * 4
            offset += 4 + extLen
        }
        var end = packet.count
        if hasPadding, end > offset {
            let pad = Int(packet[end - 1])
            if pad > 0, end - pad >= offset { end -= pad }
        }
        guard end > offset else { return }
        let payload = packet.subdata(in: offset..<end)
        guard !payload.isEmpty else { return }
        let nalType = payload[0] & 0x1F
        if nalType == 28, payload.count > 1 {
            // FU-A
            let fuHeader = payload[1]
            let start = (fuHeader & 0x80) != 0
            let endBit = (fuHeader & 0x40) != 0
            let type = fuHeader & 0x1F
            let nri = payload[0] & 0x60
            if start {
                fuBuffer = Data([nri | type])
                fuBuffer.append(payload.subdata(in: 2..<payload.count))
            } else if !fuBuffer.isEmpty {
                fuBuffer.append(payload.subdata(in: 2..<payload.count))
            }
            if endBit, !fuBuffer.isEmpty {
                decodeNAL(fuBuffer)
                fuBuffer.removeAll(keepingCapacity: true)
            }
        } else if nalType == 24 {
            // STAP-A: 16-bit size + NAL ...
            var i = 1
            while i + 2 <= payload.count {
                let size = (Int(payload[i]) << 8) | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.count else { break }
                handleNALUnit(payload.subdata(in: i..<(i + size)))
                i += size
            }
        } else {
            handleNALUnit(payload)
        }
    }

    private func handleNALUnit(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F
        if nalType == 7 {
            sps = nal
            rebuildFormat()
        } else if nalType == 8 {
            pps = nal
            rebuildFormat()
        } else if nalType == 5 || nalType == 1 || (nalType > 0 && nalType < 24) {
            decodeNAL(nal)
        }
    }

    private var fuBuffer = Data()

    private func decodeNAL(_ nal: Data) {
        guard let formatDesc, let session = decompressionSession else { return }
        var len = UInt32(nal.count).bigEndian
        var avcc = Data(bytes: &len, count: 4)
        avcc.append(nal)

        let blockStatus: OSStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &block
            )
            guard status == noErr, let block else { return status }
            status = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
            guard status == noErr else { return status }

            ptsTicks += 3000 // 90kHz clock ~30fps
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 3000, timescale: 90000),
                presentationTimeStamp: CMTime(value: ptsTicks, timescale: 90000),
                decodeTimeStamp: .invalid
            )
            var sampleSize = avcc.count
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample
            )
            guard status == noErr, let sample else { return status }

            var flagsOut: VTDecodeInfoFlags = []
            // 实时优先，避免异步堆积造成幻灯片感
            return VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flagsOut
            )
        }
        if blockStatus != noErr, decodeFail < 8 {
            NSLog("BXFloatCam decodeNAL prep/decode err %d", blockStatus)
        }
    }
}
