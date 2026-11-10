# BXFloat 交付方案清单（按顺序执行）

> 目标：画面 + 声音都能推；支持 **USB 直连** 与 **网络推流**；其它电脑/软件可接入。  
> 手机测包：`dist/latest/BXFloatInject.dylib`（出包后以实际 commit 为准）

---

## 0. 交付物一览

| # | 交付物 | 路径 |
|---|--------|------|
| 1 | 可测注入包 | `dist/latest/BXFloatInject.dylib` |
| 2 | USB 直连助手 | `tools/BxUsbDirect/BXFloat-USB直连助手.bat` |
| 3 | 一键推 Demo | `tools/BxUsbDirect/一键推Demo.bat` |
| 4 | 其它软件接入 SDK | `tools/BxMediaSource/BxMediaSourceClient.cs` |
| 5 | 本方案清单 | `docs/delivery-plan-checklist.md` |
| 6 | 给其它 AI 的提示词 | `docs/ai-prompt-other-software-ingest.md` |

---

## 1. 电脑侧准备（每次测之前）

1. 关掉旧的助手 / Demo 黑窗口  
2. 双击 `tools/BxUsbDirect/BXFloat-USB直连助手.bat`（若有 `BxUsbDirectRelay.new.exe` 会自动替换）  
3. 确认窗口出现 `[ingest] listen OK … 18765`  
4. 手机数据线连上，信任电脑  

---

## 2. 手机侧准备

1. 注入 `dist/latest/BXFloatInject.dylib`（必须换新包）  
2. 打开抖音 → 拍摄页 → 打开悬浮面板  
3. **替换摄像头：开**  
4. **推流声音：开**（要录里有声必须开）  
5. 高级设置（可选验真融合）：  
   - **融合真实摄像头：开**  
   - **推流画面占比**：例如 70%  
   - 定时露真：测时把间隔改成 30～60 秒  

---

## 3. 两种接入方式（都必须能通）

### A. USB 直连（数据线）

1. 面板模式选 **数据线**  
2. 电脑：助手已开  
3. 推流源任选其一：  
   - 双击 `一键推Demo.bat`（样片 A/V 循环，断线自动重连）  
   - 或其它软件用 `BxMediaSourceClient` 往 `127.0.0.1:18765` 推 H.264+AAC  
4. 面板应见：`VCU1已连`，`ok`/`aud` 上涨，预览有画  
5. 录 10～20 秒 → 回放应有画有声  

### B. 网络推流（局域网）

1. 面板模式选 **局域网**，填电脑 IP  
2. 电脑：MediaMTX/推流软件在 RTSP 口出流（默认路径见面板提示 / `rtspPort`）  
3. 可选：`BXFloat-USB助手.bat`（RTSP usbmux 隧道，旧 LAN 通道）  
4. 替换开后应出画；推流声开后录里应有声  

---

## 4. 功能验收勾选（齐备度）

- [ ] USB 直连：有画  
- [ ] USB 直连：录音有推流声  
- [ ] 局域网推流：有画  
- [ ] 局域网推流：录音有推流声  
- [ ] 真融合：开融合后能看出推流+真机叠画，调占比有变化  
- [ ] 定时露真：到点露真镜头，过后回推流  
- [ ] 切「分段拍」：不整屏卡死（可短暂 hold）  
- [ ] Demo/源断线：助手不掐死接入连接；恢复后自动再有画  
- [ ] 其它软件接入：按 `docs/ai-prompt-other-software-ingest.md` 能推到 18765  

---

## 5. 接入协议要点（给开发）

- **USB 直连 ingest（本机）**：TCP `127.0.0.1:18765`，帧格式 **BXMS**（见 `BxmsCodec.cs` / `BxMediaSourceClient`）  
  - 视频：Annex-B H.264（先 VideoConfig=SPS/PPS，再 Video）  
  - 音频：ADTS AAC（先 AudioConfig=ASC，再 Audio）  
- **Relay → 手机**：VCU1 24B BE 头 + payload，默认媒体 type=3，端口抖音 `28765`  
- **局域网**：RTSP/HLS URL → 手机 FFmpeg/VT 拉流（面板填 IP）  
- **声音+画面**：两条都要持续送；只送视频会导致 failclosed 静音  

---

## 6. 已知边界（不装作没有）

- OBS 正式 DLL 插件仍为 stub（可用 Client/Demo 等价接入）  
- VCU1 type/flags 完整表未钉死（默认 type=3）  
- 主线程融合用隔行加速，观感略粗于离线精细叠画  
