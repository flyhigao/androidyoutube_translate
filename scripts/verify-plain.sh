#!/usr/bin/env bash
# 验证网关的 plain 直通模式（不触碰生产服务/生产配置）
# 用法: bash scripts/verify-plain.sh [immersive-context-booster 路径]
set -euo pipefail

REPO="${1:-/e/Projects/agent/immersive-context-booster}"
GW_PORT=8792
UP_PORT=8897
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

PY="$REPO/.venv/Scripts/python.exe"
[ -x "$PY" ] || PY="$REPO/.venv/bin/python3"

cat > "$TMP/fake_upstream.py" <<'PYEOF'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        p = json.loads(self.rfile.read(n) or b"{}")
        sysmsg = "\n".join(m.get("content", "") for m in p.get("messages", []) if m.get("role") == "system")
        if p.get("response_format") and p.get("fail_json"):
            body = json.dumps({"error": {"message": "response_format json_schema is not supported",
                                         "type": "invalid_request_error"}}).encode()
            self.send_response(400)
        else:
            out = {"id": "c", "object": "chat.completion", "model": "fake",
                   "choices": [{"index": 0, "message": {"role": "assistant", "content": json.dumps(
                       {"injected": "【专业术语映射表" in sysmsg or "【重要翻译规则" in sysmsg,
                        "sys_len": len(sysmsg)})}, "finish_reason": "stop"}]}
            body = json.dumps(out).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

cd "$REPO"
PYTHONIOENCODING=utf-8 "$PY" "$TMP/fake_upstream.py" "$UP_PORT" &
sleep 1
PYTHONIOENCODING=utf-8 UPSTREAM_BASE_URL="http://127.0.0.1:$UP_PORT/v1" UPSTREAM_API_KEY=x \
  PORT=$GW_PORT HOST=127.0.0.1 "$PY" -m uvicorn gateway.server:app \
  --host 127.0.0.1 --port $GW_PORT > "$TMP/gw.log" 2>&1 &
sleep 5

BASE="http://127.0.0.1:$GW_PORT"
post() { curl -s -o "$TMP/out.json" -w '%{http_code}' -X POST "$BASE$1" \
         -H 'Content-Type: application/json' -d "$2"; }

code=$(post /v1/chat/completions '{"messages":[{"role":"user","content":"clutch shot"}]}')
grep -qF 'injected\": true' "$TMP/out.json" && echo "PASS 1 普通模式仍注入语境/术语（$code）" \
  || { echo "FAIL 1 普通模式未注入"; exit 1; }

code=$(post /v1/chat/completions '{"messages":[{"role":"user","content":"clutch shot"}],"response_format":{"type":"json_object"}}')
grep -qF 'injected\": false' "$TMP/out.json" && echo "PASS 2 带 response_format 自动直通（$code）" \
  || { echo "FAIL 2 response_format 未直通"; exit 1; }

code=$(post /v1/plain/chat/completions '{"messages":[{"role":"user","content":"clutch shot"}]}')
grep -qF 'injected\": false' "$TMP/out.json" && echo "PASS 3 /v1/plain 显式直通（$code）" \
  || { echo "FAIL 3 plain 路由未生效"; exit 1; }

code=$(post /v1/plain/chat/completions '{"messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_schema"},"fail_json":true}')
[ "$code" = "400" ] && grep -q 'response_format' "$TMP/out.json" \
  && echo "PASS 4 上游 400 原样透传（$code）" \
  || { echo "FAIL 4 上游错误被包成 $code"; exit 1; }

echo "全部通过"
