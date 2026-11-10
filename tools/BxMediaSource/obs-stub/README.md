# OBS 插件（桩 / 待接 SDK）

参照：`vcamtang-obs-usb.dll`  
行为对齐：

- 使用 OBS 视频/音频编码器（H.264 / AAC）
- 非阻塞出包；关键帧切换
- `startRelay` 拉起 USB Direct Relay
- Dock UI（可选）

本目录先占位：**完整 `.dll` 需要本机安装 OBS Studio + obs-studio 源码/SDK 才能链接**。  
在 SDK 就绪前，OBS 或其它软件可：

1. **LAN 推流模式（已保留）**：OBS 推 RTSP → MediaMTX → `BxUsbBridge`
2. **USB 直连**：用 `BxMediaSourceClient` / `BxMediaSourceDemo` 把编码帧送进 Relay

待办（有 SDK 后）：实现 `obs_module_load`，创建 output，把 `obs_encoder_packet` 转为 BXMS 写出。
