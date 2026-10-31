# 路由层重定向 YouTube 字幕请求：可行性分析

> 你的想法：在 OpenWrt 上把「网络里原本发往 YouTube 的字幕请求」重定向到 2.97 的自定义翻译服务。
> 结论先说：**透明重定向本身在 OpenWrt 上很好做，但卡在 TLS 解密这一关；对未 root 的手机不可行。**
> 不过这个想法的"内核"（一次翻译整条字幕轨、带真实语境）是更优架构，值得换个位置实现。

## 1. 现状（实测）

| 项 | 值 |
|---|---|
| 路由器 | ImmortalWrt 24.10.6，qualcommax/ipq807x（aarch64_cortex-a53），414MB RAM，overlay 剩 94MB |
| 已有能力 | `dnsmasq-full`、`nftables`、`kmod-nft-tproxy`、`passwall`（xray-core + sing-box） |
| 2.97 出网 | 直连 YouTube 可用：`https://www.youtube.com/` 200（1.1s）、`/api/timedtext` 200（0.6s） |

也就是说：**重定向的技术底座（nftables DNAT/TPROXY + 已有透明代理）是齐的**，缺的不是网络能力。

## 2. 硬阻塞：TLS 与证书信任

YouTube App 的字幕请求是：

```
https://www.youtube.com/api/timedtext?v=<id>&...&tlang=zh-Hans&fmt=json3
```

要把它"改道"到 2.97，必须做 TLS 中间人（MITM）：自己签一张 `www.youtube.com` 的证书。
而 Android 侧的信任链是：

- Android 7+ 起，App **默认只信任系统 CA**，用户安装的 CA 不生效；
- 我 dump 了你这台手机官方 YouTube 的 `network_security_config`：

```xml
<base-config cleartextTrafficPermitted="true">
  <trust-anchors>
    <certificates src="system" />   <!-- 只有 system，没有 user -->
  </trust-anchors>
  <certificateTransparency enabled="true" />
</base-config>
```

所以：**手机端不装系统级 CA，MITM 一定失败**（`SSLHandshakeException`）。
装系统级 CA 需要 root（Magisk 模块 / 挂载 `/system`），你这台 PJZ110 目前没有 root。
而且该 App 还开了 `certificateTransparency`，即使系统 CA 到位，也存在被 CT/pinning 拦下的风险。

## 3. 想做成，需要哪些前置条件

| 前置 | 说明 | 成本 |
|---|---|---|
| root（Magisk/KernelSU） | 把自签 CA 放进系统证书库 | 一加国行需深度测试解锁，风险高、可能失去保修/OTA |
| 或改 App 的 NSC | 让 App 信任 user CA —— 但这已经是"改 App"，不如直接用 Morphe 补丁 | 与方案 A 同级 |
| 或 LSPatch 注入 | 非 root 改 App，脆弱、签名变化 | 中 |

换句话说：**如果已经要改 App，就没必要再绕一圈 MITM。**
MITM 只在"完全不能改 App"且"设备已 root"时才划算（例如某些 Android TV 盒子）。

## 4. 如果真要做，正确的落法

路由器只做"改道"，解密与翻译放在 2.97（路由器 overlay 只剩 94MB，跑不了 mitmproxy）：

```bash
# 参考示意，不要直接执行；只对单台设备生效，避免污染全网
nft add table inet ytredir
nft 'add chain inet ytredir prerouting { type nat hook prerouting priority -100; }'
nft add rule inet ytredir prerouting ip saddr 192.168.2.50 tcp dport 443 \
    dnat to 192.168.2.97:8443
```

2.97 上跑 mitmproxy/自研 TLS 终结代理 → 识别 `Host: www.youtube.com` + `Path: /api/timedtext`
→ 转发上游取原字幕 → 调网关翻译 → 返回改写后的 json3/xml。

注意点：

- 你已有 passwall 透明代理（7241 行 nft 规则），**新规则必须精确 match 目标 IP/端口**，
  否则会把代理流量也劫持，导致整网断网；
- YouTube 大量走 QUIC（UDP/443），要同时 `reject udp dport 443` 才能强制回落到 TLS over TCP；
- `timedtext` 现在常带 `pot`（proof-of-origin）等参数，代理必须原样透传参数与 Cookie；
- MITM 一旦生效，**该设备的全部 HTTPS 对你可见**（隐私/安全风险），必须限设备、限域名。

## 5. 更值得做的替代：整轨道翻译（不用 MITM）

把"改道"从**网络层**挪到**应用层的一行 URL**，收益更大：

1. 2.97 提供 `GET /yt/timedtext?v=<id>&lang=<src>&tlang=zh-Hans`：
   - 用 video id 拉整条字幕轨（2.97 直连 YouTube，实测 0.6s）；
   - 一次性批量翻译整条轨道（一次几十句、自带全片语境与术语），按 `video_id+lang` 缓存；
   - 返回标准 `json3`，时间轴原样保留。
2. 补丁里把字幕基址从 `https://www.youtube.com/api/timedtext` 改到
   `http://192.168.2.97:8787/<prefix>/yt/timedtext`（Morphe 补丁做字符串/smali 替换）。
3. 效果：
   - 起播时等 2~5 秒，之后**逐句零延迟**、拖动进度条也即时；
   - 每视频只花一次 LLM 成本（而不是每句一次）；
   - **天然带语境**（知道 video id / 标题），正好补上手机端丢掉的那部分能力。

工作量：中高（要写 json3 解析 + 批量翻译 + 缓存 + 一个 smali 补丁），但比 MITM 干净得多，
也不需要 root、不影响网络里其他设备。

## 6. 方案对比

| 方案 | 改 App | 需 root | 覆盖设备 | 字幕延迟 | 状态 |
|---|---|---|---|---|---|
| A. 逐句翻译（Morphe + `/v1/plain`） | 是 | 否 | 单机 | 每句 0.5~1s | **已就绪** |
| B. 整轨道代理 + URL 改写 | 是（更小） | 否 | 单机 | 起播一次，之后 0 | 待做 |
| C. 路由 MITM 重定向 | 否 | **是** | 全网 | 每句 | 手机不可行 |
| D. PolyglotYT（Xposed） | 是（模块） | 是 | 单机 | 每句 | 可选 |

## 7. 建议

1. **先按 A 跑通**（今天就能验收），确认 21.43.523 打补丁后的实际体验；
2. 如果逐句延迟不能接受 → 做 **B（整轨道）**，这是"你那个想法"的正确形态；
3. 路由层只在两种情况下再考虑：
   - 你以后 root 了手机/电视盒子；
   - 或者你有一台可以装系统 CA 的 Android TV，想让"全网设备"都吃上翻译。
4. 无论哪条路，都建议先把网关的**入站鉴权**补上（现在局域网内任何人可直接用）。
