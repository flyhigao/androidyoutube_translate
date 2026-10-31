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
