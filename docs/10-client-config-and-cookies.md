# 客户端配置与 Cookie 生命周期（Morphe / Android）

> 回答两个运维问题：**AI 字幕的地址/key 在哪里配**、**字幕 Cookie 什么时候失效、怎么更新、能不能自动更新**。
>
> 网关侧的实现与取舍见主仓库 `immersive-context-booster/docs/subtitle-pipeline.md`。

---

## 1. AI 字幕配置在 App 的哪里

### 路径

```
YouTube（Morphe 版）→ 头像 → 设置 → Morphe → 视频 → 「AI 字幕翻译」
```

补丁把这一屏挂在 Morphe 设置的**视频**页（`morphe_settings_screen_12_video`）里，
位置在「旁白翻译 / Voice over translation」下面一行，key 为
`morphe_vot_screen__ai_captions`，标题 `@string/cap_ai_title`（中文「AI 字幕翻译」）。

### 屏幕里的字段

```
启用 AI 字幕翻译                      ← 总开关
普通视频弹出菜单中的 AI 字幕开关       ← 是否在播放器溢出菜单显示快捷开关
Shorts 弹出菜单中的 AI 字幕开关

API 配置
  API 配置方案        ← 可存多套（地址/key/模型 一组）
  API 地址            ← 我们的网关
  API Key             ← 网关不校验时随便填（见下）
  模型                 ← hy7b
  测试 API            ← 用当前已保存配置发一次探针请求
  清除本方案的 API Key

字幕样式 / 缓存与诊断（略）
```

### 具体填写值

| 字段 | 值 |
|---|---|
| API 地址 | `http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions` |
| API Key | 网关当前**不校验**，填任意非空字符串（如 `sk-local`）即可；`settings.UPSTREAM_API_KEY` 由网关自己带给上游 |
| 模型 | `hy7b`（上游报告的模型名可能是 `hy1.8b`，那是 llama.cpp 里的别名，`n_params=7.5B`，是同一个 7B 模型） |

> 地址必须带 `/v1/plain/`，不能写成 `/v1/chat/completions`：
> plain 路径才会进入「原生协议模式」（跳过术语/语境注入、跳过缓存、进入协议适配层）。
> 写成普通路径会走桌面版链路，App 的 JSON 必被注入内容破坏。

### 还要做一步：让播放器用「自动翻译」字幕轨

```
播放器 → 字幕 → 自动翻译 → 中文（简体）
```

AI 字幕只在「自动翻译」列表里选语言时生效；选原生轨（如「英语(自动)」）时走 YouTube 自己的字幕，不经过网关。

### 怎么确认配置生效

1. App 里点「测试 API」→ 应返回一行译文（`This is a subtitle test.` 这条探针网关会放行，不会被任何策略拦掉）；
2. 服务端 `journalctl -u immersive-translator -f | grep plain` 能看到 `POST /a2bxj5/v1/plain/chat/completions 200`；
3. `curl 'http://192.168.2.97:8787/a2bxj5/yt/debug/summary'` 里 `SHIM` 计数随播放增长。

---

## 2. 字幕 Cookie：什么时候失效、怎么更新、能否自动

### 它是什么

不是模型 API Key，也不是账号密码。它是 App 去 YouTube 取 **timed text（字幕轨）** 时带的匿名 Cookie，
只包含这 4 个：

```
YSC
VISITOR_INFO1_LIVE
VISITOR_PRIVACY_METADATA
__Secure-ROLLOUT_TOKEN
```

### 结论：**这个版本不需要手动设置，App 会自己刷新**

源码事实（`infrastructure/.../FreshYouTubeCookies.java`）：

| 项 | 值 |
|---|---|
| 来源 | `GET https://www.youtube.com/sw.js` 的 `Set-Cookie`（带 `Referer: https://www.youtube.com/`） |
| 缓存有效期 | **8 分钟**（`MAX_AGE_MS = 8 * 60 * 1000`） |
| 触发时机 | 字幕请求返回 **401 / 403** 时自动刷新 |
| 限流 | 最多同时 1 个刷新；两次尝试至少间隔 **30s**；单次预算 **3s** |
| 与旧设置的关系 | 刷新得到的 Cookie 在内存里独立使用，**不依赖**任何历史设置值 |

也就是说：手动填的那份即使过期，只要 YouTube 回一次 401/403，App 就会自动换新的。
「设置字幕 Cookie」这一项在当前版本的补丁里**已经不存在**（旧版本/早期文档里的说法已过期）。

### 什么时候会真的出问题

| 场景 | 表现 | 处理 |
|---|---|---|
| YouTube 改 `sw.js` 的 Cookie 名单 | 刷新拿不到可用 Cookie | 等补丁更新 `ACCEPTED` 列表 |
| 出口 IP 被 YouTube 判为异常（机房 IP、频繁请求） | 401/403 一直复现，字幕轨取不到 | 让手机走正常家宽出口；必要时给路由器分流规则调整 |
| 手机时间严重偏差 | Cookie/签名校验失败 | 开启自动对时 |
| MicroG 未登录 | 部分视频字幕轨不可用 | 登录 MicroG |

### 服务端还需要 Cookie 吗

**当前不需要。** 方案 D（协议适配层）完全不下载字幕轨：`yt-dlp`、`YT_PROXY`、
`data/yt-cookies.txt` 都只在旧整轨方案（B）里用到，而整轨方案已下线。

若要回滚到整轨方案，再启用：

```bash
# 2.97
YT_PROXY=socks5h://127.0.0.1:11070          # 经 SSH 隧道走路由器 PassWall（仅本机监听，故用隧道）
# 服务端 cookie 文件（Netscape 格式，4 个匿名 cookie 即可）
/opt/immersive-translator-gateway/data/yt-cookies.txt
```

服务端 cookie 的自动刷新没有做成 timer，因为整轨模式下 yt-dlp 每次请求都会现取；
只有在长期不给 `--cookies` 时才会踩 429/bot check。

---

## 3. 一页速查

```bash
# 配置位置
YouTube → 设置 → Morphe → 视频 → AI 字幕翻译 → API 配置

# 地址
http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions
# Key: 任意非空；模型: hy7b

# 播放器
字幕 → 自动翻译 → 中文（简体）

# 观测
curl 'http://192.168.2.97:8787/a2bxj5/yt/debug/summary'
curl 'http://192.168.2.97:8787/a2bxj5/yt/debug?limit=20'

# Cookie：App 自动刷新（8 分钟有效期，401/403 触发），无需手动
```

---

## 4. 备用：旧版补丁里的「设置字幕 Cookie」

早期打包的 APK（`yt-21.42.243` / 部分 TV 版）里有一个手动填 Cookie 的入口，
路径是 **播放器 → 字幕 → 设置字幕 Cookie**，填入后点「获取字幕 Cookie」。

当前版本（`21.43.523`，`app.morphe.android.youtube`）的补丁里**没有这个入口**，
因为 Cookie 已改成运行时自动刷新（见 §2）。若你手上是旧包：

1. 优先升级到当前包 —— 手动 Cookie 一旦过期就会导致字幕轨取不到；
2. 若必须留在旧包，Cookie 失效的表现是「字幕源失败 / 一直翻译中」，
   此时重新点一次「获取字幕 Cookie」即可（等价于请求一次 `https://www.youtube.com/sw.js`）。

---

## 5. 换域名 / 用反代之后「必须重填 API Key」，以及闪退

### 现象

把 API 地址从 `http://192.168.2.97:8787/...` 改成 `https://airoute.codet.net/...` 后：

1. 测试时提示要输入 API Key；
2. 随便输一个后 App 直接退出；
3. 之后 AI 字幕用不了（一直要 key）。

### 原因一：Key 与「源」绑定（设计如此）

`SecureApiKey` 把 key 用 Android Keystore 加密保存，并**同时记下 `scheme://authority`**：

```java
private static String origin(Context context) {
    URI uri = URI.create(DeepSeekConfig.baseUrl(context));
    return uri.getScheme().toLowerCase(Locale.ROOT) + "://"
         + uri.getRawAuthority().toLowerCase(Locale.ROOT);
}
private static boolean originMatches(Context context) { ... saved.equals(current) ... }
```

换域名 = origin 变了 → `load()` 直接返回空 → App 认为没有 key → 要求重填。
这是防「改地址把 key 发给别的服务器」的保护，不是 bug。

**所以：换地址后必须重填一次 Key，填什么都行**（网关不校验 `Authorization`）。
建议填 `sk-local`（纯 ASCII、单行、别粘贴）。

### 原因二：闪退来自「地址不合法」

`origin()` 没有做空值/异常保护：`URI.create(baseUrl)` 之后直接 `getScheme().toLowerCase()`。
如果保存的地址缺少 `https://`、含中文/空格/换行、或带 `#fragment`：

- `URI.create` 抛 `IllegalArgumentException`，或
- `getScheme()` / `getRawAuthority()` 返回 `null` → **NullPointerException**

`save()` 的调用链没有捕获 → **App 崩溃退出**。
而 `load()` 那边走的是 `ProviderEndpoint.validate`（失败会静默），所以崩溃后表现为「一直要 key」。

### 正确操作顺序

1. **先修地址**：AI 字幕翻译 → API 地址，清空后**手打**
   `https://airoute.codet.net/a2bxj5/v1/plain/chat/completions`
   确认：开头有 `https://`、结尾没有空格/换行、没有中文、没有 `#`。
   停手后会自动保存（summary 写的是「停止输入后自动保存」）。
2. **再填 key**：`sk-local`。
3. 点「测试 API」确认。

### 更稳的做法：用「API 配置方案」

同一屏幕顶部有「API 配置方案」，每个方案独立保存 地址 / Key / 模型：

```
方案 A  lan    → http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions   key: sk-local
方案 B  remote → https://airoute.codet.net/a2bxj5/v1/plain/chat/completions  key: sk-local
```

切换方案即可，两个 origin 各自保留自己的 key，不会再互相顶掉。

### 反代侧要求（已实测通过）

| 检查 | 结果 |
|---|---|
| `GET /a2bxj5/v1/plain/models` | 200，`application/json`，1.17s |
| `POST .../chat/completions`（非流式 + `response_format`） | 200，0.45s，返回 `{block, events}` |
| `POST .../chat/completions`（`stream:true`） | 200，1.16s，正常 SSE 分块 |
| 带 `Authorization: Bearer sk-local` | 200（网关忽略该头） |

反代**不要**加 Basic Auth（App 会拿到 401，表现成「配置无效」），也不要把路径重写掉。

### 如果修好地址后仍然闪退

那就是 Keystore 侧的问题（MicroG / 部分 ROM 上 `AndroidKeyStore` 生成密钥失败）。
两种处理：

1. 「清除本方案的 API Key」→ 再填一次；
2. 需要彻底绕开的话，可以出一个补丁版 APK：去掉 key 的 origin 绑定 + 允许空 key + `origin()` 加空值保护
   （源码在本地推导仓库，用 Morphe CLI 重新打包）。
