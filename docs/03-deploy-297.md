> 2026-11-01 注：网关已迁移到 `172.20.16.249:/opt/immersive-translator-gateway`，
> 本文保留为 2.97 旧机部署与回滚记录。迁移步骤见 `docs/12-migrate-gateway-to-249.md`。

# 部署到 2.97（LXD Ubuntu 22.04）

## 现状

| 项 | 值 |
|---|---|
| 主机 | QNAP 上的 LXD 容器 `lxd-ubu2204`，x86_64，4 核，19G 内存 |
| 路径 | `/opt/immersive-translator-gateway`（属主 ubuntu） |
| 服务 | `systemd: immersive-translator.service`，root 运行，`--host 0.0.0.0 --port 8787` |
| 环境 | `.env`：`PATH_PREFIX=a2bxj5`、`UPSTREAM_BASE_URL=http://172.20.16.90:8012/v1`、`DEFAULT_MODEL=hy7b` |
| 旧版本 | 与本地 `0b794b0` 的 `gateway/server.py` **逐字节一致**（diff 为空） |

## 本次部署（已执行）

```bash
# 备份 → 覆盖 → 重启 → 校验
ssh root@192.168.2.97 'cp -a /opt/immersive-translator-gateway/gateway/server.py \
    /opt/immersive-translator-gateway/gateway/server.py.bak-$(date +%Y%m%d-%H%M%S)'
scp gateway/server.py root@192.168.2.97:/opt/immersive-translator-gateway/gateway/server.py
scp run.sh           root@192.168.2.97:/opt/immersive-translator-gateway/run.sh
ssh root@192.168.2.97 'systemctl restart immersive-translator'
```

验证结果：

```
GET  /a2bxj5/v1/models                          → 200  (hy7b, hy1.8b)
POST /a2bxj5/v1/plain/chat/completions (真实模型) → 200  0.9s
     {"choices":[{"message":{"content":"{\"t\":\"他们在禁区内将他包夹，他便将球踢向角球区。\"}"}}]}
```

即：**直通模式生效（无注入、按 response_format 返回 JSON）、上游链路可用、往返 0.9s**。

## 回滚

```bash
ssh root@192.168.2.97 'ls -1 /opt/immersive-translator-gateway/gateway/server.py.bak-*'
ssh root@192.168.2.97 'cp -a /opt/immersive-translator-gateway/gateway/server.py.bak-<时间戳> \
    /opt/immersive-translator-gateway/gateway/server.py && systemctl restart immersive-translator'
```

## 后续建议

- 网关**没有入站鉴权**，`0.0.0.0:8787` 对局域网完全开放。至少：
  - 只允许内网网段（nftables/firewalld），或
  - 校验 `Authorization`，非空才放行，并把 key 填进手机端配置。
- `PATH_PREFIX` 只是「猜不到的路径」，不是鉴权。
- 如果要在 2.97 上做整轨道字幕预翻译，建议单独加一层缓存表（`video_id + lang + prompt_version`），
  避免和现有的逐句缓存混在一起。
