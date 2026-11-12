# 拍摄 / 录视频整屏卡死加固 · 2026-11-12

## 用户反馈
- 点「拍摄」大概率整屏卡住，退出重进好
- 插件已插入时点「录视频」：手机整机卡死（含原软件），要强制大退
- 对面成片已能出画有声；本轮只修收端卡顿/卡死，不改协议/编码档位

## 发现
- `dist/latest/BXFloatInject.dylib` 时间戳 2026-11-10 07:37，早于下午 `cfea165` 点直播加固，测包很可能未带上最新防卡死

## 本轮代码
- `FloatingOverlayController`：替换开着时 reattach 直接 return（连 windowLevel 都不碰）
- `CameraReplaceHooks`：begin/commit/start/stop 安静窗加长；融合禁音加长；**主线程 paint 禁止融合/ring，只 hold/整帧替换**
- `MicReplaceHooks`：主线程只转发，不 paint 音频

## 出包
- 需 CI 编 dylib 落到 `dist/latest`
