#!/usr/bin/env bash
# 让 2.97 上的 yt-dlp 走路由器 PassWall 的 SOCKS（解决字幕 429 / 出口问题）
# 用法：bash setup-yt-proxy.sh
set -euo pipefail

ROUTER="${ROUTER:-192.168.2.1}"
HOST="${HOST:-192.168.2.97}"
GW="/opt/immersive-translator-gateway"
LOCAL_PORT="${LOCAL_PORT:-11070}"
ROUTER_SOCKS_PORT="${ROUTER_SOCKS_PORT:-1070}"

echo "== 1. 路由器侧确认 SOCKS 入口 =="
ssh "root@$ROUTER" "netstat -lntp 2>/dev/null | grep ':$ROUTER_SOCKS_PORT ' || true; \
  uci get passwall.myshunt.default_node; \
  curl -sS --socks5-hostname 127.0.0.1:$ROUTER_SOCKS_PORT -m 10 https://api.ipify.org; echo"

echo "== 2. 2.97 上装 SSH 隧道服务 =="
ssh "root@$HOST" "cat > /etc/systemd/system/router-passwall-socks.service <<'UNIT'
[Unit]
Description=SSH tunnel to OpenWrt PassWall SOCKS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -N -L 127.0.0.1:$LOCAL_PORT:127.0.0.1:$ROUTER_SOCKS_PORT root@$ROUTER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now router-passwall-socks
sleep 3
systemctl is-active router-passwall-socks
ss -ltn | grep $LOCAL_PORT || true"

echo "== 3. 网关写 YT_PROXY 并重启 =="
ssh "root@$HOST" "grep -q '^YT_PROXY=' $GW/.env \
    && sed -i 's#^YT_PROXY=.*#YT_PROXY=socks5h://127.0.0.1:$LOCAL_PORT#' $GW/.env \
    || echo 'YT_PROXY=socks5h://127.0.0.1:$LOCAL_PORT' >> $GW/.env
  systemctl restart immersive-translator
  sleep 4
  systemctl is-active immersive-translator
  grep -E '^YT_' $GW/.env"

echo "== 4. 端到端验证 =="
ssh "root@$HOST" "curl -s 'http://127.0.0.1:8787/a2bxj5/yt/warm?v=GHIIuBfP3t8' >/dev/null
  for i in \$(seq 1 20); do sleep 5; \
    st=\$(curl -s 'http://127.0.0.1:8787/a2bxj5/yt/status?v=GHIIuBfP3t8'); echo \"\$i \$st\"; \
    case \"\$st\" in *'\"state\":\"done\"'*|*'\"state\":\"error\"'*) break;; esac; done"
