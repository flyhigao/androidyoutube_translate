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
