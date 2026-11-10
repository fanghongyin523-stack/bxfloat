# 步骤1 · 手机 VCU1 收端设计短注 · 2026-11-10

**状态：** 已过计划评审；执行中。不写新协议。

## 事实链（只对齐已有参照）

1. 手机 `NWListener` 听 `device_port`（抖音默认 **28765**，同 `tools/BxUsbDirect/ports.ini`）。
2. PC usbmux `Connect` → accept → 「sender connected」。
3. 循环读：**先 24B 头**，再按 `length@offset8` BE 读 body（**模仿** `SelfTest.cs` fake-phone / `BxUsbDirectRelay.ServeIngest`）。
4. 校验 `VCU1` + `version=1`；坏头打日志并断连（意图对齐参照 `bad protocol header`；错法对齐 `USBStreamBridge` cancel）。
5. `length > 0x400000` → reject（**模仿** `Vcu1Codec.MaxPayload`）。
6. type 分发（窄）：
   - **type=3**：媒体载荷 → 尝试 H.264 解码 → `BXFloatPublishVideoFrame`（已证实默认 enqueue）。
   - **type=6**：只日志，不发明业务。
   - 其它：日志 + 计数丢弃。
7. 显示出口强制现有环：`BXFloatPublishVideoFrame` /（音频延期）`BXFloatPublishAudioPCM`；pts = `ptsUs / 1e6`。

## 包头（与 Vcu1Codec.cs 逐字节一致）

| 偏移 | 字段 |
|------|------|
| 0..3 | `V` `C` `U` `1` |
| 4 | version = 1 |
| 5 | type u8 |
| 6..7 | flags u16 BE |
| 8..11 | length u32 BE |
| 12..15 | sequence u32 BE |
| 16..23 | ptsUs u64 BE |

## 模仿清单

| 点 | 参照 |
|----|------|
| listen/accept/queue/statusLine | `USBStreamBridge.swift` |
| 24B 编解码 | `tools/BxUsbDirect/Vcu1Codec.cs` |
| 读头+length | `SelfTest.cs` fake-phone |
| NAL→VT→像素 | `RTSPVTPuller.swift`（工程内已有 annex-B/NAL+VT） |
| 出帧 | `FFRTSPBridge.m` → `BXFloatPublishVideoFrame` |
| 端口配置字段写法 | `MediaConfig.rtspPort` |

## 明确不做 / 未证实

- 不改 VCU1 定义；不编 type 全表；不瞎拼 SPS。
- Annex-B vs AVCC、独立 config type：**未证实**。type=3 优先按工程已有 NAL 路径试；无 SPS/PPS 则打「缺 video config」，接受「有包无画」风险。
- 音频 ASC：先延期，主线视频。
- USB 直连开替换时 **不** 强制再拉 `18554` RTSP；RTSP 隧道可保留作回退基础设施，但不与 VCU1 抢灌环。
