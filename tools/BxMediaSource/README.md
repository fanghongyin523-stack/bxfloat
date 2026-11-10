# BxMediaSource — 插件留接口（给 OBS / 其他软件）

按用户要求：

1. **留接口**：其他软件通过 TCP `BXMS` 帧接入（默认 `127.0.0.1:18765`）。
2. **两个通道都要**  
   - **USB 直连**：本接口 → `BxUsbDirectRelay` → VCU1 → usbmux → 手机端口（抖音默认 28765）  
   - **局域网**：业务推 RTSP/HLS 到 MediaMTX，再用现有 `BxUsbBridge` / `BXFloat-USB助手.bat`
3. **保留 OBS 推流模式**：OBS 可作为推流源（LAN），或经本接口进 USB 直连；完整 OBS 图形插件需 OBS SDK 编译（见 `obs-stub/`）。

## BXMS 帧（PC 适配层，非宣称等于 VCamTang 本地私有协议）

| 偏移 | 内容 |
|------|------|
| 0..3 | `BXMS` |
| 4 | version=1 |
| 5 | msg: 1 video_config / 2 audio_config / 3 video / 4 audio |
| 6..7 | flags u16 BE |
| 8..15 | ptsUs u64 BE |
| 16..19 | length u32 BE |
| 20.. | payload（编码后的 H.264/AAC 或 config 字节；具体 Annex/AVCC/ASC **未在参照中完全证实**） |

Relay 再打成已证实的 **VCU1 24B 头** 发到手机。

## C# 调用

```csharp
using (var c = new BxMediaSourceClient("127.0.0.1", 18765)) {
    c.SendVideoConfig(configBytes);
    c.SendVideo(frameBytes, ptsUs);
}
```

Demo：`tools/BxUsbDirect/bin/BxMediaSourceDemo.exe`
