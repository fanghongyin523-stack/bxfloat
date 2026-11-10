# 执行进展 · 2026-11-10

**时间：** 约 07:56–08:10（本地）  
**依据：** `2026-11-10_plan.md`（已过审，用户批准执行）

## 已完成

| 步骤 | 结果 |
|------|------|
| 0 PC selftest | **SELFTEST PASS**（含 fake-phone / E2E loopback） |
| 1 收端设计短注 | `call-records/2026-11-10_vcu1-recv-design.md` |
| 2–3 listen+拆包 | `Vcu1UsbPuller.swift` + `Vcu1Codec.swift`（24B 对齐 C#；NWListener 风格对齐 USBStreamBridge） |
| 4 type 分发 | type=3 → 解码；type=6 只日志；其它计数丢弃 |
| 5 解码→publish | 模仿 `RTSPVTPuller` VT；出口 `BXFloatPublishVideoFrame`；ptsUs→秒 |
| 6 UX | USB+替换 → 启 VCU1，**不**再强制 FFmpeg 拉 18554；面板拼 `Vcu1UsbPuller.statusLine()`；`MediaConfig.vcu1Port=28765` |
| 9a PC 回归 | 再跑 selftest → PASS |

## 进行中 / 阻塞

| 项 | 说明 |
|----|------|
| 7 CI 出包 | 本机 Windows 无 xcodebuild；需 push `BXFloatMVP/**` 触发 `build-ipa.yml` inject job，再取 artifact → `dist/latest` |
| 9c 真机 | 需注 dylib + 数据线 + PC Relay/Demo；未跑 |
| 音频 | 按计划延期（ASC 未证实） |

## 未证实（未发明）

- type 全表；flags 位义；Annex-B vs AVCC 是否唯一；独立 video config type  
- Demo 样包无 SPS/PPS 时预期「有收包、缺 video config、无出画」——真机需带 SPS/PPS 的流才过显示门槛

## 测法（出包后）

1. 注 `dist/latest/BXFloatInject.dylib`  
2. 面板选数据线 → 开替换 → 日志/状态应见 `VCU1等待发送端 :28765`  
3. PC：`BXFloat-USB直连助手.bat` / Relay + `BxMediaSourceDemo`（或真实源）  
4. 手机：`sender connected`；收帧计数；有 SPS/PPS 才望见画  
