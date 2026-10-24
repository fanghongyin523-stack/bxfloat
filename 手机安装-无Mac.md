# 没有苹果电脑，怎么装到你的 iPhone

思路：用 GitHub 网上的苹果电脑帮你编译 → 你下载安装包 → 用手机上的 **巨魔（TrollStore）** 安装。

---

## 你要准备的

1. 苹果手机（已装巨魔）
2. 一台 Windows 电脑（你现在这台就行）
3. 一个免费的 GitHub 账号（没有就去 https://github.com 注册）

---

## 第一步：把代码放到 GitHub

你电脑里可能还没装 git，**直接用下面两种方式，不必单独装 git。**

### 方式 A（最省事）：GitHub Desktop

1. 安装 [GitHub Desktop](https://desktop.github.com/)（装完自带上传能力）
2. 登录你的 GitHub 账号
3. File → Add local repository → 选中文件夹 `e:\tuiliu`  
   - 如果提示还不是仓库：选 **create a repository**
4. 左下角写一句说明，例如：`first build`
5. 点 **Commit** → 再点 **Publish repository**（发布到网上）

### 方式 B：网页拖上去

1. 打开 GitHub → New repository（新建仓库）→ 名字随便，例如 `bxfloat` → Create
2. 点 **uploading an existing file**
3. 把 `e:\tuiliu` 里这些都拖上去（保持文件夹结构）：
   - `.github` 文件夹（很重要，没有就不能自动编译）
   - `BXFloatMVP` 文件夹
   - `手机安装-无Mac.md`、`.gitignore` 等
4. 点 Commit changes

---

## 第二步：等网上自动编译

1. 打开你的仓库网页
2. 点上面的 **Actions**
3. 点左侧 **Build IPA for TrollStore**
4. 点右侧 **Run workflow** → 再确认运行
5. 等几分钟，变成绿色对勾
6. 点进这次运行 → 最下面 **Artifacts** → 下载 **BXFloatMVP-ipa**
7. 解压后得到 `BXFloatMVP.ipa`

---

## 第三步：装到手机（巨魔）

1. 把 `BXFloatMVP.ipa` 传到手机（微信文件传输、iCloud、爱思助手等都行）
2. 用 **巨魔 / TrollStore** 打开这个 ipa → 安装
3. 主屏幕打开 **BXFloat**

---

## 第四步：怎么试功能

1. 打开 App
2. 点 **填入测试视频地址**
3. 点 **打开悬浮窗**
4. 应出现可拖动的小窗；能拖、能缩放、能关

有问题把现象发我（黑屏 / 闪退 / 装不上），我继续改。

---

## 注意

- 不需要苹果电脑，也不需要付费开发者账号（巨魔安装这条路）
- 第一次编译可能要 5～15 分钟
- 这是「目标1」：只在本 App 里悬浮，还不会盖到微信上面
