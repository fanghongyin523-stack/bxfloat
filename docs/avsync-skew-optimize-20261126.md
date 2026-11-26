# AVSYNC skew 优化说明（2026-11-26）

## 改动文件（优化，非重组）

- `AVSyncClock.swift` — skew 离散 snap + 冷却；audioSoftLead 1.0→0.55；maxDropPerCall 0.10→0.16
- `CamAudioStore.swift` — snap 同拍 flush/裁超前；capLiveLatency 0.80→0.55
- `CamFrameStore.swift` — 进环 fps；过旧裁切 1.2s→1.0s；snap 后调声环
- `Vcu1UsbPuller.swift` — Config 就绪后 missCfg 归零
- `CamSettingsPanel.swift` — fps / drop-old / AU+AQ 注出合计

## 阈值与冷却（自证：非每帧 snap）

| 参数 | 值 | 作用 |
|------|-----|------|
| `skewSnapThreshold` | **0.50s** | `|A−V|` 达此才允许 snap |
| `skewSnapCooldown` | **0.55s** | 两次 snap 最短间隔 |
| `audioSoftLead` | **0.55s** | 音超前视频超过则 pending，防轴狂奔到数秒 |
| `maxDropPerCall` | **0.16s** | buffered 过高时每拍最多跳这么多（仍离散） |
| `targetDelay` / `maxDelay` | 0.20 / 0.48 | 未加深缓冲 |

触发路径：`noteVideoPTS` / `noteAudioEndPTS` / `mediaTime` tick；打日志 `skew-snap reason=…`。

## AU 假数原因

面板原只读 `BXFloatMicAUPaintCount`。抖音走 **AudioQueue** 时 `gPaint`(AU) 停更，`gAQPaint` 仍涨 → 显示卡在如 758。现改为 **AU+AQ** 合计。

## 出包

待 CI/Mac 编 dylib；未注入前不得写验收通过。
