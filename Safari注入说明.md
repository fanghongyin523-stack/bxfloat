# 目标2：注入测试（不用系统 Safari）

系统 **Safari 经常不在巨魔注入器列表里**，这是正常现象。  
改用我们自己的 **「BXFloat壳」** 做试验靶。

---

## 你需要的文件（在 `e:\tuiliu\dist\`）

| 文件 | 干什么 |
|---|---|
| `BXFloatHost.ipa` | 巨魔安装 → 注入器里会出现「BXFloat壳」 |
| `BXFloatInject.dylib` | 注入进「BXFloat壳」 |
| `BXFloatMVP.ipa` | 原来的独立悬浮 App（可继续用） |

---

## 步骤

1. 巨魔安装 **`BXFloatHost.ipa`**（桌面出现「BXFloat壳」）  
2. 打开巨魔注入器，找到 **BXFloat壳** / `com.baixiang.bxfloat.host`  
3. 注入 **`BXFloatInject.dylib`**  
4. **彻底划掉**「BXFloat壳」，再打开  
5. 几秒内应出现悬浮窗并自动播测试视频  

可试：拖动、缩放、顶栏「地址」、暂停、关闭。

---

## 失败时

- 注入器仍没有「BXFloat壳」→ 确认 Host.ipa 已用巨魔装成功  
- 有壳但打开无窗 / 闪退 → 取消注入后回我现象  
