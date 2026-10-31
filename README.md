# Android YouTube 中文字幕：自建 LLM 翻译方案

把「YouTube App 自带的机翻字幕（慢、质量一般）」替换成「本机/局域网 7B 模型的 AI 翻译」，
不需要 root，RVX 与官方 YouTube 可共存。

## 现状（已落地）

| 环节 | 位置 | 状态 |
|---|---|---|
| 翻译网关 | `192.168.2.97:/opt/immersive-translator-gateway`（systemd: `immersive-translator`） | 已部署 plain 直通模式 |
| 上游模型 | `http://172.20.16.90:8012/v1`（GPUStack，模型 `hy7b`） | 可用 |
| 手机端 | OnePlus PJZ110 / Android 17，Morphe 补丁 `AI caption translator` | 待打补丁 |
| 原桌面链路 | Firefox + 沉浸式翻译 + 油猴脚本 | 未改动，继续可用 |

网关对外地址（带 `PATH_PREFIX`）：

```
http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions
```

> 手机端**不要**用 `adb reverse` + `127.0.0.1`，改用上面的局域网地址即可（同一 Wi-Fi，任意设备通用）。

## 方案拓扑

```
        ┌────────────────────────────┐
        │ 官方 YouTube 21.43.523      │  ← Morphe + AI caption translator 补丁
        │ (com.google.android.youtube)│     每句字幕 → OpenAI 兼容请求
        └──────────────┬─────────────┘
                       │ http (YouTube 自带 NSC 已允许 cleartext)
                       ▼
        ┌────────────────────────────┐
        │ 192.168.2.97:8787          │
        │ gateway /v1/plain/…        │──── 无注入直通 ────► GPUStack hy7b
        │ （JSON Schema 客户端专用）  │
        └────────────────────────────┘

        RVX (app.rvx.android.youtube, 20.05.46) 不受影响，独立包名，继续可看
```

## 为什么需要 `/v1/plain` 直通入口

手机端补丁会发 `response_format`（JSON Schema）并要求模型只输出 JSON。
原网关会往 system prompt 追加「语义词表 + 只输出中文译文」，会破坏 schema 解析。
因此新增直通模式：**跳过语境/术语/人名规则注入与翻译缓存**，只转发。
带 `response_format` 的请求自动进入该模式，也可以显式用 `/v1/plain/chat/completions`。

同时上游 4xx/5xx 现在**原样透传**（不再包成 502），因为补丁靠错误文本判断
「response_format 不支持」并自动降级。

## 快速开始

```bash
# 0) 网关（2.97 上已由 systemd 托管）
ssh root@192.168.2.97 'systemctl status immersive-translator --no-pager'

# 1) 健康检查
curl -s http://192.168.2.97:8787/a2bxj5/v1/models

# 2) 手机：装 Morphe Manager → 打补丁（见 docs/01）
# 3) 手机：API 地址填
#    http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions
```

## 目录

```
docs/01-morphe-app-patch.md     手机 App 内补丁的完整步骤与踩坑
docs/02-gateway-plain-mode.md   网关改动的设计、代码位置、验证方法
docs/03-deploy-297.md           2.97 部署与回滚
docs/04-openwrt-redirect.md     路由层重定向 YouTube 字幕请求的可行性分析（结论：TLS 拦截走不通）
patches/                        对 immersive-context-booster 的补丁（server.py / run.sh）
scripts/adb-reverse.sh          仅调试用：USB 隧道（生产走局域网，不需要）
```

## 待办

- [ ] 手机端实际打补丁 + 验收（21.43.523 属实验目标，失败退回 21.30.216）
- [ ] 术语表以 JSON-safe 方式注入（不破坏 schema）
- [ ] 可选：整轨道翻译服务 `/yt/timedtext`（一次翻译整段、按 video_id 缓存、天然带语境）
- [ ] 可选：网关入站鉴权（当前无鉴权，局域网内任何人可用你的显卡）
