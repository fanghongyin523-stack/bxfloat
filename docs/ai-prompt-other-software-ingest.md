# 提示词：让其它 AI / 工程师把「推流软件」接到 BXFloat

把下面整段复制给其它 AI 或同事执行即可。

---

## 提示词正文（复制开始）

你要为现有推流/剪辑/采集软件增加「推到 BXFloat 手机注入」能力。不要发明私有协议；必须对接已有接口。

### 产品硬要求
1. **画面和声音都要推**（H.264 视频 + AAC 音频），不能只推一路。  
2. 支持两种用户场景（软件里都要能选或都文档化）：  
   - **USB 直连**：电脑开 BXFloat USB Direct Relay，软件把编码帧推到本机 ingest。  
   - **网络推流**：软件照常推 RTSP/到 MediaMTX；手机面板用「局域网」填电脑 IP 拉流。  
3. 其它电脑也能用：只要能连到跑 Relay 的那台机器的 ingest 地址（默认同机 `127.0.0.1:18765`；若跨机需改 Relay `ports.ini` 的 ingest listen，并注意防火墙）。

### USB 直连接入（优先实现）
- 仓库参考实现：`tools/BxMediaSource/BxMediaSourceClient.cs`、`ProgramDemo.cs`、`tools/BxUsbDirect/BxmsCodec.cs`。  
- 连接：TCP → `127.0.0.1:18765`（或配置的 ingest）。  
- 发送顺序：  
  1. `SendVideoConfig(SPS/PPS Annex-B)`  
  2. 循环 `SendVideo(access unit Annex-B)` + `SendAudio(ADTS frame)`（按 PTS 交错）  
  3. 开头再 `SendAudioConfig(ASC)`（可与视频 config 紧挨着发）  
- 断线：自动重连；手机暂时没听端口时 **不要堵死采集线程**（丢帧即可，对齐参照「relay stalled; capture kept running」）。  
- 自测：电脑先开 `BXFloat-USB直连助手.bat`，再跑你的推流；手机注 dylib、替换开、推流声开，面板 `ok/aud` 上涨且预览有画，录一段回放有声。

### 网络推流接入（必须保留）
- 软件继续输出 RTSP（或经 MediaMTX）。  
- 手机：连接模式=局域网，填电脑 IP，替换开。  
- 不要删掉原有 RTSP 推流路径；USB 与 LAN 是两条通道，用户二选一或按场景切换。

### 验收标准
- [ ] USB：有画 + 录音有推流声  
- [ ] LAN：有画 + 录音有推流声  
- [ ] 手机拔线/重开后，推流端不崩，恢复后自动再通  
- [ ] 文档写清：默认端口、BXMS 消息类型、样例代码路径  

### 禁止
- 不要改 VCU1 包头布局臆造字段。  
- 不要只推视频不推音频还声称「完整」。  
- 不要依赖未开源的 OBS DLL 才能工作；Client 接口必须独立可用。

## 提示词正文（复制结束）

---

配套方案顺序见：`docs/delivery-plan-checklist.md`。
