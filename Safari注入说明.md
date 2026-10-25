# 目标2：注入说明（白名单）

## 产物（`e:\tuiliu\dist\`）

| 文件 | 用途 |
|---|---|
| `BXFloatInject.dylib` | 注入用插件 |
| `BXFloatHost.ipa` | 试验壳（注入器一定能看到） |
| `BXFloatMVP.ipa` | 独立悬浮 App |

---

## 当前白名单 App

| App | Bundle ID |
|---|---|
| BXFloat壳 | `com.baixiang.bxfloat.host` |
| 抖音 | `com.ss.iphone.ugc.Aweme` |
| 抖音极速版 | `com.ss.iphone.ugc.Aweme.lite` |
| 微信 | `com.tencent.xin` |
| 快手 | `com.smile.gifmaker` |
| 快手极速版 | `com.kuaishou.nebula` |
| 小红书 | `com.xingin.discover` |
| 淘宝 | `com.taobao.taobao4iphone` / `com.taobao.taobao` |

注入器里**看不到的 App 无法注入**（系统 App 常见）。  
列表里有哪个，就注入哪个。

---

## 步骤

1. 巨魔注入器打开 → 选目标 App（如抖音/微信…）  
2. 注入 `BXFloatInject.dylib`  
3. **彻底划掉该 App** 再打开  
4. 几秒内应出 BXFloat 悬浮窗  

建议：先在一个 App 上试通，再注入下一个。

---

## 注意

- 目前是 **悬浮预览**（测试流/可改地址），还不是 RTSP，也不是虚拟摄像头  
- 微信/抖音等有检测风险，仅建议自用试验  
- 闪退 → 注入器里取消注入后告诉我是哪个 App  
