# 计划 A / B

## A：逐句翻译（已实现）

**定义**：Morphe 补丁版 YouTube（`AI caption translator`）把每一句字幕通过 OpenAI 兼容请求发到 2.97 网关，
网关直通本地模型翻译，返回给播放器叠加显示。

**验收标准**

- [x] 网关提供 `/v1/plain/chat/completions`，带 `response_format` 时自动直通（不注入、不缓存）
- [x] 上游 4xx/5xx 原样透传（供补丁做协议降级）
- [x] 2.97 部署完成，真实模型往返 0.3~0.9s，`json_schema` 可用
- [x] 补丁 APK 构建成功（109 个补丁，含 `AI caption translator`）
- [x] 安装成功：`app.morphe.android.youtube` 21.43.523，与官方 YouTube / RVX 三者共存
- [x] 资源校验：`cap_ai_title`（"AI 字幕翻译"）等字符串、`DeepSeekEnabledPreference` 设置项均已注入
- [ ] 机主在 App 内填 API 地址 / Key / 模型并「测试 API」
- [ ] 实际播放验收：字幕出现、延迟可接受、拖动/暂停同步正常

**构建记录（2026-10-31）**

| 项 | 值 |
|---|---|
| 输入 | 从手机拉取的官方 YouTube 21.43.523 四件套（base + arm64_v8a + xxxhdpi + zh）打包为 `.apks` |
| 补丁源 | `MorpheApp/morphe-patches` v2.0.0 + `YYDarlinker/morphe-ai-caption-translator` v1.6.0 |
| 工具 | `morphe-desktop-1.20.0-all.jar`（CLI，需 JDK 21+；本机用 Android Studio 自带 JBR 25） |
| 应用补丁 | 109 个，含 `AI caption translator` / `Captions` / `GmsCore support`（指向 `app.revanced.android.gms`）/ `Enable debugging` |
| 耗时 | 26.7s（合并 + 打补丁 + 签名） |
| 产物 | 137MB，签名 `CN=Morphe`，包名 `app.morphe.android.youtube` |
| 安装 | `pm install -r -t` 成功；启动正常，无 FATAL |

**App 内配置**

```
API 地址：http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions
API Key ：任意非空字符串（网关不校验；但客户端要求非空）
模型    ：hy7b（网关会用 DEFAULT_MODEL 覆盖）
```

入口：YouTube(补丁版) → 设置 → Morphe → 视频 → **AI 字幕翻译**。

**已知限制**

- 逐句请求，每句一次 LLM 调用；实测 0.3~0.9s/句（本机 1.8B~7B 档位）。
- 不注入语境/术语（按当前取舍），`at the logo` 这类黑话仍会译错。
- 21.43.523 属补丁的**实验**目标；若出现异常，退 `21.30.216`。

---

## B：整轨道翻译（待实现）

**定义**：2.97 提供 `GET /yt/timedtext`，一次拉取整条字幕轨 → 批量翻译（带全片语境）→ 按
`video_id + src_lang + tgt_lang + prompt_version` 缓存 → 返回标准 `json3`。
补丁把字幕基址改到该接口，播放器拿到的就是「已经翻好的整轨字幕」。

**为什么值得做**

- 起播等一次（2~5s），之后**逐句零延迟**，拖动/回看即时；
- 每个视频只花一次批量调用（成本、显卡压力大幅下降）；
- 天然知道 `video_id`/标题 → **语境与术语可以真正生效**（A 路线丢掉的能力）。

**里程碑**

| # | 内容 | 验收 |
|---|---|---|
| M1 | 2.97 上 `/yt/timedtext` 拉轨（透传 `v/lang/tlang/fmt/kind/pot` 等参数，`json3` 解析） | curl 返回原始轨道，时间轴与官方一致 |
| M2 | 批量翻译：按 ~40 条/批、保序、失败重试、`[[n]]` 占位对齐 | 整轨译文覆盖率 100%，无错行/漏行 |
| M3 | 缓存：SQLite 表 `subtitle_cache(video_id, src, tgt, prompt_ver, json, created_at)` | 二次请求 <50ms |
| M4 | 客户端接入：Morphe 补丁替换字幕基址（smali 字符串/路由替换） | 播放器直接显示译好的整轨字幕 |
| M5 | 语境注入：按 `video_id` 拉标题/频道 → 复用现有 analyzer 生成语境 | 术语命中率提升，抽样对比 |

**接口草案**

```
GET /{prefix}/yt/timedtext?v=<id>&lang=en&tlang=zh-Hans&fmt=json3
→ 200 application/json（json3，events[].segs[].utf8 已替换为译文）
→ 304 / 命中缓存直接返回
```

**风险**

- `timedtext` 现在常带 `pot`（proof-of-origin）；代理必须**原样透传**参数与 Cookie，否则可能 403。
- 视频可能无字幕轨 / 仅 ASR 轨 → 需要回退（返回 204，让客户端用原生逻辑）。
- 改字幕基址是**版本绑定**的 smali 工作，YouTube 升级需重新定位。
- 翻译失败要能降级为原文，不能出现空字幕。

**预计工作量**：M1–M3 半天（服务端可独立验证，不影响 A）；M4 半天~1 天（补丁调试）。

---

## 顺序

1. **先验收 A**（机主配置 + 播放实测），拿到真实延迟体感；
2. 若延迟/质量不满意 → 做 B 的 M1–M3（服务端，纯后端，可先离线验证）；
3. B 的 M4 再决定是否投入（涉及 smali 补丁维护成本）。

---

## 2026-10-31 实测进展与阻塞

**已完成**

- MicroG-RE 7.2.2（`app.revanced.android.gms`）安装完成，Google 账号已登录，YouTube Morphe 可正常观看。
- App 内 AI 配置完成并验证可达：
  `http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions`（Key `local`，模型 `hy7b`），
  「测试 API」在网关侧留下真实请求：`POST /a2bxj5/v1/plain/chat/completions 200`（12:49:55）。
- 三个开关（启用 AI / 普通视频弹菜单 / Shorts 弹菜单）均为 ON。
- 网关 `/v1/plain/models` 已补上（补丁获取模型列表不再 404）。

**阻塞**

- 播放时（CC → 自动翻译 → 中文(简体中文)），网关**没有**收到翻译请求；
  「字幕诊断 → 展开」显示：`当前模式：原字幕（零翻译 API）`、`target=en;translate=false`。
  看到的简体字幕来自 YouTube 自身机翻，不是本地模型。
- 诊断确认引擎本体已加载（`引擎：事件重建 / 1.6.0`，有 REBUILD 记录，1 次 API 尝试=测试）。

**推断**：`rewriteUrl`（timedtext 请求改写钩子）在 21.43.523 上没被触发/未命中，
即作者标注的「experimental + phone acceptance pending」。设置层与引擎层都在，唯独请求层没接管。

**下一步（按成本排序）**

1. 播放中打开播放器弹出菜单（⋮）里的「AI 字幕」单视频开关，再重选一次「自动翻译→中文」；
   看诊断的 `当前模式` 是否变为翻译态。
2. 若仍为「原字幕」→ 用 `scripts/build-patched-apk.sh` 重建到 **21.30.216**（官方常规目标，
   非实验版），大概率能命中钩子。
3. 仍不行 → 给上游提 issue（附诊断导出），或转 B 路线（整轨道代理，不依赖该钩子）。

### 2026-10-31 14:28 A 路线验收通过（此前结论作废）

之前"钩子未命中"是**测错视频**：3Blue1Brown 那条视频自带 `zh / zh-CN / zh-TW` 原生字幕轨，
补丁按设计直接显示原生中文、不调 API。换成**只有 `en` 轨**的视频后：

```
视频: https://www.youtube.com/watch?v=qudm6mShR2U （仅 en 轨，已用 ytInitialPlayerResponse 核实）
操作: CC → 长按 CC → 自动翻译 → 中文 (简体中文)
网关: 90 秒内 9 次 POST /a2bxj5/v1/plain/chat/completions 200（来自 192.168.2.204）
画面: 先显示「翻译中…」，随后显示本地模型译文，例如「一有机会就从这儿离开。」
```

结论：**逐句 AI 字幕在手机端已闭环可用**。选片原则：先用 player response 确认目标语言没有原生轨。

