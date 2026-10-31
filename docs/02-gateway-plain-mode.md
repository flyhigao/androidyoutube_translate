# 网关改动：`/v1/plain` 直通模式

代码：`immersive-context-booster/gateway/server.py`（补丁见 `patches/immersive-gateway-plain-mode.diff`）

## 问题

手机端客户端（Morphe `AI caption translator`、PolyglotYT 等）的 System Prompt 里写死了
**JSON Schema 输出协议**（`response_format: json_schema`），并按结构解析回复。

原网关对任何请求都会追加：

- 英文人名强制保留规则
- 术语映射表
- 语境参考
- 「请严格只输出对应中文翻译结果，严禁输出任何多余解释、前缀说明或未要求的符号」

最后一句会直接把模型推向「纯文本译文」，破坏 JSON 解析 → 手机端一条字幕都出不来。

另外原网关把上游 4xx/5xx 统一包成 `502 上游模型请求失败`，而补丁依赖错误文本
（`response_format_unsupported` / `model_rejected`）做协议降级，包起来就协商失败了。

## 改动

1. **直通模式判定**

```python
is_plain_mode = (
    request.url.path.rstrip("/").endswith("/v1/plain/chat/completions")
    or bool(body.get("response_format"))
)
```

2. 直通模式下跳过：翻译缓存读写、术语匹配、占位符保护、全部 System Prompt 注入。
3. 新增路由 `POST /v1/plain/chat/completions`（与 `/v1/chat/completions` 共用实现）。
4. 新增 `UpstreamHTTPError`：上游 ≥400 时保留 status + body，原样返回给客户端。
5. SDK 不变：仍然强制 `model=DEFAULT_MODEL`、`temperature` 默认 0.3。

## 验证（本地假上游，5 项断言全过）

```
普通 /v1/chat/completions          → has_injection=true    ✅ 桌面链路不受影响
带 response_format                 → has_injection=false   ✅ 自动直通
/v1/plain/chat/completions         → has_injection=false   ✅ 显式直通
plain + stream=true                → SSE 完整可重组        ✅
上游 400(response_format 不支持)    → 400 + 原始错误体       ✅ 可协商降级
```

复现方式见 `scripts/verify-plain.sh`（会启动假上游 + 临时网关，不动生产配置）。

## 兼容性

- 沉浸式翻译（桌面）不发送 `response_format`，路径也不是 `/v1/plain` → 行为完全不变。
- 手机端若用 PolyglotYT（纯文本输出），直接走原 `/v1/chat/completions` 即可，能吃到术语库。
