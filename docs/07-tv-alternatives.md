# Android TV 端字幕翻译方案调研（2026-10-31）

结论：**没有找到支持"自定义 AI 接口"的 YouTube TV 客户端**。
TV 上可行的只有两条：① 侧载补丁版手机 YouTube（本项目已做）；② 用 SmartTube 自带的机翻。

## 1. SmartTube（yuliskov/SmartTube）

- 事实：SmartTube 有**在线字幕翻译**（changelog 多次出现 “Auto-translated subtitles fix”），
  走的是 YouTube 的 `timedtext?tlang=`，即 **Google 机翻**，不是 AI。
- 已知缺陷：翻译语言列表里只有「中文（繁体）」；issue
  [#5749](https://github.com/yuliskov/SmartTube/issues/5749)（open）有人改
  `TranslatedCaptionTrack.java` / `VideoInfo.java` 两个文件就能加出「简体中文」。
- 不支持自定义 endpoint / API Key，所以无法接我们 2.97 的模型。
- 优点：TV 原生 UI、遥控器友好、免侧载手机版。

## 2. 其他候选

| 项目 | 星 | 形态 | 说明 |
|---|---|---|---|
| [hoangkien1703/dual-sub-replay](https://github.com/hoangkien1703/dual-sub-replay) | 51 | Android App（8+） | 开源，YouTube 双语字幕 + 端上翻译 + 点句重播；偏手机/学习场景，未见 TV 适配 |
| [ismael6499/omnitv](https://github.com/ismael6499/omnitv) | 1 | Android TV 工具 | SmartTube AI 助手、文本/评论翻译、OCR；不含字幕轨 AI 翻译 |
| arvio.tv | - | 商业 | 号称 Android TV AI 字幕，闭源收费 |

## 3. 本项目在 TV 上的实际形态

- 侧载 `app.morphe.android.youtube`（21.42.243，armeabi-v7a），与电视自带
  `com.google.android.youtube.tv` 5.30.340 共存。
- AI 配置已写入，网关实测收到来自 TV（192.168.2.223）的
  `POST /a2bxj5/v1/plain/chat/completions 200`。
- 短板：跑的是**手机版 UI**，遥控器操作字幕菜单很别扭；建议插 USB 鼠标，或用
  TiVoRemote（Wi-Fi ADB 模式）推送按键。

## 4. 电视上"找不到 App"的问题（已修）

电视 Launcher 只显示声明了 `LEANBACK_LAUNCHER` 的应用，手机版 YouTube 和
MicroG 都只有普通 `LAUNCHER`，所以桌面看不到。用作者自写的 **应用抽屉**
（`com.tivo.drawer`，源码 `E:\esp\project\tvdrawer`）进入。

原抽屉的 bug：`item_app.xml` 里每个格子设了 `android:clickable="true"`，
GridView 的 `onItemClick` 被吞掉，遥控器按 OK **没有任何反应**（"所有程序都打不开"）。

修复（已编译并安装到电视）：

1. `item_app.xml` 去掉 `android:focusable` / `android:clickable`；
2. `MainActivity` 增加 `OnKeyListener` 处理 `DPAD_CENTER/ENTER`，用
   `ComponentName` 精确启动（对没有 LAUNCHER 意图的 App 也有效），失败再回退
   `getLaunchIntentForPackage`。

验证：抽屉内 DPAD 选中 → OK，`YouTube (M)` 与 `MicroG RE` 均能正常启动。
