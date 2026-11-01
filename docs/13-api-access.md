# 翻译平台接口地址与访问方式（2026-11-01）

> 本文是当前生产环境的接口速查。网关部署在 `172.20.16.249`，
> 上游模型在 `172.20.16.90:8012`，公网入口为 `https://airoute.codet.net`。

## 1. 拓扑与地址

```
Android App / 桌面沉浸式翻译
        │
        ├─ LAN:    http://172.20.16.249:8787/a2bxj5
        └─ 公网:   https://airoute.codet.net/a2bxj5
                         │
                    hk.codet.net:37000 (frps)
                         │
                    172.20.16.249:8787
                    immersive-translator (FastAPI)
                         │
                    http://172.20.16.90:8012/v1  (llama.cpp/GPUStack, hy7b)
```

| 项 | 值 |
|---|---|
| 新网关主机 | `172.20.16.249` |
| 代码目录 | `/opt/immersive-translator-gateway` |
| systemd | `immersive-translator.service`，`0.0.0.0:8787` |
| 路径前缀 | `a2bxj5`（`PATH_PREFIX`） |
| 上游 | `UPSTREAM_BASE_URL=http://172.20.16.90:8012/v1` |
| 模型 | `DEFAULT_MODEL=hy7b`（上游别名 `hy1.8b`，实际 7.5B） |
| 旧网关 | `192.168.2.97` 已停止/禁用，仅保留回退 |

### 地址速查

```text
LAN base:    http://172.20.16.249:8787/a2bxj5
Public base: https://airoute.codet.net/a2bxj5
```

手机端 App 填的是**完整 endpoint**，不是 base：

```text
http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions
https://airoute.codet.net/a2bxj5/v1/plain/chat/completions
```

> App 的 API 地址必须带 `/v1/plain/chat/completions`。
> 写成 `/v1/chat/completions` 会走桌面端注入/缓存链路，破坏 App 的 JSON 协议。

## 2. 认证方式

### 入站（客户端 → 网关）

**当前不校验入站 Key。**

- App 的 `API Key` 填任意非空字符串即可，例如 `sk-local`；
- 网关不会读取或校验 `Authorization`；
- 换地址后 App 会要求重填 Key，是 App 的 origin 绑定行为，不是网关要求；
- `PATH_PREFIX=a2bxj5` 只是“猜不到的路径”，**不是鉴权**。

### 出站（网关 → 上游）

网关用 `.env` 里的 `UPSTREAM_API_KEY` 访问 `http://172.20.16.90:8012/v1`。
当前上游未要求 Key，值为空。

## 3. 端点一览

所有路径都带前缀 `/a2bxj5`。

### 3.1 模型列表

```http
GET /a2bxj5/v1/models
GET /a2bxj5/v1/plain/models
```

返回：

```json
{"object":"list","data":[
  {"id":"hy7b","object":"model","owned_by":"custom-gateway"},
  {"id":"hy1.8b","object":"model","owned_by":"custom-gateway"}
]}
```

### 3.2 手机端翻译（AI 字幕）

```http
POST /a2bxj5/v1/plain/chat/completions
```

特点：

- 跳过术语/语境注入；
- 跳过翻译缓存；
- 进入 `gateway/shim.py` 协议适配：网关自己切句、编号批量翻译，
  保证 App 要求的 `source` 引文完整覆盖 `source_text`；
- 带 `response_format` 也自动走直通逻辑；
- 源文本已经是目标语言（中文→中文）时直接透传，0 模型调用。

请求体是 OpenAI Chat Completions，`user` 里放 App 的块 JSON：

```json
{
  "model": "hy7b",
  "stream": false,
  "messages": [
    {"role":"system","content":"translate"},
    {"role":"user","content":"{\"block\":\"b0\",\"source_text\":\"Hello world.\",\"language\":\"zh-Hans\"}"}
  ]
}
```

返回：

```json
{
  "id":"chatcmpl-shim-...",
  "object":"chat.completion",
  "model":"hy7b",
  "choices":[{
    "index":0,
    "message":{"role":"assistant","content":"{\"block\":\"b0\",\"events\":[{\"source\":\"Hello world.\",\"text\":\"你好，世界。\"}]}"},
    "finish_reason":"stop"
  }]
}
```

流式：请求加 `"stream": true`，返回 SSE `data: ...` 与 `data: [DONE]`。

### 3.3 桌面端翻译（注入/术语/缓存）

```http
POST /a2bxj5/v1/chat/completions
```

- 保留语境注入、术语表、英文人名保留、翻译缓存；
- 不发送 `response_format` 的桌面沉浸式翻译走这里；
- 受 `MAX_CONCURRENCY` 限制（当前 6）。

### 3.4 预热/整轨（当前 shim 模式禁用）

```http
GET|POST /a2bxj5/yt/warm?v=<video_id>
GET      /a2bxj5/yt/resolve?title=<title>
GET      /a2bxj5/yt/track?v=<video_id>&src=en&tgt=zh-Hans
```

当前 `.env` 是 `GATEWAY_SHIM=1`，`/yt/warm` 直接返回：

```json
{"status":"disabled","video_id":"...","reason":"shim_mode"}
```

不会启动 yt-dlp、不会占用模型 slot。App 的 `WarmPing` 仍会每视频发一次
`/yt/warm`，但服务端立即返回，开销很小。

### 3.5 诊断与控制台

```http
GET /a2bxj5/yt/debug/summary
GET /a2bxj5/yt/debug?limit=20
GET /a2bxj5/yt/debug/clear
GET /a2bxj5/
GET /a2bxj5/api/terms
```

- `/yt/debug/summary`：SHIM 次数、请求数、模型调用数、批次数、平均/最大批耗时；
- `/yt/debug`：最近整轨/预热日志；
- `/a2bxj5/`：Web 控制台；
- `/api/terms` 等是桌面端术语管理接口。

## 4. curl 示例

### 健康检查

```bash
curl -s http://172.20.16.249:8787/a2bxj5/v1/plain/models
curl -s https://airoute.codet.net/a2bxj5/v1/plain/models
```

### 手机端 shim 翻译

```bash
curl -sS -H 'Content-Type: application/json' \
  -d '{"model":"hy7b","stream":false,"messages":[
    {"role":"system","content":"translate"},
    {"role":"user","content":"{\"block\":\"b0\",\"source_text\":\"Hello world.\",\"language\":\"zh-Hans\"}"}
  ]}' \
  http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions
```

### 普通 OpenAI 兼容请求（直通）

```bash
curl -sS -H 'Content-Type: application/json' \
  -d '{"model":"hy7b","messages":[{"role":"user","content":"用一句话解释什么是字幕翻译。"}]}' \
  https://airoute.codet.net/a2bxj5/v1/plain/chat/completions
```

### 桌面端注入模式

```bash
curl -sS -H 'Content-Type: application/json' \
  -d '{"model":"hy7b","messages":[{"role":"user","content":"Hello world."}]}' \
  http://172.20.16.249:8787/a2bxj5/v1/chat/completions
```

### 流式

```bash
curl -N -H 'Content-Type: application/json' \
  -d '{"model":"hy7b","stream":true,"messages":[{"role":"user","content":"Hello world."}]}' \
  https://airoute.codet.net/a2bxj5/v1/plain/chat/completions
```

## 5. 手机 App 配置

App 里现在有**两套 API 配置方案**：

| 方案 | API 地址 | Key | 模型 |
|---|---|---|---|
| `LAN`（默认激活） | `http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions` | `sk-local` | `hy7b` |
| `public`（备选） | `https://airoute.codet.net/a2bxj5/v1/plain/chat/completions` | `sk-local` | `hy7b` |

路径：

```text
YouTube(Morphe) → 头像 → 设置 → Morphe → 视频 → AI 字幕翻译 → API 配置方案
```

自动线路切换会按当前网络选择：

- WiFi → 优先 `LAN`；
- 5G → 优先 `public`；
- 一条失败会自动重试另一条，60 秒后再试回首选。

> 两套方案各自保存自己的 Key（origin 绑定），来回切换不需要重填。
> 当前默认激活 `LAN`，`public` 作为移动网络/故障备选。

播放器里还要：

```text
CC → 长按 CC → 自动翻译 → 中文（简体）
```

> App 的自动线路切换会按当前网络选择 LAN 或公网：
> WiFi 优先 `172.20.16.249`，5G 优先 `airoute.codet.net`；
> 一条失败会重试另一条。

## 6. 超时、并发与缓存

| 项 | 值 | 说明 |
|---|---|---|
| `MAX_CONCURRENCY` | 6 | **只限制** `/v1/chat/completions` 普通链路 |
| shim 并发 | `SHIM_MAX_CONCURRENCY=6` | `_ask()` 全局 semaphore；不再绕过普通链路的并发保护 |
| 上游 HTTP | 180s，connect 15s | `server.py` 的 `httpx.Timeout` |
| App 请求 | connect 4s / read 16s | priority block 10s |
| App 源字幕 | 30s | `RawCaptionSource.LOAD_DEADLINE_SECONDS` |
| 响应上限 | 2MB | App 侧 `RebuildApi` |
| 源字幕上限 | 16MB | App 侧 `RawCaptionSource` |
| shim LRU | 512 条 / 30 分钟 | `SHIM_LRU_MAX` / `SHIM_LRU_TTL` |
| shim 批大小 | 600 字符 | `SHIM_BATCH_CHARS` |
| shim 单句上限 | 160 字符 | `SHIM_MAX_CLAUSE` |
| shim 重试 | 3 次 | `translate_block` |

可调环境变量（`.env`）：

```env
PATH_PREFIX=a2bxj5
MAX_CONCURRENCY=6
GATEWAY_SHIM=1
SHIM_MAX_CONCURRENCY=6
SHIM_LRU_MAX=512
SHIM_LRU_TTL=1800
SHIM_BATCH_CHARS=600
SHIM_MAX_CLAUSE=160
SHIM_SKIP_SAME_LANGUAGE=1
```

## 7. 观测与日志

```bash
# 服务状态
systemctl status immersive-translator --no-pager

# 最近访问日志
journalctl -u immersive-translator -n 100 --no-pager

# SHIM 计数
curl -s http://127.0.0.1:8787/a2bxj5/yt/debug/summary

# 最近请求
curl -s 'http://127.0.0.1:8787/a2bxj5/yt/debug?limit=20'
```

数据文件：

```text
/opt/immersive-translator-gateway/data/terms.db        术语库
/opt/immersive-translator-gateway/data/subs.db         整轨缓存（B 路线）
/opt/immersive-translator-gateway/data/gateway_live.log 普通链路日志
/opt/immersive-translator-gateway/data/yt_debug.log     SHIM/整轨事件日志
```

## 8. 安全提醒

- 公网 `https://airoute.codet.net/a2bxj5/...` **没有入站鉴权**，
  任何人知道路径都能用你的模型；
- `PATH_PREFIX` 不是密码；
- 建议至少加一层：
  - Nginx/FRP 侧 Basic Auth 或 IP allowlist；
  - 或网关校验 `Authorization`；
- 不要把上游 `172.20.16.90:8012` 直接暴露到公网；
- 当前 249 的 `frpc` 还承担 `trans.codet.net → 172.20.16.90:8012`
  的直通，若不需要建议关闭，避免模型裸奔。

## 9. 相关文档

- `docs/12-migrate-gateway-to-249.md`：迁移与 FRP 切换记录
- `docs/11-endpoint-failover-and-404.md`：404 根因与 App 自动线路切换
- `docs/14-resource-audit.md`：循环、CPU/内存与资源审计
