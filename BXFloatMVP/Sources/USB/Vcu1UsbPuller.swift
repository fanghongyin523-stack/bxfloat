import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

/// USB 直连 VCU1 收端：listen device_port → 拆 24B 头 → type 分发 → VT 解码 → BXFloatPublishVideoFrame。
/// 网络风格模仿 `USBStreamBridge`；拆包模仿 `Vcu1Codec.cs` / fake-phone；解码模仿 `RTSPVTPuller`。
final class Vcu1UsbPuller {
    static let shared = Vcu1UsbPuller()

    private let queue = DispatchQueue(label: "com.baixiang.vcu1.pull")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var running = false
    private var listenPort: UInt16 = 28765
    private var recvBuffer = Data()

    // Diagnostics (panel)
    private(set) var diagListening = false
    private(set) var diagSenderConnected = false
    private(set) var diagPackets: Int64 = 0
    private(set) var diagType3: Int64 = 0
    private(set) var diagType6: Int64 = 0
    private(set) var diagUnknownType: Int64 = 0
    private(set) var diagBadHeader: Int64 = 0
    private(set) var diagDecodeOK: Int64 = 0
    private(set) var diagDecodeFail: Int64 = 0
    private(set) var diagMissingConfig: Int64 = 0
    private(set) var diagAudioOK: Int64 = 0
    private(set) var diagLastError: String = ""

    // VT path — imitate RTSPVTPuller
    private var sps: Data?
    private var pps: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    /// Last submitted pts (seconds); VT callback may publish with this (imitate FFRTSP pts feed).
    private var pendingPublishPts: Double = -1
    /// 解码失败 / 不完整 GOP 后：丢掉后续 P，等下一个带参的 IDR 再出帧（勿 hold 花屏帧）。
    private var needIDRAfterFail = false

    private init() {}

    func start(port: Int = 28765) {
        let p = UInt16(clamping: max(1, min(65535, port)))
        queue.async { self.startLocked(port: p) }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    func statusLine() -> String {
        if !running { return "VCU1未启动" }
        if diagSenderConnected {
            return "VCU1已连 pk=\(diagPackets) t3=\(diagType3) ok=\(diagDecodeOK) aud=\(diagAudioOK) missCfg=\(diagMissingConfig)"
        }
        // 发送端断开后继续听；不要把 NWError 粘成主状态（Demo 发完就会断 TCP）
        if diagListening {
            if diagPackets > 0 {
                return "VCU1等待发送端 :\(listenPort) 曾收 pk=\(diagPackets) ok=\(diagDecodeOK) aud=\(diagAudioOK)"
            }
            return "VCU1等待发送端 :\(listenPort)"
        }
        if !diagLastError.isEmpty {
            return "VCU1:\(diagLastError)"
        }
        return "VCU1启动中…"
    }

    // MARK: - Lifecycle

    private func startLocked(port: UInt16) {
        if running, listenPort == port, listener != nil { return }
        stopLocked()
        running = true
        listenPort = port
        diagListening = false
        diagSenderConnected = false
        diagPackets = 0
        diagType3 = 0
        diagType6 = 0
        diagUnknownType = 0
        diagBadHeader = 0
        diagDecodeOK = 0
        diagDecodeFail = 0
        diagMissingConfig = 0
        diagAudioOK = 0
        diagLastError = ""
        recvBuffer.removeAll(keepingCapacity: true)
        resetDecoderLocked()
        Vcu1AacReset()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            diagLastError = "坏端口"
            running = false
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let lis = try NWListener(using: params, on: nwPort)
            listener = lis
            lis.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    switch state {
                    case .ready:
                        self.diagListening = true
                        NSLog("BXFloatCam VCU1 listening device_port=%u", port)
                    case .failed(let err):
                        self.diagLastError = err.localizedDescription
                        NSLog("BXFloatCam VCU1 listen failed %@", err.localizedDescription)
                        self.stopLocked()
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            lis.newConnectionHandler = { [weak self] conn in
                self?.queue.async { self?.acceptSender(conn) }
            }
            lis.start(queue: queue)
        } catch {
            diagLastError = error.localizedDescription
            running = false
            NSLog("BXFloatCam VCU1 listen create fail %@", error.localizedDescription)
        }
    }

    private func stopLocked() {
        running = false
        diagListening = false
        diagSenderConnected = false
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        recvBuffer.removeAll(keepingCapacity: false)
        resetDecoderLocked()
        Vcu1AacReset()
        NSLog("BXFloatCam VCU1 puller stopped")
    }

    private func acceptSender(_ conn: NWConnection) {
        guard running else {
            conn.cancel()
            return
        }
        // 单发送端：新连接替换旧连接（模仿隧道一对一）
        connection?.cancel()
        connection = conn
        recvBuffer.removeAll(keepingCapacity: true)
        diagSenderConnected = false
        diagLastError = ""
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.diagSenderConnected = true
                    NSLog("BXFloatCam VCU1 sender connected port=%u", self.listenPort)
                    self.readLoop()
                case .failed(let err):
                    // 对端关闭常见 NWError 0；保持 listen，仅记日志
                    self.diagLastError = ""
                    self.diagSenderConnected = false
                    NSLog("BXFloatCam VCU1 sender failed %@ (back to waiting)", err.localizedDescription)
                    conn.cancel()
                    if self.connection === conn { self.connection = nil }
                case .cancelled:
                    if self.connection === conn {
                        self.connection = nil
                        self.diagSenderConnected = false
                    }
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    // MARK: - Read / parse (fake-phone rhythm)

    private func readLoop() {
        guard running, let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.diagLastError = error.localizedDescription
                    NSLog("BXFloatCam VCU1 recv %@", error.localizedDescription)
                    conn.cancel()
                    return
                }
                if let content, !content.isEmpty {
                    self.recvBuffer.append(content)
                    self.consumePackets()
                }
                if isComplete {
                    self.diagSenderConnected = false
                    self.diagLastError = "" // 正常结束，回到「等待发送端」
                    NSLog("BXFloatCam VCU1 sender EOF (back to waiting)")
                    if self.connection === conn { self.connection = nil }
                    return
                }
                if self.running, self.connection === conn {
                    self.readLoop()
                }
            }
        }
    }

    private func consumePackets() {
        while true {
            if recvBuffer.count < Vcu1Codec.headerSize { return }
            // Validate magic/version before trusting length (bad protocol header → drop)
            if recvBuffer[0] != 0x56 || recvBuffer[1] != 0x43 ||
                recvBuffer[2] != 0x55 || recvBuffer[3] != 0x31 ||
                recvBuffer[4] != Vcu1Codec.protocolVersion {
                diagBadHeader += 1
                diagLastError = recvBuffer[4] != Vcu1Codec.protocolVersion ? "bad version" : "bad magic"
                NSLog("BXFloatCam VCU1 bad protocol header: %@", diagLastError)
                connection?.cancel()
                connection = nil
                diagSenderConnected = false
                recvBuffer.removeAll(keepingCapacity: false)
                return
            }
            // Peek length @ offset 8 BE (fake-phone / ServeIngest)
            let peekLen = Vcu1Codec.readU32BE(recvBuffer, 8)
            if peekLen > UInt32(Vcu1Codec.maxPayload) {
                diagBadHeader += 1
                diagLastError = "payload too large"
                NSLog("BXFloatCam VCU1 USB payload too large len=%u", peekLen)
                connection?.cancel()
                connection = nil
                diagSenderConnected = false
                recvBuffer.removeAll(keepingCapacity: false)
                return
            }
            let need = Vcu1Codec.headerSize + Int(peekLen)
            if recvBuffer.count < need { return }

            let frame = Data(recvBuffer.prefix(need))
            recvBuffer.removeSubrange(0..<need)
            let (packet, err) = Vcu1Codec.tryDecode(frame)
            if let err {
                diagBadHeader += 1
                diagLastError = err
                NSLog("BXFloatCam VCU1 bad protocol header: %@", err)
                connection?.cancel()
                connection = nil
                diagSenderConnected = false
                recvBuffer.removeAll(keepingCapacity: false)
                return
            }
            guard let packet else { return }
            handlePacket(packet)
        }
    }

    // MARK: - Type dispatch (narrow)

    private func handlePacket(_ p: Vcu1Codec.Packet) {
        diagPackets += 1
        switch p.type {
        case Vcu1Codec.typeProvenPayloadEnqueue:
            diagType3 += 1
            handleType3(p)
        case Vcu1Codec.typeProvenRelaySpecial:
            diagType6 += 1
            if diagType6 <= 8 || diagType6 % 100 == 0 {
                NSLog(
                    "BXFloatCam VCU1 handleType:flags:sequence:ptsUs:payload: type=6 flags=%u seq=%u pts=%llu len=%d (unproven, log only)",
                    p.flags, p.sequence, p.ptsUs, p.payload.count
                )
            }
        default:
            diagUnknownType += 1
            if diagUnknownType <= 8 || diagUnknownType % 100 == 0 {
                NSLog(
                    "BXFloatCam VCU1 unknown type=%u flags=%u seq=%u pts=%llu len=%d",
                    p.type, p.flags, p.sequence, p.ptsUs, p.payload.count
                )
            }
        }
    }

    private func handleType3(_ p: Vcu1Codec.Packet) {
        let ptsSec = p.ptsUs > 0 ? Double(p.ptsUs) / 1_000_000.0 : -1.0
        // type 表未齐：config/video/audio 默认都映成 3 → 靠 payload 自识别（对标业务：编码后 H.264/AAC）
        if looksLikeAnnexB(p.payload) {
            feedAnnexB(p.payload, ptsSec: ptsSec)
            return
        }
        if looksLikeADTS(p.payload) {
            feedADTS(p.payload, ptsSec: ptsSec)
            return
        }
        if looksLikeAACASC(p.payload) {
            p.payload.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = Vcu1AacSetConfig(base, Int32(p.payload.count))
            }
            return
        }
        if looksLikeLengthPrefixedNAL(p.payload) {
            feedLengthPrefixed(p.payload, ptsSec: ptsSec)
            return
        }
        // Single NAL without start code (rare): treat as raw NAL if type field sane
        if !p.payload.isEmpty {
            let nalType = p.payload[0] & 0x1F
            if nalType > 0, nalType < 24 {
                handleNALUnit(p.payload, ptsSec: ptsSec)
                return
            }
        }
        diagMissingConfig += 1
        if diagMissingConfig <= 5 || diagMissingConfig % 60 == 0 {
            NSLog("BXFloatCam VCU1 type=3 unrecognized payload len=%d (缺 video config / 格式未证实)", p.payload.count)
        }
    }

    private func looksLikeADTS(_ data: Data) -> Bool {
        guard data.count >= 7 else { return false }
        return data[0] == 0xFF && (data[1] & 0xF0) == 0xF0
    }

    /// MPEG-4 AudioSpecificConfig 很短（常见 2B）；避免把短视频垃圾当 ASC。
    private func looksLikeAACASC(_ data: Data) -> Bool {
        guard data.count >= 2, data.count <= 8 else { return false }
        let objType = (data[0] >> 3) & 0x1F
        // AAC LC / HE / HE-v2 object types
        return objType == 2 || objType == 5 || objType == 29
    }

    private func feedADTS(_ data: Data, ptsSec: Double) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            if Vcu1AacFeedADTS(base, Int32(data.count), ptsSec) {
                diagAudioOK += 1
            }
        }
    }

    // MARK: - H.264 feed (imitate RTSPVTPuller)

    private func looksLikeAnnexB(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data[0] == 0, data[1] == 0, data[2] == 0, data[3] == 1 { return true }
        if data[0] == 0, data[1] == 0, data[2] == 1 { return true }
        return false
    }

    private func looksLikeLengthPrefixedNAL(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        let n = Int(Vcu1Codec.readU32BE(data, 0))
        guard n > 0, n + 4 <= data.count, n < Vcu1Codec.maxPayload else { return false }
        let nalType = data[4] & 0x1F
        return nalType > 0 && nalType < 24
    }

    private func feedAnnexB(_ data: Data, ptsSec: Double) {
        var i = 0
        let bytes = [UInt8](data)
        while i + 3 < bytes.count {
            var start = -1
            var scLen = 0
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                start = i + 4
                scLen = 4
            } else if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                start = i + 3
                scLen = 3
            }
            if start < 0 {
                i += 1
                continue
            }
            var next = start
            while next + 3 < bytes.count {
                if bytes[next] == 0, bytes[next + 1] == 0, bytes[next + 2] == 0, bytes[next + 3] == 1 { break }
                if bytes[next] == 0, bytes[next + 1] == 0, bytes[next + 2] == 1 { break }
                next += 1
            }
            if next + 3 >= bytes.count { next = bytes.count }
            if start < next {
                handleNALUnit(Data(bytes[start..<next]), ptsSec: ptsSec)
            }
            i = max(next, i + scLen)
        }
    }

    private func feedLengthPrefixed(_ data: Data, ptsSec: Double) {
        var o = 0
        while o + 4 <= data.count {
            let n = Int(Vcu1Codec.readU32BE(data, o))
            o += 4
            guard n > 0, o + n <= data.count else { return }
            handleNALUnit(data.subdata(in: o..<(o + n)), ptsSec: ptsSec)
            o += n
        }
    }

    private func handleNALUnit(_ nal: Data, ptsSec: Double) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F
        if nalType == 7 {
            sps = nal
            rebuildFormat()
        } else if nalType == 8 {
            pps = nal
            rebuildFormat()
        } else if nalType == 5 {
            // IDR：恢复点；缺 SPS/PPS 时先 rebuild，仍缺则等下一包参数集
            if formatDesc == nil || decompressionSession == nil {
                rebuildFormat()
            }
            needIDRAfterFail = false
            decodeNAL(nal, ptsSec: ptsSec)
        } else if nalType == 1 || (nalType > 0 && nalType < 24) {
            // 残缺 GOP 后的 P/非关键帧：跳过，等 IDR（不要拼不完整帧）
            if needIDRAfterFail { return }
            decodeNAL(nal, ptsSec: ptsSec)
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
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
                    guard let base = buf.baseAddress else { return OSStatus(-12710) }
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
                    NSLog("BXFloatCam VCU1 VT session ready sps=%d pps=%d", sps.count, pps.count)
                } else {
                    NSLog("BXFloatCam VCU1 format desc err %d", status)
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
                let puller = Unmanaged<Vcu1UsbPuller>.fromOpaque(refcon).takeUnretainedValue()
                if status == noErr, let imageBuffer {
                    puller.diagDecodeOK += 1
                    puller.needIDRAfterFail = false
                    // 附件在 CamFrameStore.publish 统一打 BT.709；像素格式为 420v（tv/limited）
                    BXFloatPublishVideoFrame(imageBuffer, puller.pendingPublishPts)
                } else {
                    puller.diagDecodeFail += 1
                    puller.needIDRAfterFail = true
                    AVSyncClock.shared.beginVideoRecoveryFreeze(reason: "vcu1-vt-fail")
                    if puller.diagDecodeFail <= 5 || puller.diagDecodeFail % 60 == 0 {
                        NSLog(
                            "BXFloatCam VCU1 VT decode status=%d fail=%lld ok=%lld → wait IDR",
                            status, puller.diagDecodeFail, puller.diagDecodeOK
                        )
                    }
                }
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        // 与发送端建议 VUI 对齐：bt709 + tv（limited）→ 420v，勿再用无标记 420f+DeviceRGB
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
            NSLog("BXFloatCam VCU1 VT create err %d", err)
        }
    }

    private func decodeNAL(_ nal: Data, ptsSec: Double) {
        guard let formatDesc, let session = decompressionSession else {
            diagMissingConfig += 1
            if diagMissingConfig <= 5 || diagMissingConfig % 60 == 0 {
                NSLog("BXFloatCam VCU1 缺 video config（尚无 SPS/PPS）nalType=%u", nal[0] & 0x1F)
            }
            return
        }
        var len = UInt32(nal.count).bigEndian
        var avcc = Data(bytes: &len, count: 4)
        avcc.append(nal)

        let pts90k: Int64
        if ptsSec >= 0 {
            pts90k = Int64(ptsSec * 90_000.0)
        } else {
            pts90k = Int64(diagDecodeOK + diagDecodeFail + 1) * 3000
        }
        pendingPublishPts = ptsSec

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

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 3000, timescale: 90000),
                presentationTimeStamp: CMTime(value: pts90k, timescale: 90000),
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
            // USB 码流常稀疏：禁止 ._1xRealTimePlayback，避免把仅有的 IDR/稀帧再丢掉
            return VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flagsOut
            )
        }
        if blockStatus != noErr {
            needIDRAfterFail = true
            if diagDecodeFail < 8 {
                NSLog("BXFloatCam VCU1 decodeNAL prep/decode err %d → wait IDR", blockStatus)
            }
        }
    }

    private func resetDecoderLocked() {
        if let s = decompressionSession {
            VTDecompressionSessionInvalidate(s)
        }
        decompressionSession = nil
        formatDesc = nil
        sps = nil
        pps = nil
        lastSPS = nil
        lastPPS = nil
        needIDRAfterFail = false
    }
}

// MARK: - FFmpeg AAC C API (Vcu1AacBridge.m · 同 FFRTSPController @_silgen_name 风格)

@_silgen_name("Vcu1AacReset")
func Vcu1AacReset()

@_silgen_name("Vcu1AacSetConfig")
func Vcu1AacSetConfig(_ asc: UnsafePointer<UInt8>, _ len: Int32) -> Bool

@_silgen_name("Vcu1AacFeedADTS")
func Vcu1AacFeedADTS(_ data: UnsafePointer<UInt8>, _ len: Int32, _ pts: Double) -> Bool
