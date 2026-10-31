# 部署运行手册（MicroG + Morphe + AI 字幕）

> 一次性把「Android 设备上的 YouTube AI 字幕」部署完的完整流程。
> 已在 OnePlus PJZ110（Android 17，官方 YouTube 21.43.523）上跑通到「配置可用、钩子未命中」阶段，见文末状态。

## 0. 前置

| 项 | 要求 |
|---|---|
| 电脑 | Git Bash + adb（`E:\Android\sdk\platform-tools\adb.exe`）+ JDK 21+（可用 Android Studio 自带 `jbr`） |
| 补丁工具 | `morphe-desktop-<ver>-all.jar`（MorpheApp/morphe-desktop releases） |
| 网关 | `http://192.168.2.97:8787/a2bxj5`（systemd: `immersive-translator`） |
| 设备 | 开 USB 调试 / 网络调试，`adb devices` 可见 |

```bash
export MSYS_NO_PATHCONV=1                 # 避免 Git Bash 把 /data 转成 Windows 路径
ADB="/e/Android/sdk/platform-tools/adb.exe -s <serial>"
JAVA="/e/Program Files/Android/Android Studio/jbr/bin/java.exe"
```

## 1. 网关自检

```bash
curl -s http://192.168.2.97:8787/a2bxj5/v1/models
curl -s http://192.168.2.97:8787/a2bxj5/v1/plain/models   # 手机端补丁用这个
```

两个都应返回 `hy7b` / `hy1.8b`。若 404：检查 `PATH_PREFIX`（2.97 上是 `a2bxj5`）。

## 2. 安装 MicroG-RE

补丁版 YouTube 只认 **MicroG-RE**（Morphe 分支），包名必须是 `app.revanced.android.gms`。
旧版 ReVanced MicroG 会被判定「不适配」并提示卸载。

```bash
cd /e/tmp
curl -L -o microg-re.apk \
  https://github.com/MorpheApp/MicroG-RE/releases/download/7.2.2/microg-7.2.2-icon-arm64-v8a.apk
"$ADB" push microg-re.apk /data/local/tmp/ && \
"$ADB" shell 'pm install -r -t /data/local/tmp/microg-re.apk'
"$ADB" shell 'dumpsys deviceidle whitelist +app.revanced.android.gms'   # 电池白名单
```

- 装完先打开一次 MicroG，让它完成自检（设备注册 / 云消息）。
- **卸载 MicroG 会连带清空已登录的 Google 账号**，重装后要在 MicroG → 帐户 里重新登录。
- armeabi-v7a / 无图标变体按设备 ABI 选择；TV 盒子同理。

## 3. 构建补丁版 YouTube

```bash
# 3.1 拉取设备上已安装的官方 YouTube 分卷（base + split）
mkdir -p /e/tmp/ytsplit && cd /e/tmp/ytsplit && rm -f *.apk
for p in $("$ADB" shell pm path com.google.android.youtube | sed 's/package://' | tr -d '\r'); do
    "$ADB" pull "$p" .
done

# 3.2 打包成 .apks（Morphe 会自动合并分卷）
zip -q -0 /e/tmp/yt-bundle.apks ./*.apk

# 3.3 打补丁（官方默认组合 + AI caption translator）
"$JAVA" -jar /e/tmp/morphe-desktop.jar patch \
  --patches=https://github.com/MorpheApp/morphe-patches \
  --patches=https://github.com/YYDarlinker/morphe-ai-caption-translator \
  --out /e/tmp/yt-patched.apk \
  /e/tmp/yt-bundle.apks
```

一键脚本：`bash scripts/build-patched-apk.sh <serial>`（含安装）。

产物特征（实测）：

- 包名 `app.morphe.android.youtube`（GmsCore support 补丁自动改包名 → 与官方 YouTube / RVX 共存）
- 标签 `YouTube Morphe`，启动 Activity `…morphe_black_1`
- 109 个补丁，含 `AI caption translator` / `Captions` / `GmsCore support`（指向 `app.revanced.android.gms`）
- 26.7s 出包，137MB，签名 `CN=Morphe`

## 4. 安装

```bash
"$ADB" push /e/tmp/yt-patched.apk /data/local/tmp/
"$ADB" shell 'pm install -r -t /data/local/tmp/yt-patched.apk'
"$ADB" shell 'rm -f /data/local/tmp/yt-patched.apk'
```

## 5. App 内配置

路径：**YouTube Morphe → 头像 → 设置 → Morphe → 视频 → AI 字幕翻译**

| 字段 | 值 |
|---|---|
| 启用 AI 字幕翻译（开关） | ON |
| 普通视频 / Shorts 弹出菜单开关 | ON（按需） |
| API 地址 | `http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions` |
| API Key | 任意非空（如 `local`；网关不校验，客户端要求非空） |
| 模型 | `hy7b`（网关会用 `DEFAULT_MODEL` 覆盖） |

点「测试 API」→ 成功时网关日志会出现：
`POST /a2bxj5/v1/plain/chat/completions HTTP/1.1" 200`。

> adb 代填（可选）：`input tap` + `input text`，注意先 `input keycombination 113 29` 全选再删，
> 否则会追加到默认值后面（默认 `https://api.deepseek.com`）。

## 6. 验收

1. 播放视频 → 开 CC → **长按 CC** 打开字幕菜单 →「自动翻译」→「中文 (简体中文)」。
2. 看网关是否收到成串请求：
   ```bash
   ssh root@192.168.2.97 'journalctl -u immersive-translator -n 50 --no-pager | grep plain/chat'
   ```
3. App 内「AI 字幕翻译 → 缓存与诊断 → 字幕诊断 → 展开」，关注：
   - `当前模式：AI 翻译` （若是「原字幕（零翻译 API）」= 钩子未命中）
   - `API：N 次尝试 · M 次成功`

## 7. 排错

| 现象 | 原因 / 处理 |
|---|---|
| 启动弹「MicroG 不适配」 | 装 MicroG-RE（见 §2），包名必须是 `app.revanced.android.gms` |
| 测试 API 失败 + 网关 404 | URL 少了 `PATH_PREFIX` |
| 模型列表 404 | 网关需提供 `/v1/plain/models`（本项目已加） |
| 字幕是中文但没有 API 请求 | 看到的是 YouTube 自带机翻；钩子未命中（见 §8） |
| 21.43.523 上钩子不命中 | 该版本是实验目标；回退 21.30.216（常规目标）重建 |

## 8. 当前状态（2026-10-31）

- MicroG-RE 7.2.2 安装 + 账号登录 ✅
- 补丁包构建 / 安装 / 启动 ✅
- API 配置保存 + 测试请求 200 ✅
- **播放时翻译请求未触发**：诊断显示 `当前模式：原字幕（零翻译 API）`、`target=en; translate=false`
  → timedtext 请求改写钩子在 21.43.523 上未命中（作者标注 experimental / phone acceptance pending）。
- 后续：重建 21.30.216，或转 B 路线（整轨道代理）。

---

## 9. Android TV（TiVo Stream 4K，SEI400TV）部署记录

设备：Android 12 / SDK 31 / **armeabi-v7a（32 位）** / 4.1G 数据分区（可用约 1.0G）/ 自带 Google TV GMS。
电视上的 YouTube 是 **`com.google.android.youtube.tv` 5.30.340**，而 AI 字幕补丁只支持
**手机版 `com.google.android.youtube`**（`list-patches -f com.google.android.youtube.tv` 里没有该补丁）。
所以做法是：**不改电视原版 YouTube，另外侧载一个补丁版手机 YouTube**。

### 9.1 取 32 位手机版 APK

Aptoide 的公开 API 可以直接下整包（含全部 ABI）：

```bash
curl -s "https://ws75.aptoide.com/api/7/app/get/package_name=com.google.android.youtube"   # 取 file.path
curl -L -o yt-21.42.243.apk "https://pool.apk.aptoide.com/..."
```

本次拿到的是 **21.42.243**（`native-code: arm64-v8a, armeabi-v7a, x86, x86_64`）。
它不在补丁声明列表（声明的是 21.42.241），因此打补丁时加 `--force`，App 会弹「实验性提示」。

### 9.2 构建（只保留 v7a 以省空间）

```bash
JAVA="/e/Program Files/Android/Android Studio/jbr/bin/java.exe"
"$JAVA" -jar morphe-desktop.jar patch \
  --patches=https://github.com/MorpheApp/morphe-patches \
  --patches=https://github.com/YYDarlinker/morphe-ai-caption-translator \
  --force --striplibs armeabi-v7a \
  --out yt-tv-patched.apk yt-21.42.243.apk
```

结果：109 个补丁（含 AI caption translator），25.8s，113MB。

### 9.3 安装

```bash
ADB="adb -s 192.168.2.223:5555"
curl -L -o microg-re-v7a.apk https://github.com/MorpheApp/MicroG-RE/releases/download/7.2.2/microg-7.2.2-icon-armeabi-v7a.apk
$ADB push microg-re-v7a.apk /data/local/tmp/ && $ADB shell 'pm install -r -t /data/local/tmp/microg-re-v7a.apk'
$ADB push yt-tv-patched.apk /data/local/tmp/ && $ADB shell 'pm install -r -t /data/local/tmp/yt-tv-patched.apk'
$ADB shell 'dumpsys deviceidle whitelist +app.revanced.android.gms'
```

安装后首次启动会依次弹：**实验性提示**（选「我想要实验」）→ **MicroG 电池优化提示**（点「继续」；
若循环弹，用上面的 deviceidle 白名单命令直接放行）→ 进入首页。

### 9.4 TV 上的配置

分辨率 1920×1080（`wm size` 覆盖）。按钮全部可用 `input tap` 点击（触屏事件在 TV 上也生效）：

```
我 → 设置(右上齿轮 1872,48) → 设置(Morphe) → 视频 → AI 字幕翻译
```

| 字段 | 值 |
|---|---|
| 启用 AI 字幕翻译 | ON |
| API 地址 | `http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions` |
| API Key | `local` |
| 模型 | 点「刷新」后下拉选 `hy7b`（列表实测返回 2 个模型） |

> TV 上 `input keycombination 113 29`（Ctrl+A）无效，清空输入框要：
> `input keyevent 123`（移到末尾）+ 循环 `input keyevent 67`（DEL）。

### 9.5 已验证 / 待验证

- ✅ 两个包安装成功：`app.revanced.android.gms`、`app.morphe.android.youtube`
- ✅ 启动正常，首页 / 播放 / 英文字幕渲染正常
- ✅ 配置保存 + 「测试 API」成功：网关日志 `192.168.2.223 → POST /a2bxj5/v1/plain/chat/completions 200`
- ⏳ 未完成：在「仅英文轨」的视频上选「自动翻译 → 中文(简体)」并确认网关出现成串请求。
  电视上跑的是**手机版 UI**，遥控器/触屏注入操作字幕菜单很别扭，建议接一个 USB 鼠标设置。
  注意：带原生中文字幕的视频（如 3Blue1Brown）**本来就不会调用 API**，会直接显示原生中文轨。

### 9.6 回退

```bash
$ADB shell 'pm uninstall app.morphe.android.youtube'
$ADB shell 'pm uninstall app.revanced.android.gms'   # 如果不再需要
```

电视自带 `com.google.android.youtube.tv` 全程未改动。

### 9.7 电视上启动这两个 App

TV Launcher 只显示 `LEANBACK_LAUNCHER` 应用，手机版 YouTube 与 MicroG 都只有普通
`LAUNCHER`，桌面上看不到。用应用抽屉（`com.tivo.drawer`，源码 `E:\esp\project	vdrawer`）进入；
抽屉此前"点了没反应"，已修复（详见 `docs/07-tv-alternatives.md` §4）并重新安装：

```bash
cd /e/esp/project/tvdrawer && bash build.sh
adb -s 192.168.2.223:5555 push TvAppDrawer.apk /data/local/tmp/ && adb shell 'pm install -r -t /data/local/tmp/TvAppDrawer.apk'
```

实测：抽屉 → DPAD 选中 → OK，`YouTube (M)` 打开补丁版 YouTube，`MicroG RE` 打开账号设置。
