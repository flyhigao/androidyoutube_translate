# B 路线服务端：整轨字幕翻译（已实现）

## 为什么不用 timedtext 直连

2.97 上用普通 HTTP 抓 `/api/timedtext` **返回 0 字节**（YouTube 现在要 POT/签名）。
`youtubei/v1/player` 用 ANDROID client 也 400。
**可用方案：yt-dlp**（已装进网关 venv，实测 0 秒拉到 15KB json3）。

## 接口

```
GET  /a2bxj5/yt/track?v=<videoId>&src=en&tgt=zh-Hans     # 整轨 json3（已翻译）
POST /a2bxj5/yt/warm?v=<videoId>                          # 后台预热
响应头：X-YT-Cues / X-YT-Batches / X-YT-Elapsed
```

实现（`gateway/yt_subs.py`）：

1. yt-dlp 拉整轨 json3（人工轨优先，回退自动字幕）；
2. 按事件切分，**编号+制表符**批量送模型（实测比 JSON 数组更能保证条数对齐：
   JSON 数组 6 条只回 1 条，编号格式 6/6 全对）；
3. 缺行单条补翻；
4. 译文写回同一 event 的 `segs`，时间轴不动；
5. SQLite 缓存 `data/subs.db`（video_id + src + tgt）。

## 实测（38 秒视频，19 条字幕，2 批）

| 场景 | 耗时 |
|---|---|
| 冷启动（拉轨 + 翻译） | **9.2s** |
| 命中缓存 | **0.01s** |

样例：

```
呃，我希望能被交易离开湖人队，
因为这支球队没人能帮我，
我也无法和这支队伍一起赢球。呃，如果我
```

## 还没接上客户端

补丁版 YouTube 仍然是**逐块**调模型（`/v1/plain/chat/completions`），不会去拉 `/yt/track`。
要真正实现"一次翻完、之后零等待"，两条路：

1. **模糊缓存（推荐，不动 App）**：网关在逐块请求里，用 `source_text` 去已翻译的整轨里
   做包含匹配，命中就直接返回该条译文（~10ms），未命中才调模型。需要"播前预热"触发
   （媒体会话标题 → yt-dlp 搜索视频 ID → `/yt/warm`）。
2. **改字幕基址（真正的 B）**：写一个 Morphe/smali 补丁，把字幕 URL 指到 `/yt/track`。
   效果最干净，但要跟着 YouTube 版本维护。

---

## A 方案：模糊缓存（已实现，2026-10-31 16:05）

逐块请求到达时，网关先用 `source_text` 去**已预翻译整轨**里做包含匹配（归一化去标点、
词边界对齐、长度比例打分 ≥0.6），命中就直接返回，不再调模型。

- 新表：`data/subs.db / cue_index(video_id, idx, norm, zh, ts)`
- 命中响应：`{"block": <请求里的 block>, "events":[{"source": <请求原文>, "text": <整轨译文>}]}`
- 未命中：照常走模型（短块 ~0.5s，长块 3s+）

### 实测

| 场景 | 耗时 |
|---|---|
| 逐块请求命中 cue 缓存 | **57–63ms** |
| 未命中（照常调模型） | 400–3500ms |
| 不相关句子（防误命中） | 正确返回 None → 走模型 |

### 自动预热（`scripts/watch-and-warm.py`）

```
adb dumpsys media_session  →  标题
  → GET /a2bxj5/yt/resolve?title=<标题>   (yt-dlp ytsearch1 → 视频 ID → 后台 /yt/warm)
  → 整轨翻译完成 → cue_index 落库 → 后续逐块请求全部命中
```

实测：标题解析准确（6.1s 拿到 `<videoId>`），后台预热进行中 cue_index 持续增长。
命中率取决于**预热是否跑得完**：20 分钟视频约 200+ 条，需要 1–3 分钟（受单模型吞吐限制）。

### 上下文窗口（llama-server）

当前 `--ctx-size 12288 --parallel 4` → **3072 token/slot**。
实测补丁的单块请求：输入 1.6–2.6KB（约 500–800 token）+ 输出 200–400 token ≈ **1100–1200 token**，
3k 够用但余量不大。若看到 `context shift`/截断或想加大 `context_before/after`，建议
`--ctx-size 16384`（4096/slot），显存允许的话更稳。

---

## 性能优化（2026-10-31 16:30）

20 分钟视频（134 条字幕、268 events）实测：

| 版本 | 冷启动耗时 |
|---|---|
| 优化前（700 字/批，串行，不过滤重复） | **60–180s** |
| 优化后（去重 + 1400 字/批 + 3 批并发） | **15.9s** |

三个改动：
1. **去重**：自动字幕是滚动生成，同一句会重复多次（本例 268 events → 134 条唯一文本）；
2. **加大批量**：`YT_BATCH_CHARS=1400`（原 700），请求数从 ~20 降到 4；
3. **批间并发**：`YT_CONCURRENCY=3`，配合 llama-server `--parallel 4`，留 1 个 slot 给实时字幕。

覆盖率校验：134 条文本 → 120 条中文 + 14 条纯数字（正确保留），无漏译。

## 预热服务已迁到 2.97

```
/opt/immersive-translator-gateway/scripts/watch_and_warm.py
systemd: yt-warm-phone.service  (192.168.2.204:5555)
         yt-warm-tv.service     (192.168.2.223:5555)
```

- 2.97 已装 `android-tools-adb`，并把笔记本的 `adbkey` 复制过去（免二次授权）；
- 手机已 `adb tcpip 5555`，2.97 可直接 `adb connect`；
- 服务开机自启，日志：`journalctl -u yt-warm-phone -f`。

**注意**：手机重启后 adbd 会退回 USB 模式，需要再执行一次 `adb tcpip 5555`
（电视是网络 adb，不受影响）。

## 更正：--cache-ram 对逐块延迟没有帮助（实测）

我上一版说「--cache-ram 0 导致每次重新 prefill 整段提示词」是**错的**。A/B 实测（75 段字幕块、
prompt 3871 token、同前缀连发 3 次）：

| 配置 | 第1次 | 第2次 | 第3次 |
|---|---|---|---|
| `--cache-ram 0` | 1.76s | 1.51s | 1.52s |
| `--cache-ram 2048` | 1.82s | 1.50s | 1.49s |

日志显示第二次起 `need to evaluate at least 1 token ... (n_past = 3619)`——**同一 slot 的 KV 一直在显存里，
公共前缀本来就复用**，与 `--cache-ram` 无关。

`--cache-ram` 是主机内存里的 KV 快照缓存，只在 slot 的 KV 被挤掉/被完全不同的 prompt 覆盖时才用得上。

**结论**：逐块的真实成本是「每个块的 prompt 都不同 → ~3.5k token 要重新 prefill」，约 1.5s/块。
唯一的降法是**减少请求数 / 缩短 prompt / 改成整轨批量**，而不是调 cache-ram。
本项目的整轨路径正是这么做的（1400 字/批、3 批并发、20 分钟视频 15.9s）。

## 等待期策略：不逐条翻，只等整轨（已实现）

`YT_HOLD_WHILE_WARMING=true`（默认开）：只要有视频正在预热，逐块请求**不再调模型**，
直接返回 `{"block": <原 block>, "events": []}`（实测 34ms），客户端会继续显示「翻译中…」。
预热结束后，同一批请求走 cue 缓存（57ms）。

这样播放时的行为就是用户要的：**开头只有「翻译中」，不出现逐条机翻**，整轨准备好后一次到位。

## 怎么触发预热（不再用 adb）

手机端打开 `http://192.168.2.97:8787/a2bxj5/yt/`，粘贴视频链接 → 页面显示
`翻译中… 40/134 条（29.9%）` → 完成后自动变成「翻译完成」。

接口：`POST /yt/warm?v=<url|id>`、`GET /yt/status?v=<id>`。

> 2.97 无法自己知道你在看哪个视频（YouTube 流量是 TLS，网关看不到）。
> 要么设备主动告知（网页粘贴 / 伴生 App），要么就只能靠逐块请求里的字幕文本反推。

## 429 的真正原因与修法（2026-10 实测）

排查结论：**429 不是 IP 被整体限流，而是 YouTube 对「自动翻译字幕轨」返回 429。**

同一个视频 `GHIIuBfP3t8`、同一个出口、同一份 Cookie：

| `--sub-langs` | 结果 |
|---|---|
| `en` | `HTTP Error 429: Too Many Requests` |
| `en-orig` | 正常下载，329KB json3 |
| `en-orig,en.*` | 先写 en-orig 成功，随后 en 仍 429 |

`en` 是 YouTube 的自动翻译轨（timedtext 上带 `tlang`），`en-orig` 是原始人工/自动轨。
所以修法是**优先取 `<lang>-orig`**，失败再退回 `<lang>`，而不是死等退避。

`gateway/yt_subs.py` 现在：

```python
def _lang_candidates(src_lang):
    base = src_lang.split("-")[0]
    return [f"{base}-orig", base, f"{base}.*", "en-orig", "en"]
```

每条候选只退避一次（0 / 4s），429 就换下一条候选，比原来 0/3/12/30 秒退避快得多。

## 出口：2.97 通过路由器 PassWall 的 SOCKS 隧道

OpenWrt（`192.168.2.1`）PassWall 的真实入口：

| 项 | 值 |
|---|---|
| SOCKS5 入口 | `127.0.0.1:1070`（`socks-in`，noauth，**仅路由器本机监听**） |
| tproxy 入口 | `:1041`（`tcp_redir` / `udp_redir`，给局域网透明代理用） |
| DNS 入口 | `127.0.0.1:15353`（`dns-in`） |
| 节点 1 | `LA-xhttp`（`rPiflUD8`，`la.codet.net:443`，vless+reality+xhttp，path `/xhtp`），出口 `64.186.237.81` |
| 节点 2 | `HK-xhttp-ng`（`0ELiXGVq`，`hk.codet.net:443`，path `/xhtp1`），出口 `47.83.152.45` |
| 分流总节点 | `myshunt`，`default_node=LA-xhttp`（原始设置，已恢复） |

`1070` 只监听 `127.0.0.1`，所以 2.97 不能直连，用 SSH 隧道把它拉过来：

```ini
# /etc/systemd/system/router-passwall-socks.service  (2.97)
[Service]
ExecStart=/usr/bin/ssh -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
  -N -L 127.0.0.1:11070:127.0.0.1:1070 root@192.168.2.1
Restart=always
```

网关侧只认环境变量，不硬编码：

```bash
# /opt/immersive-translator-gateway/.env
YT_PROXY=socks5h://127.0.0.1:11070
```

> 注意：`socks5h` 的 `h` 让 DNS 也在路由器侧解析，否则 YouTube 域名会被 2.97 本地解析后按 IP 直连，代理等于没用。
> 实测两个节点出口 IP 不同（LA `64.186.237.81` / HK `47.83.152.45`），HK 节点更容易触发
> `Sign in to confirm you're not a bot`，所以**保持 `default_node=LA-xhttp`**，不要为抓字幕改全局默认节点。

## 实测结果（修复后）

```text
GHIIuBfP3t8  440 条：fetching 10s → working 20s → done（总计约 30s）
mVLa38NhY3Q  198 条：fetching 5s  → working 15s → done（总计约 20s）
```

`/yt/track?v=GHIIuBfP3t8` 返回中文 json3，首句：
`第11页，我们正在大楼里展示NBA总冠军奖杯。`

## 预热失败不再退回逐句

`yt_subs.should_hold()`：预热中 **或** 预热失败 600s 内（`YT_HOLD_ON_ERROR` / `YT_HOLD_ON_ERROR_SECONDS`），
逐块请求一律返回空 `events`，播放器继续显示「翻译中」，不会再掉回逐句机翻。

## 「翻译中」反复出现的真正原因（2026-10-31 日志实证）

现象：开头等一会儿出译文，正常显示约 30 秒后又变「翻译中」；暂停等一会儿好了，再过一会儿又卡。

网关日志（旧代码）证据：

```
23:22:59  GET /yt/warm?v=NrKWR562rX8   (x2)
23:23:05  GET /yt/warm?v=LVH8BTJV2Go   (x4)
23:25-23:30  POST /v1/plain/chat/completions ... 200 OK   ← 全部被 hold，返回空 events
```

再查这两个视频的抓轨结果：

```
ERROR: [youtube] LVH8BTJV2Go: Sign in to confirm you're not a bot.
ERROR: [youtube] NrKWR562rX8: Sign in to confirm you're not a bot.
```

三个叠加的 bug：

1. **hold 是全局的**：`any_warming()` / `any_failed()` 不看视频 ID。
   任何视频一旦开始预热（哪怕是别的视频），当前视频的**所有**未命中块都被拦成「翻译中」。
2. **预热失败后 600 秒内继续全局 hold**：`any_failed()` 默认 600s。
   而这两个视频用默认 client 抓轨必然失败（bot check）→ 等于常在「翻译中」。
3. **多 cue 的 block 匹配不到**：App 的 `source_text` 常常跨 2~3 条字幕，
   拼起来的 norm 不等于任何单条 cue，`cue_lookup` 全部 miss → 落回模型 1.6s+/块。

修复：

| 问题 | 修法 |
|---|---|
| 全局 hold | `should_hold(text)` 只看 `ACTIVE`（最近一次 WarmPing 的视频），并按位置判断 `pos > ready_ms` |
| 抓轨 bot check | 多 client **并行**（`android_vr,tv_embedded,默认,android`），谁先拿到用谁，4.5s→3s |
| 429 自动翻译轨 | `--sub-langs "en-orig,en"` 合并请求，`en-orig` 成功即用 |
| 多 cue block | 新增 `compose_lookup()`：按时间顺序把已翻译 cue 拼回 block，实测 0.01s 命中 |
| 等待太久 | 时间窗口推进：首窗口 30s，之后 120s；`ready_ms` 实时反映“已能播到第几秒” |

注意 `--extractor-args youtube:...` **多次传递是后者覆盖前者**，必须合成
`youtube:player_client=X;player_skip=webpage,configs`，否则静默变成 “no subtitles”。

## 观测端点

```bash
GET /a2bxj5/yt/debug            # 当前 active、各视频进度、最近 40 行日志
GET /a2bxj5/yt/debug/summary    # 命中/hold/调模型次数 + 每批耗时统计
GET /a2bxj5/yt/debug/clear      # 清空日志
```

日志事件：`ACTIVE / WARM_START / WARM_FETCH / FETCH_OK / FETCH_LANGS_FAIL /
WARM_TRACK / BATCH / WINDOW / WARM_DONE / WARM_ERROR / REQ_HIT / REQ_MISS /
REQ_MODEL`，落在 `/opt/immersive-translator-gateway/data/yt_debug.log`。

## 2026-10-31 夜间实测：整轨方案的真实命中率（12 分钟视频 MFoZPzApJRE）

用户反馈：前 2 分 40 秒出现 4 次「翻译中」。日志统计：

```
REQ_HIT   9      命中缓存（0.01~0.02s）
REQ_MISS  38     未命中
REQ_MODEL 35     落回模型（每个 1.6s+）
WARM      36.25s 完成（fetch 3.53s，窗口 0~28s 就绪于 4.9s，0~239s 就绪于 15s）
```

**整轨本身没问题**：`ready_ms` 在 15 秒时已经覆盖到 239 秒，而播放才走到 15 秒。
问题 100% 出在「块 → 缓存条」的匹配上。

### 根因：App 的 block 是 token 区间，经常切断字幕条

用 `difflib` 把 MISS 的 `source_text` 和整轨 norm 对齐，覆盖率全部是 **1.00**——文本完全在轨里，
只是**边界不一样**：

```
app : all right uh deer and danny after one of the weirdest basketball games i ve ev…
mine: …weirdest basketball games i ve ever seen they were so cooked in the first quarter…
```

- `cue_lookup` 的判分是 `min(len)/max(len)`，块是某条字幕的前半截时得分 ≈ 0.5 < 0.6 → 判 miss
- `compose_lookup` 要求 90% 覆盖且 chunk 与 cue 完全相等 → 被切断的首尾拼不上 → 判 miss

而返回「超集译文」是**协议不允许**的：App 的 `PROMPT` 要求回复里的 `source` 引文必须
**完整划分 `source_text`**，多一个字都会被判无效。

### 连带发现：同一块被反复重试

日志里同一段文本出现 3~4 次（`>> He's a little shook…` ×4、`The minivan had some moments…` ×4），
说明回复没通过 App 的严格解析 → App 重试 → 又一次模型调用。35 次调用里可能只有 10 个不同的块。

### 结论

| 事实 | 含义 |
|---|---|
| 整轨翻译本身 36s 完成、位置覆盖超前播放 | 整轨**不是**瓶颈 |
| 命中 9 / 请求 47 | 整轨缓存对 App 的 token 区间**天然不匹配** |
| 未命中 → 模型 1.6s+ 且被重复重试 | 「翻译中」全部来自这里 |

## 转向：透明转发模式（passthrough）

考虑到「术语注入 + 缓存 + hold」三层复杂度实际换不到命中率，改为可切换的透明模式：

```bash
# /opt/immersive-translator-gateway/.env
GATEWAY_PASSTHROUGH=1     # 1=原样转发给上游，只记日志；0=旧的整轨/注入逻辑
```

透明模式下 `_passthrough()` 完全不动 messages、不查缓存、不 hold，只记录：

```json
{"event":"PT","ms":311,"chars":114,"status":200,"sys":0,"prompt":28,"out":21,
 "in_head":"All right. Uh, deer and Danny…","reply":"好的。呃，迪尔和丹尼…"}
```

### 关掉注入后，单块延迟实测（hy7b, Hy-MT2-7B-Q4）

| 场景 | 旧（注入 3619 token prompt） | 现在（透明，prompt 46~63 token） |
|---|---|---|
| 单块 150~190 字符 | 1.5~1.9s | **0.32~0.66s** |
| 4 块并发 | — | **0.79~1.09s** |

即：原版「逐块翻译」在本地 7B 上其实是够快的，**慢的是我们自己加的注入与缓存层**。
这也验证了用户判断：应该先退回原版行为，用量化数据再决定要加什么。

### 备份

```
/opt/immersive-translator-gateway.track-20261101-0003.tar.gz     # 整轨版完整备份
/opt/immersive-translator-gateway.track-20261101-0003-gateway/   # 仅 gateway/ 目录
E:\tmp\gateway-track-backup-20261101-0003\                       # 本地副本
```

回滚：解开 tar 覆盖 `/opt/immersive-translator-gateway/gateway/`，把 `.env` 里
`GATEWAY_PASSTHROUGH=0`，重启 `immersive-translator`。

## 2026-11-01 透明模式实测：原版协议为什么一直「翻译中」

`GATEWAY_PASSTHROUGH=1` 下播放 2 分钟，58 条 `PT` 日志，特征：

```
chars=5771~6846   prompt=1196~1641   ms=0.8s → 2s → 4s → 7.3s（越来越慢）
reply 开头：{"block":"b0_0_15","language":"zh-Hans","source_text":"All right. Uh, deer…
```

**模型把输入 JSON 原样抄了回来**，`source_text` 字段都在，注定过不了 App 的解析 → App 重试 →
同一 `in_head` 在日志里出现 3~4 次 → 越重试越排队 → 一直「翻译中」。

单独复现同一个 block（4 条字幕 / 309 字）：

| 方式 | 耗时 | 结果 |
|---|---|---|
| 原版 system prompt，无 `response_format` | 768ms | 合法 JSON，但只翻了前 2 条，**没覆盖完整 source_text** |
| 原版 system prompt + `json_schema` | 960ms | 同上 |
| 换成精简中文指令 | 2629ms | `source` 写成中文、内容重复，彻底失败 |

结论：**7B 翻译模型无法稳定满足「引文必须逐字完整划分 source_text」这个协议要求。**
这不是提示词能修好的，也不是加缓存能绕过的。

## 现在的方案：协议适配层（shim）

`gateway/shim.py`：**切句由网关做，模型只做「第 N 行 → 译文」**。

```
App 请求 {block, language, source_text, owned_tokens, context_*}
  ↓ 网关用正则切句（切分可逆：拼接结果 === source_text）
  ↓ 编号批量送模型（1400→600 字/批，缺行只重问缺的那几条）
  ↓ 网关拼回 {"block": 原 block, "events":[{source: 本网关切的句子, text: 译文}]}
App 校验：引文逐字、顺序、覆盖全部 source_text → 通过
```

实测（真实字幕轨，全部 `完整划分=True`）：

| block 规模 | 耗时 |
|---|---|
| 4 条 / 309 字 | 728ms |
| 10 条 / 722 字 | 1.41s |
| 20 条 / 1465 字 | 1.77s |
| 40 条 / ~2900 字 | 3.72s |

开关：

```bash
GATEWAY_SHIM=1          # 协议适配层（当前）
GATEWAY_PASSTHROUGH=0   # 1=完全透明转发（只记日志，用于观察原版行为）
```

`GATEWAY_SHIM=1` 时 `/yt/warm` 返回 `{"status":"disabled","reason":"shim_mode"}`，
不再做整轨预热（否则会白占模型 slot）。

日志：`SHIM`（成功，含 ms/chars/events）、`SHIM_FAIL`（失败回落）、`PT`（透明模式）。

## 2026-11-01 定稿：协议适配层实测通过

用户实播 12 分钟视频（含多次拖动进度）后的日志统计：

```
SHIM 请求 41 条
avg 554ms   p50 561ms   p90 920ms   max 1447ms
>2s 的请求：0
平均 block：183 字符 / 3.2 条事件
重复 head：4（"[music]" "Heat." 这类真实重复，不是重试风暴）
```

对比三个版本的同一个指标：

| 版本 | 单块耗时 | 结果 |
|---|---|---|
| 逐块 + 注入（术语/语境/占位符） | 1.5~1.9s（prompt 3619 token） | 开头等很久，后面排队 |
| 透明转发（原版协议） | 0.8s → 7.3s 递增 | 模型抄写输入 → App 重试 → 卡「翻译中」 |
| **协议适配层（shim）** | **avg 554ms / p90 920ms** | 正常出字幕，拖动也跟得上 |

### 最终结构

```
Morphe（RebuildProtocol）
  │ POST /a2bxj5/v1/plain/chat/completions  {block, source_text, owned_tokens, ...}
  ▼
网关 server.py → shim.py
  │ ① 切句（可逆，拼接 === source_text）
  │ ② 编号批量 → hy7b（600 字/批，缺行只重问缺的）
  │ ③ 拼回 {block, events:[{source, text}]}
  │ ④ 完全相同 source_text 直接命中内存 LRU（0ms）
  ▼
App 校验引文 → 通过 → 显示
```

没有任何术语注入、语境注入、整轨预热、cue 索引。`/yt/warm` 在 shim 模式返回
`{"status":"disabled","reason":"shim_mode"}`。

### 开关一览

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `GATEWAY_SHIM` | `1` | 协议适配层（当前方案） |
| `GATEWAY_PASSTHROUGH` | `0` | 1 = 完全透明转发，只记日志（用于对照/观察原版） |
| `SHIM_BATCH_CHARS` | `600` | 每次模型请求的字符上限 |
| `SHIM_MAX_CLAUSE` | `160` | 单句超过则按空白二次切（保持可逆） |
| `SHIM_LRU_MAX` / `SHIM_LRU_TTL` | `512` / `1800` | 完全相同块的内存缓存 |

### 为什么它稳

App 的失败模式只有两种：**引文对不上**（模型少翻/多翻）和 **回复不是那个 JSON**（模型抄输入）。
shim 把这两件事都从模型手里拿走了——引文由网关生成，外层 JSON 由网关拼装，
模型只剩「第 N 行翻成第 N 行」这一个它能稳定完成的任务。
