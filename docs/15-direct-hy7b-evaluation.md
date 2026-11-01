# 直连 HY7B 公网 API 的字幕可行性评估（2026-11-01）

> 结论：**能连通、能返回 200 和 JSON，但不适合直接作为 App 的 AI 字幕 API。**
> 直连 HY7B 的 quote 覆盖率不稳定，App 会判 `source_quote_mismatch` 并重试；
> 延迟也比走我们的网关高。

## 1. 被测地址

| 方案 | 地址 |
|---|---|
| 直连 HY7B（公网） | `https://trans.codet.net/v1/chat/completions` |
| 我们的网关（公网） | `https://airoute.codet.net/a2bxj5/v1/plain/chat/completions` |

`trans.codet.net` 是 249 上 frpc 的 `openai-api-trans`：

```toml
localIP = "172.20.16.90"
localPort = 8012
customDomains = ["trans.codet.net"]
```

即把 `172.20.16.90:8012` 的 llama.cpp/GPUStack 直接暴露到公网，没有网关的 shim、
没有切句、没有 quote 校验、没有 LRU 缓存。

健康检查：

```text
GET https://trans.codet.net/v1/models → 200
返回 hy1.8b（别名 hy7b，7.5B）
```

## 2. 测试方法

用 App 实际的协议构造请求：

- system prompt：从 `RebuildProtocol.PROMPT + FIDELITY_PROMPT + RebuildGuidance.SENTENCE`
  提取的完整提示词；
- user：`{"block","language","source_text","owned_tokens",...}`；
- `response_format`：App 的 `caption_events` JSON Schema；
- 校验：
  - HTTP 200；
  - `content` 可解析为 JSON；
  - `block` 一致；
  - `events[].source` 按顺序拼接 == `source_text`（忽略空白）；
  - `events[].text` 非空且中文占比 > 15%。

这是 App 的 `RebuildProtocol.parse` / `source_quote_mismatch` 的核心条件。

## 3. 结果

### 3.1 8 条混合句子（含长句、从句、否定、数字）

| 方案 | 有效 | 平均延迟 |
|---|---:|---:|
| 直连 HY7B | **3/8（37.5%）** | **412ms** |
| 我们的网关 | **8/8（100%）** | **189ms**（部分 LRU 命中） |

直连失败原因：

```text
quote_mismatch
```

典型：

- 只返回第一句：
  `The quick brown fox jumps over the lazy dog.`
  丢掉 `It was a sunny day in the park.`
- 只返回前半句：
  `Although the weather was bad,`
  丢掉主句。
- 只返回：
  `The president said`
  丢掉后面的内容。

即模型会**省略尾句/后半句**，不满足 App 的“quotes must partition all of source_text”。

### 3.2 6 条全新句子（冷启动、无缓存）

| 方案 | 有效 | 平均延迟 |
|---|---:|---:|
| 直连 HY7B | **4/6（67%）** | **463ms** |
| 我们的网关 | **6/6（100%）** | **278ms** |

网关在冷启动下仍比直连快约 1.6 倍，且全部有效。

### 3.3 不同 response_format

| 直连请求形式 | 有效 |
|---|---:|
| `response_format` = App JSON Schema | 3/8 |
| 无 `response_format` | **0/5** |
| `response_format = json_object` | **0/5** |
| `temperature=0` + JSON Schema | 1/5 |
| `temperature=0.3` + JSON Schema | 1/5 |

结论：JSON Schema 只能稍微改善格式，不能解决“省略 source”这个语义问题。

## 4. 为什么直连不适合

1. **没有 shim 的切句/编号/重试**
   - 网关把长块拆成短句，模型只翻“第 N 行”，quote 由网关保证；
   - 直连让模型自己决定 quote 边界，7B 模型经常漏掉尾句。

2. **没有 quote 校验**
   - 网关返回的 `events[].source` 一定能拼回 `source_text`；
   - 直连返回的 source 经常不完整，App 直接判 `source_quote_mismatch`，
     然后重试/放弃，表现为「翻译中…」或字幕缺失。

3. **没有 LRU 缓存**
   - 网关对相同 `target + source_text` 有 512 条 / 30 分钟 LRU；
   - 直连每次都调用模型，重复句/回看/暂停重播更慢。

4. **没有并发保护**
   - 直连把模型直接暴露给 App 的 focus/prefetch 并发；
   - 单 slot llama.cpp 会排队，首字延迟更高。

5. **公网裸模型**
   - `trans.codet.net` 没有入站鉴权；
   - 任何人知道地址都能直接调用 7B 模型；
   - 建议不需要时关闭这个 frpc proxy，或加鉴权/allowlist。

## 5. App 内不要保留直连配置

直连 HY7B 只适合简单文本翻译/调试，不适合 App 的逐块字幕协议。
**不建议在 App 里新增 `hy7b-direct` 方案。**

如果曾经添加过，删除方式：

```text
AI 字幕翻译 → API 配置方案 → 方案操作 → 删除
```

保留网关的两个方案即可：

```text
LAN:    http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions
public: https://airoute.codet.net/a2bxj5/v1/plain/chat/completions
Key:    sk-local
模型:   hy7b
```

2026-11-01 检查结果：App 的「API 配置方案」列表有两个方案：

- `LAN`：`http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions`
- `public`：`https://airoute.codet.net/a2bxj5/v1/plain/chat/completions`

没有 `trans.codet.net` / `hy7b-direct` 直连方案。

## 6. 建议

- **继续用网关的 `/v1/plain/chat/completions`**；
- 直连 HY7B 只适合简单文本翻译/调试，不适合逐块字幕协议；
- 如果以后要直连，需要把 shim 的切句、编号、quote 校验、LRU 至少搬到 App 或另一个轻代理里；
- `trans.codet.net` 若无用途，建议从 249 的 frpc 配置中移除。
