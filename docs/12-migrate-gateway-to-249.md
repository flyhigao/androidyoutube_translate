# 翻译平台迁移到 172.20.16.249（2026-11-01）

## 0. 先回答：HY 7B 的地址是什么

不是 `aiapi` 域名，是**具体 IP**：

```
UPSTREAM_BASE_URL=http://172.20.16.90:8012/v1
DEFAULT_MODEL=hy7b
```

上游 `/v1/models` 返回：

```json
{"data":[{"id":"hy1.8b","aliases":["hy1.8b","hy7b"],
  "meta":{"n_params":7504568320,"n_embd":4096}}]}
```

即 `hy7b` 是 `hy1.8b` 的别名，实际参数量 7.5B（llama.cpp / GPUStack 的模型名显示为 `hy1.8b`）。
网关的 `DEFAULT_MODEL=hy7b` 会覆盖客户端传来的模型字段。

## 1. 部署结果

| 项 | 值 |
|---|---|
| 新主机 | `172.20.16.249`（LXC，Ubuntu 22.04.5，Python 3.10.12） |
| 代码目录 | `/opt/immersive-translator-gateway` |
| 服务 | `systemd: immersive-translator.service`，root，`0.0.0.0:8787` |
| 虚拟环境 | `/opt/immersive-translator-gateway/.venv` |
| 上游 | `http://172.20.16.90:8012/v1` |
| 路径前缀 | `a2bxj5`（与旧机一致，客户端不用改路径） |
| 数据 | `terms.db` / `subs.db` / `yt-cookies.txt` 已从 2.97 复制 |
| 旧机 | `192.168.2.97` 仍保留运行，作为迁移窗口回退 |

### 已执行的部署命令（摘要）

```bash
# 1) 从 2.97 复制代码与数据（排除 .venv 和两个大日志）
ssh root@192.168.2.97 'tar -C /opt -czf - \
  --exclude=immersive-translator-gateway/.venv \
  --exclude=immersive-translator-gateway/data/gateway_live.log \
  --exclude=immersive-translator-gateway/data/yt_debug.log \
  immersive-translator-gateway' \
| ssh root@172.20.16.249 'tar -C /opt -xzf -'

# 2) 新建 venv 并安装依赖（与 2.97 同版本）
ssh root@172.20.16.249 'cd /opt/immersive-translator-gateway &&
  python3 -m venv .venv &&
  .venv/bin/pip install -r requirements.txt &&
  .venv/bin/pip install "yt-dlp==2026.10.21" "curl_cffi==0.11.0"'

# 3) .env：注释掉旧机的 SSH 隧道代理
#    YT_PROXY=socks5h://127.0.0.1:11070  →  16.249 上没有这个隧道
ssh root@172.20.16.249 'cd /opt/immersive-translator-gateway &&
  sed -i "s|^YT_PROXY=.*|# YT_PROXY moved with the old SSH tunnel; not configured on 16.249|" .env'

# 4) systemd
ssh root@172.20.16.249 'cat > /etc/systemd/system/immersive-translator.service <<UNIT
[Unit]
Description=Immersive Translator Context & Term Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/immersive-translator-gateway
EnvironmentFile=/opt/immersive-translator-gateway/.env
ExecStart=/opt/immersive-translator-gateway/.venv/bin/python3 -m uvicorn gateway.server:app --host 0.0.0.0 --port 8787
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now immersive-translator'
```

## 2. 验证

在 249 上：

```bash
curl -s http://127.0.0.1:8787/a2bxj5/v1/models
curl -s http://127.0.0.1:8787/a2bxj5/v1/plain/models
```

均返回 `hy7b` / `hy1.8b`。

真实 shim 翻译请求（`/v1/plain/chat/completions`，带 `source_text`）：

```json
{"model":"hy7b","stream":false,"messages":[
 {"role":"system","content":"translate"},
 {"role":"user","content":"{\"block\":\"b0\",\"source_text\":\"This is a test of the subtitle translation gateway.\",\"language\":\"zh-Hans\"}"}]}
```

结果：

```text
HTTP=200 time=0.284s
{"events":[{"source":"This is a test of the subtitle translation gateway.",
            "text":"这是对字幕翻译网关的测试。"}]}
```

从 192.168.2.x 网段（电视盒子）访问：

```text
ping 172.20.16.249        → 6.5 ms
GET  /a2bxj5/v1/models     → 200
```

说明 192.168.2.0/24 → 172.20.16.0/24 的路由已通，手机 WiFi 也应能直接访问。

上游往返：

```text
172.20.16.249 → 172.20.16.90:8012   /v1/models  200，约 1 ms
```

## 3. 反代切换（已于 2026-11-01 22:33 完成）

切换前公网链路：

```
airoute.codet.net → hk.codet.net (frps) → 192.168.2.97:8787
```

切换后：

```
airoute.codet.net → hk.codet.net (frps) → 172.20.16.249:8787
```

### 实际执行记录（2026-11-01 22:33）

| 时间 | 动作 | 结果 |
|---|---|---|
| 22:33:09 | 2.97 备份 `frpc.toml`，删除 `airoute` proxy 块 | `frpc verify` 通过 |
| 22:33:35 | 2.97 `systemctl restart frpc` | `learn_aze_home` / `CPA` / `daka_api` / `espdashboard_api` / `tv_api` 全部 `start proxy success`，无 `airoute` |
| 22:33:4x | 2.97 `systemctl stop immersive-translator && systemctl disable immersive-translator` | `inactive` / `disabled`，8787 已关闭 |
| 22:33:50 | 249 备份 `frpc.toml`，追加 `airoute` proxy | `frpc verify` 通过 |
| 22:33:50 | 249 `systemctl restart frpc` | `airoute` / `openai-api` / `openai-api-trans` 全部 `start proxy success` |
| 22:34:06 | 公网 `GET /a2bxj5/v1/models` | 200，约 0.29s |
| 22:34:07 | 公网 `POST /a2bxj5/v1/plain/chat/completions` | 200，约 0.71s，真实译文返回 |
| 22:39:01 | 手机关 WiFi（5G），App「测试 API」 | 249 日志出现 `127.0.0.1:0`（frpc 公网入口）200 |
| 22:39:23 | 手机开 WiFi，App「测试 API」 | 249 日志出现 `172.20.16.246`（192.168.2.204 的 NAT 出口）200 |
| 22:40:30 | 播放中关 WiFi | 先出现 `翻译中…`，约 1 分钟后 249 日志出现 `127.0.0.1:0` 公网请求，字幕恢复中文 |
| 22:42:50 | 重新开 WiFi | 249 日志回到 `172.20.16.246` 内网请求，自动切回 LAN |

> `172.20.16.246` 是 192.168.2.0/24 到 172.20.16.0/24 的 NAT 出口，
> 所以手机 WiFi 请求在 249 上显示为这个地址；`127.0.0.1:0` 是 frpc 转发。


反代移到 249 后，应改为：

```
airoute.codet.net → hk.codet.net (frps) → 172.20.16.249:8787
```

在 249 上把 `frpc.toml` 里的 `airoute` proxy 改成：

```toml
[[proxies]]
name = "airoute"
type = "http"
localIP = "127.0.0.1"
localPort = 8787
customDomains = ["airoute.codet.net"]
transport.useCompression = true
```

切换前建议先停 2.97 的网关，再同步一次运行数据（避免 SQLite 在写入中被复制）：

```bash
ssh root@192.168.2.97 'systemctl stop immersive-translator &&   tar -C /opt/immersive-translator-gateway -czf - data/terms.db data/subs.db data/yt-cookies.txt' | ssh root@172.20.16.249 'tar -C /opt/immersive-translator-gateway -xzf - && systemctl restart immersive-translator'
```

如果切换后需要回滚，再在 2.97 上 `systemctl start immersive-translator`。

然后：

```bash
systemctl restart frpc
# 验证
curl -s https://airoute.codet.net/a2bxj5/v1/models
```

注意：

- 249 上已经有 `/opt/frp_0.70.1_linux_amd64`，但当前是否有 `frpc.service` 需要确认；
  不要在 249 和 2.97 同时注册同一个 `customDomains`，frps 会冲突。
- 切换顺序建议：先在 249 上启动 frpc 并确认注册成功 → 停 2.97 的 frpc/airoute proxy →
  公网验证 → 再停 2.97 的 `immersive-translator`。
- 旧机 2.97 保留 `immersive-translator.service` 但可以先停 `frpc` 中的 `airoute`，
  便于回滚。

## 4. App 侧地址配对

AI 字幕补丁的自动线路切换已把已知地址对改为：

```
内网侧：http://172.20.16.249:8787
公网侧：https://airoute.codet.net
```

迁移窗口内 `http://192.168.2.97:8787` 仍被识别为内网侧，所以旧机不会立刻失效。
新 APK 已重新构建：

```
/e/tmp/yt-failover-patched.apk
SHA-256 4db441b338223ab75c1e6d6c4575a479ad070fd3a60bdb4ca8b268b884166080
```

手机已重新连接并安装（2026-11-01 22:34，`lastUpdateTime=22:34:29`，数据保留）。
App 内已把「API 地址」改为局域网地址：

```
http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions
```

Key 重新填为 `sk-local`（改地址后旧 Key 因 origin 绑定会失效，这是设计行为）。

实测：

- WiFi（192.168.2.204）→ 249 日志来源 `172.20.16.246`（NAT）→ LAN 方案 200；
- 5G（WiFi 关闭）→ 249 日志来源 `127.0.0.1:0`（frpc）→ 公网方案 200；
- 播放中关 WiFi：先显示「翻译中…」，随后自动切公网，字幕恢复中文；
- 重新开 WiFi：自动切回 LAN，249 日志来源恢复为 `172.20.16.246`。

如果以后要重新安装：

```bash
adb push /e/tmp/yt-failover-patched.apk /data/local/tmp/yt-failover.apk
adb shell pm install -r -t /data/local/tmp/yt-failover.apk
```

## 5. 回滚

- 反代回滚：在 2.97 上恢复 `frpc` 的 `airoute` proxy，重启 `frpc`；在 249 上停 `frpc`。
- App 回滚：重新安装旧 APK 即可；数据保留。
- 网关回滚：2.97 的 `/opt/immersive-translator-gateway` 和 `immersive-translator.service` 未删除。
