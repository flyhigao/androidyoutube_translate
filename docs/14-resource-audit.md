# 循环与资源占用审计（2026-11-01）

> 结论先说：
>
> 1. **动态线路切换本身不占资源**：没有后台轮询、没有定时探活、没有 `while(true)`；
>    只在“建立翻译会话/发请求”时做一次很小的网络判断和端点排序。
> 2. App 里真正持续跑的是**补丁原有的 UI 循环**：
>    - AI 字幕开启时，主线程每 40ms 一次的 native 字幕隐藏 tick（25Hz，多数是 early-return）；
>    - 每 2.5s 一次的全 View 树维护扫描（最多 1800 个 View，始终在跑）。
>    实测补丁自己的线程 CPU 只有 0–0.1%，主要 CPU 是视频解码/YouTube UI。
> 3. 网关没有忙等循环；空闲约 1% 单核，20 个连续请求时约 30–36% 单核，
>    系统总 CPU <2%，内存约 57MB。
> 4. 已处理：
>    - shim 上游并发已加 `SHIM_MAX_CONCURRENCY=6` 全局 semaphore；
>    - 249 的 journald 已从 3.9G 回收到 1.0G，并设置 `SystemMaxUse=1G`；
>    - `gateway_live.log` / `yt_debug.log` 已加 logrotate。

---

## 1. 动态线路切换：没有循环

代码位置：

- `DeepSeekConfig.onWifi()`：`getAllNetworks()` 遍历当前网络（通常 2–5 个）；
- `DeepSeekConfig.fallbackRequest()`：遍历 API 配置方案（上限 30 个）；
- `RebuildApi.targets()`：每次请求排 1–2 个端点；
- `RebuildApi.sendWithFailover()`：失败时最多再试一次；
- `endpointDownUntil`：最多 32 个 URL，超过就 clear。

没有：

- `while(true)` 探活；
- `Timer` / `ScheduledExecutor` 定时探测；
- `Handler.postDelayed` 循环；
- 常驻后台线程。

唯一的“网络切换相关线程”是 `WarmPing.ping()`：

- 每个视频启动一次，一个短线程；
- 一次 `GET /yt/warm`；
- connect 3s / read 5s，失败静默；
- shim 模式下服务端立即返回 `disabled`，不跑 yt-dlp。

因此：

- 正常播放：动态切换的 CPU/内存开销可以忽略；
- 快速连续切视频：可能有几个 WarmPing 线程重叠，但每个最多 5s，数量有限；
- **没有“定期探活”循环**：WiFi 恢复后，是否切回 LAN 取决于新会话/新请求的
  `onWifi` 判断，或当前线路失败后的回退；如果同一会话里公网一直成功，
  理论上可能继续用公网直到新会话。实测重新开 WiFi 后约 10s 切回 LAN，
  但不是靠独立定时器保证的。

---

## 2. App 内已有的周期性操作

| 位置 | 周期 | 条件 | 开销判断 |
|---|---:|---|---|
| `CaptionMusicSuppressor.TICK` | **40ms（25Hz）** | AI 字幕/原生字幕轨被接管时 | 主线程；多数 tick 只做 early-return + 少量 masked view 检查；补丁线程 CPU 0–0.1% |
| `CaptionButtonController.MAINTENANCE` | **2.5s** | Activity 存活就运行 | 每次全 View 树 BFS，最多 1800 个 View；**最值得优化的常驻 UI 扫描** |
| `CaptionButtonController.NATIVE_MENU_MONITOR` | **160ms** | 字幕菜单打开后最多 30s | 只在菜单窗口期，短暂 |
| `RebuildController.tick` | **80ms（12.5Hz）** | 有活跃翻译 session 时 | 负责字幕调度/位置；session 停就停 |
| `SourceLoadFlights` | 20ms 轮询 | 仅在源字幕加载中 | `Future.get(20ms)` 轮询，有 deadline；一次加载约 0.2–1s |
| `CaptionDiagnosticsWriter.flush` | 10ms × 40 | 仅打开/导出诊断时 | 最多等 400ms，不是常驻 |
| `NetworkDeadline.TIMER` | 每请求一次 | 每个 HTTP 请求 | 2 个 daemon 线程，`removeOnCancelPolicy`，不堆积 |
| `DeepSeekModelPreference.NETWORK` | 按需 | 刷新模型列表 | `newCachedThreadPool`，任务短 |
| `WarmPing` | 每视频一次 | 每个视频 | 一个短线程 + 一次 GET |

### 实测手机数据（OnePlus PJZ110）

```text
App PID 30228
线程总数：205
补丁相关线程：13 个
  CaptionPriority ×2, CaptionPrefetch ×2, CaptionSharedSo ×2,
  CaptionHttpDead ×2, caption-diagnos, DeepSeekCaption, CaptionSourceIO,
  CaptionRetireme, CaptionPresenta
补丁线程 CPU：0.0–0.1%
主线程 CPU：约 10%
前台播放整机采样：约 48% 单核（含视频解码、渲染、YouTube UI）
后台：约 3–6% 单核
PSS：约 619MB；RSS：约 836MB（YouTube + 视频解码为主）
```

结论：

- 补丁线程本身很轻；
- 25Hz tick 和 2.5s 全树扫描都在主线程，CPU 会算进主线程，
  但当前没有看到它们造成明显卡顿；
- 如果关心续航/发热，优先降 `CaptionMusicSuppressor` 的 40ms tick
  和 `CaptionButtonController` 的 2.5s 全树扫描。

### 后台行为（重要）

这两组循环是**补丁代码**，不是 YouTube 本身的循环；它们只是操作 YouTube 的 View：

- `CaptionMusicSuppressor` 隐藏 YouTube 原生字幕窗口；
- `CaptionButtonController` 查找/同步 YouTube 的 CC 按钮。

代码里**没有显式的 `onPause/onStop` 停止逻辑**，是否继续跑取决于：

- `CaptionActions.ownsNativeTrack()` 是否仍为 true；
- `CaptionButtonController` 的 Activity 是否 finishing；
- Android 是否把后台进程冻结。

实测（App 按 Home 退到后台、无 PiP）：

```text
进程 CPU：0.0%
补丁线程：0.0%
```

说明普通后台场景下 Android 已经把它压住了。但如果是 **PiP / 后台音频播放**，
session 可能仍 active，`ownsNativeTrack()` 可能继续为 true，40ms TICK
和 80ms tick 仍可能继续跑；2.5s maintenance 也会每 2.5s 醒一次
（`root.isShown()` 为 false 时不做全树扫描，只做一次廉价检查）。

因此：

- 如果只关心普通后台：当前实测接近 0%，问题不大；
- 如果经常 PiP/后台播放：建议加 lifecycle gating，
  在 `onStop` 停止 TICK/maintenance/tick（PiP 例外），`onStart` 恢复；
  这比单纯把 40ms 降到 100–200ms 更有效。

### `while(true)` 检查

| 文件 | 循环 | 边界 |
|---|---|---|
| `RawCaptionSource` | 读 HTTP body | EOF / 16MB / deadline / cancel |
| `RebuildApi` | 读 HTTP body | EOF / 2MB / deadline / cancel |
| `SourceLoadFlights` | 等共享加载 | 20ms 轮询 + deadline + cancel |

没有发现无退出条件的忙等。

---

## 3. 网关侧资源

### 实测（249）

```text
空闲：
  python3 CPU ≈ 1.0% 单核
  内存 RSS ≈ 57MB
  systemd TasksCurrent = 1
  已建立连接 ≈ 2

20 个连续 shim 请求：
  python3 CPU ≈ 30–36% 单核
  系统总 CPU ≈ 1.9%（8 核）
  RSS 仍约 57MB
```

数据文件：

```text
terms.db        484K
subs.db         804K
yt_debug.log     48K
gateway_live.log  4K
```

### 循环检查

| 位置 | 行为 | 判断 |
|---|---|---|
| `server.py` streaming | `async for` 读上游 SSE | 由上游流结束/断开结束 |
| `shim.translate_block` | 按 `SHIM_BATCH_CHARS=600` 切块，`asyncio.gather` 并发 | 有界，但**没有全局并发上限** |
| `shim` 重试 | 每块最多 3 次，然后逐条单发 | 有界 |
| `shim._LRU` | 512 条 / 30 分钟 | 有界 |
| `yt_subs._fetch_parallel` | 多 yt-dlp 子进程 + 0.25s 轮询 + 45s deadline | **仅 B 路线**；当前 `GATEWAY_SHIM=1` 不执行 |
| `server.py` `/yt/warm` | shim 模式立即返回 disabled | 不启动 yt-dlp |
| `AUTO_EXTRACT_TERMS` | 当前 `false` | 不做后台术语提取 |

### 其他资源点

| 点 | 现状 | 影响 |
|---|---|---|
| shim 上游连接 | `shim.translate_block()` 每个 block `async with httpx.AsyncClient()` | 每块新建连接池/TCP，未复用到上游；块多时增加握手与临时端口 |
| shim 日志 | `yt_subs.log_event()` 每请求同步 `open(...,"a")` 写一行 | 事件循环里做磁盘 I/O；高并发时会拖慢 |
| debug 读取 | `/yt/debug`、`/yt/debug/summary` 先 `read().splitlines()[-N:]` | 日志很大时会整文件读入内存 |
| 日志轮转 | `gateway_live.log` / `yt_debug.log` 无 logrotate | 长期增长，最终影响磁盘与 debug 内存 |

### 需要关注的点

#### 3.1 shim 链路并发（已修复）

> 2026-11-01 23:21 已加 `SHIM_MAX_CONCURRENCY=6` 全局 semaphore；
> 本地假上游测试 `SHIM_MAX_CONCURRENCY=2`，6 个并发请求的
> `max_concurrent=2`，验证生效；部署到 249 后 6 个并发真实请求
> 全部 200，单请求约 1.0–1.1s。

原问题：`concurrency_semaphore` 只包了：

```text
/v1/chat/completions 普通链路
```

`/v1/plain/chat/completions` 的 shim 路径直接 `await shim.translate_block(...)`，
而 `translate_block` 内部：

```python
await asyncio.gather(*[run(g) for g in _chunks(clauses, limit)])
```

也就是说：

- 一个 2KB block 可能拆成多个 chunk 并发打上游；
- App 同时有 focus/prefetch 多个请求；
- 多设备/桌面端同时用 plain 时，上游可能收到比 `MAX_CONCURRENCY=6` 更多的并发。

当前上游是单 slot llama.cpp 时，这不会把网关打崩，但会让请求排队、
首字延迟变长。现已用 `SHIM_MAX_CONCURRENCY=6` 包住 `_ask()`。

#### 3.2 B 路线（yt-dlp）是重操作

`yt_subs._fetch_parallel()` 会：

- 同时启动多个 `yt-dlp` 子进程；
- 每 0.25s 轮询；
- 45s deadline；
- 失败后换语言/client 重试。

当前 `GATEWAY_SHIM=1` 下 `/yt/warm` 直接返回，不会走到这里。
**不要在没有需要时把 `GATEWAY_SHIM` 改成 0**。

#### 3.3 日志与磁盘（已处理）

- `journald` 已从 **3.9G** 回收至 **1.0G**；
- 已设置 `/etc/systemd/journald.conf.d/99-immersive-maxuse.conf` 为 `SystemMaxUse=1G`；
- 已添加 `/etc/logrotate.d/immersive-translator`（weekly / rotate 4 / compress / copytruncate / su root root）；
- `gateway_live.log` / `yt_debug.log` 后续按周轮转，最多保留 4 份。

---

## 4. 建议优先级

已完成：

1. ✅ shim 上游并发 `SHIM_MAX_CONCURRENCY=6`。
2. ✅ journald 3.9G → 1.0G，`SystemMaxUse=1G`。
3. ✅ 两个日志的 logrotate。

待评估（未改代码）：

4. 如果关心续航：把 `CaptionMusicSuppressor` 的 40ms tick 降到 100–200ms，
   或改成事件驱动；把 `CaptionButtonController` 的 2.5s 全树扫描改成
   “首次 hook 成功后延长到 10s/停止”。这两项会影响 native 字幕隐藏/CC 按钮
   hook 的响应速度，需在真机上验收全屏、Shorts、PiP、评论面板等场景。
5. 可选：shim 模式下 App 不再发 `/yt/warm`，每视频省一个 HTTP 请求。

### 4.1 两项 UI 循环改动的影响

#### A. `CaptionMusicSuppressor` 40ms → 100–200ms

作用：AI 字幕开启时，定期把 YouTube 原生字幕窗口重新隐藏，避免播放器重建、
全屏/旋转、PiP、Shorts 切换时原生字幕和 AI 字幕同时出现。

- 40ms（25Hz）现在的实际工作很少：大多数 tick 只做 early-return，
  补丁线程 CPU 0–0.1%；
- 降到 100ms（10Hz）/200ms（5Hz）：
  - CPU/唤醒次数减少 60–80%，但绝对值不大；
  - 最坏情况下，播放器重建后原生字幕可能闪现 100–200ms，
    表现为“闪一下”或短暂双字幕；
  - 不影响翻译正确性，只影响过渡瞬间的视觉干净程度。
- 更稳的做法：保留事件驱动（player transition / player type / video id /
  fullscreen）立即隐藏，另加一个 500ms 的低频兜底 tick，而不是纯降频。

#### B. `CaptionButtonController` 2.5s 全树扫描延长/停止

作用：查找并 hook 原生 CC 按钮、同步它的状态、支撑 AI 字幕弹出菜单。
YouTube 在进入/退出全屏、Shorts、PiP、评论面板、视频切换时会重建 View 树。

- 2.5s 全树 BFS（最多 1800 个 View）是常驻的，即使 AI 字幕关闭也在跑；
- 延长到 10s 或首次 hook 后停止：
  - CPU 扫描次数减少，但单次扫描成本本身不大；
  - 新玩家视图可能最多 10s 内没有 hook 到 CC 按钮 →
    AI 字幕快捷开关/菜单可能不出现，或状态不同步；
  - 翻译主链路不一定受影响，但“AI 字幕按钮/菜单”体验会退化；
- 更稳的做法：
  - `onVideoId` / `onPlayerType` / `player transition` 时立即扫描；
  - 首次 hook 成功后停止定时全树扫描；
  - 保留 10–30s 的极低频兜底，而不是 2.5s 常驻。
- 验收必须覆盖：普通视频、全屏进出、旋转、Shorts、PiP、评论面板、
  字幕菜单打开/关闭、切换视频。

## 5. 复现命令

```bash
# 网关 CPU/内存
ssh root@172.20.16.249 'top -b -n 2 -d 1 -p $(systemctl show -p MainPID --value immersive-translator)'

# 网关日志/磁盘
ssh root@172.20.16.249 'du -sh /opt/immersive-translator-gateway/data/*; journalctl --disk-usage'

# 手机补丁线程
adb shell 'PID=$(pidof app.morphe.android.youtube); for t in /proc/$PID/task/*; do cat $t/comm; done | sort | uniq -c | grep -E "Caption|DeepSeek"'
adb shell 'PID=$(pidof app.morphe.android.youtube); ps -T -p $PID -o TID,%CPU,CMD | grep -E "Caption|caption"'
```
