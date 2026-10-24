# 目标2：把 BXFloat 注入 Safari（试验）

路线：**先 A，再 B/C**。这一步只注入 **Safari**。

---

## 你需要准备

1. 手机已装 **巨魔（TrollStore）**
2. 注入工具：**TrollFools**（或你常用的同类工具）
3. 文件：`BXFloatInject.dylib`（编译产物，在 `e:\tuiliu\dist\`）

---

## 安装步骤

1. 把 `BXFloatInject.dylib` 传到手机  
2. 打开 **TrollFools**  
3. 选择 **Safari**（系统 Safari / `com.apple.mobilesafari`）  
4. 注入 / 添加 `BXFloatInject.dylib`  
5. **彻底划掉 Safari** 后重新打开  

---

## 怎么判断成功

打开 Safari 后几秒内应出现 **BXFloat 悬浮窗**，并自动播测试视频。

可试：
- 拖动 / 缩放  
- 顶栏 **地址**：改播放链接  
- **暂停 / 关闭**  

---

## 注意

- 目前 **只允许 Safari**，注入到别的 App 不会启动（安全阀）  
- 独立 App `BXFloatMVP` 仍然可用，和注入是两套入口  
- 若 Safari 打不开或闪退：用 TrollFools **取消注入**，回我现象  

---

## 以后（先不做）

- B：白名单加更多 App  
- C：越狱全局注入  
