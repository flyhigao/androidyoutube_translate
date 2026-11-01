> **2026-11-01 22:34 实测**：手机 App 的 API 地址已改为
> `http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions`。
> WiFi 下走 249（249 日志来源 `172.20.16.246` NAT），5G 下自动走
> `airoute.codet.net`（249 日志来源 `127.0.0.1:0` frpc），播放中切换网络可自动恢复。

# 404 反复出现 / 内网与公网自动切换（2026-11-01 修复）

> 结论先说：
>
> 1. **你看到的 404 不是网关返回的**。网关 `journalctl` 在对应时刻没有任何 404；
>    第一次 404 是公网反代/FRP 链路的一次瞬时响应。
> 2. **真正让它“一直坏到换几个视频才恢复”的是 App 自己的 bug**：
>    `RebuildApi` 把 404 当成“配置永久错误”写进了进程级 `blocked` 表，
>    之后所有请求在发网络之前就直接抛 404，连 HTTP 都没有发出。
> 3. 已打补丁修掉：404 不再永久拉黑；并加入“WiFi 优先内网 / 移动网络优先公网”的
>    自动线路选择，失败一次自动切另一条，60 秒后再试回首选线路。
> 4. 新包已安装到手机（2026-11-01 14:29，数据保留），待解锁后做一次播放验收。

---

## 1. 现场证据

### 1.1 手机端诊断（`caption-diagnostics-1.6.0-20261101-140158.txt`）

| 时间 | 请求 | 现象 | 说明 |
|---|---|---|---|
| 13:01:44 | session 476 / request 536 | `status=404`，`network_round_trip_ms=162` | **真实网络响应**，但网关没收到 |
| 13:06:28 | session 537 / request 539 | `http_404`，**没有 `REBUILD_HTTP_BEGIN`** | 根本没发 HTTP，直接失败 |
| 13:07:19 | session 542 / request 544 | `http_404`，**没有 `REBUILD_HTTP_BEGIN`** | 同上 |

第二次、第三次 404 与 `REBUILD_REQUEST` 在同一毫秒发生，且没有
`REBUILD_HTTP_BEGIN` / `REBUILD_HTTP_RESPONSE`。这说明失败发生在发送前。

### 1.2 网关侧

同一时间段 `ssh root@192.168.2.97 journalctl -u immersive-translator`：

```
13:01:37 ... POST /a2bxj5/v1/plain/chat/completions 200
13:01:40 ... POST /a2bxj5/v1/plain/chat/completions 200
（13:01:44 没有 404；13:01:40–13:08:36 没有任何 chat 请求）
13:06:29 ... GET /a2bxj5/yt/warm?v=Cv9AkaQDVVM 200
13:07:20 ... GET /a2bxj5/yt/warm?v=LVH8BTJV2Go 200
```

`/yt/warm` 能通，说明公网域名本身和 FRP 隧道当时是通的；只是翻译 POST 的
那一次拿到了 404。`journalctl` 全天只有一条 404，是 `GET /`（控制台根路径），
不是 App 的请求。

### 1.3 为什么一次 404 会“传染”

`translation-core/.../RebuildApi.java` 原来的逻辑：

```java
if (response.status < 200 || response.status >= 300)
    throw new Failure(
        "http_" + response.status,
        response.status == 401 || response.status == 403 || response.status == 404,
        response.retryAfter);
...
if (failure != null && failure.configuration) {
    blocked.put(identity, failure.code);   // identity = baseUrl + model + key
}
...
if (blocked.containsKey(identity))
    throw new Failure(blocked.get(identity), true, 0);  // 不再发网络请求
```

于是：

1. 13:01:44 公网链路瞬时 404 → `blocked[identity] = "http_404"`；
2. 之后同一进程里，无论换哪个视频、开哪个 session，命中同一个 identity；
3. 请求在 `translate()` 入口就直接抛 404，`REBUILD_HTTP_BEGIN` 不会出现；
4. 只有 App 进程重启（或换 API 地址/Key 导致 identity 变化）才恢复——
   这就是“切换几个视频之后又好了”的真相。

---

## 2. 修复内容

补丁源码在 `E:\tmp\ai-caption`，改动已导出到
`patches/endpoint-failover/endpoint-failover.diff`。

### 2.1 404 不再永久拉黑

```java
// 只有 401/403 仍视为需要用户处理的配置问题
response.status == 401 || response.status == 403
```

404/408/502/503/504 现在是可重试的普通失败，不会写入 `blocked`。

### 2.2 请求级自动线路切换

`TranslationSettings` 新增：

- `fallbackBaseUrl` / `fallbackApiKey` / `fallbackModel`
- `onWifi`（当前是否有已验证的 WiFi/Ethernet）

`RebuildApi.sendWithFailover()` 按下面顺序尝试：

| 当前网络 | 首选 | 备选 |
|---|---|---|
| WiFi / Ethernet | 内网地址（私有 IP） | 公网地址 |
| 移动网络 | 公网地址 | 内网地址 |
| 判断不出 | 当前配置的地址 | 另一条 |

失败条件（会在同一次请求里重试备选一次）：

- 连接失败 / 连接超时 / 连接被重置 / DNS 失败（内网候选使用 1.5s 连接超时，公网候选 4s）
- HTTP 404 / 408 / 502 / 503 / 504
- 流式请求尚未收到任何内容时

不会重试：

- 400 / 422（协议/内容问题）
- 401 / 403（认证问题）
- 已经收到流式内容后的读失败（避免重复半截译文）
- 用户取消/切视频

失败的首选线路进入 **60 秒冷却**；60 秒后下一次请求会再试首选线路，
这就是“定期发现内网恢复后切回去”的机制，不需要额外定时器。

### 2.3 备选线路从哪里来

优先级从高到低：

1. 同一 API 配置方案里显式保存的 `fallback_base_url`（预留，当前无 UI）；
2. **另一套 API 配置方案**：如果存在不同 origin 的方案，自动选它
   （优先“另一侧”：内网方案 ↔ 公网方案；名字含
   `remote/public/公网/外网/反代` 或 `lan/local/内网/局域` 会加分）；
3. 没有第二套方案时，使用本部署已知的一对地址：
   `http://172.20.16.249:8787` ↔ `https://airoute.codet.net`
   （保留原路径与 query；迁移窗口内 `192.168.2.97` 也仍被识别为内网侧）。

所以你现在**不需要手动切换配置方案**：当前激活的是
`https://airoute.codet.net/...` 也没关系，WiFi 下会自动优先走
`http://172.20.16.249:8787/...`，移动网络下自动优先走公网。

### 2.4 预热也跟着线路走

原来的 `WarmPing` 已从 smali 注入改为 Java 源码，并调用
`DeepSeekConfig.preferredBaseUrl()`，因此 `/yt/warm` 不会再在移动网络下
去连内网。

---

## 3. 构建与安装

改动的源码需要重新编译成 `extensions/extension.mpe`（dex），再替换进
`.mpp`，最后用 Morphe CLI 重新打包 APK。本次实际使用的命令：

```bash
# 1) 编译扩展（Java 11 + android-33）
javac -encoding UTF-8 -source 11 -target 11 \
  -cp "$ANDROID_HOME/platforms/android-33/android.jar" \
  -d /e/tmp/ext-build/classes @sources.txt

# 2) 转 dex（min-api 28）
java -cp "$ANDROID_HOME/build-tools/33.0.2/lib/d8.jar" \
  com.android.tools.r8.D8 --min-api 28 \
  --output /e/tmp/ext-build/dex $(find /e/tmp/ext-build/classes -name '*.class')

# 3) 替换 mpp 里的 extension.mpe
cp /e/tmp/ext-build/dex/classes.dex unpack/extensions/extension.mpe
(cd unpack && zip -q -r ../patches-failover.mpp .)

# 4) 重新打补丁 APK
java -jar /e/tmp/morphe-desktop.jar patch \
  --patches=/e/tmp/morphe-data/patches/MorpheApp-morphe-patches/v2.0.0__patches-2.0.0.mpp \
  --patches=/e/tmp/mpp-failover/patches-failover.mpp \
  --out /e/tmp/yt-failover-patched.apk \
  /e/tmp/ytsplit/yt-21.43.523.apks

# 5) 安装（保留数据）
adb push /e/tmp/yt-failover-patched.apk /data/local/tmp/yt-failover.apk
adb shell pm install -r -t /data/local/tmp/yt-failover.apk
```

产物：

| 文件 | 说明 |
|---|---|
| `patches/endpoint-failover/patches-failover.mpp` | 已替换 extension 的补丁包（SHA-256 `2248d1ea…`） |
| `/e/tmp/yt-failover-patched.apk` | 已签名 APK（2026-11-01 22:23 重新构建，SHA-256 `4db441b3…`；待手机重新连接后安装） |
| `patches/endpoint-failover/endpoint-failover.diff` | 上游源码改动 |
| `patches/endpoint-failover/tests/` | 线路顺序 / 404→备选 / 双失败回退测试 |

---

## 4. 验证

### 4.1 桌面测试（已通过）

`FailoverHttpTest`：本地两个 HTTP server，主 404、备 200：

```
first  status=200 primary_hits=1 fallback_hits=1
second status=200 primary_hits=1 fallback_hits=2   # 主线路冷却，直接走备选
```

`FailoverBothFailTest`：主 404、备选端口不可达：

```
first  status=404 primary_hits=1
second status=404 primary_hits=2   # 主线路没有被冷却，下一次仍然先试主
```

`FailoverOrderTest`：

```
WiFi + 主内网   → 内网 -> 公网
移动 + 主内网   → 公网 -> 内网
WiFi + 主公网   → 内网 -> 公网
移动 + 主公网   → 公网 -> 内网
```

### 4.2 手机验收（待完成）

安装成功、启动无 FATAL；由于抓取时手机处于锁屏，未完成播放实测。
解锁后按下面点一次即可：

```
YouTube(Morphe) → 播放仅英文轨视频 → CC → 长按 CC → 自动翻译 → 中文(简体)
设置 → Morphe → 视频 → AI 字幕翻译 → 缓存与诊断 → 字幕诊断 → 展开
```

期望：

- `当前模式：AI 翻译`；
- 诊断里不再出现连续的 `http_404`；
- WiFi 下网关日志出现内网请求；移动网络下出现公网请求；
- 如果公网偶发 404，只会影响那一块，下一次请求会自动重试，不会一直坏到重启。

---

## 5. 还可以继续做的

- 给 `fallback_base_url` 加一个设置页输入框（需要重新编译 patch bundle，
  本次为了不破坏现有设置页没做；当前靠“第二套 API 方案 / 已知地址对”自动推导）。
- 把 60 秒冷却做成可配置。
- 对 404 记录响应体（现在只记录 status）以便进一步定位公网反代/FRP 的瞬时 404。
- 如果公网 404 反复出现，建议在 HK 反代/FRP 侧看 `nginx`/`frps` 日志，
  或在 `/yt/warm` 与 `chat/completions` 上加一个轻量健康检查。
