#!/usr/bin/env bash
# 仅调试用：把手机的 127.0.0.1:8787 映射到电脑的 8787。
# 生产用法是让手机直接访问 http://192.168.2.97:8787/<PATH_PREFIX>/v1/plain/...
set -euo pipefail

ADB="${ADB:-adb}"
[ $# -ge 1 ] && ADB="$ADB -s $1"

"$ADB" reverse --remove-all
"$ADB" reverse tcp:8787 tcp:8787
"$ADB" reverse --list

echo "手机端验证："
"$ADB" shell 'curl -s -m 5 http://127.0.0.1:8787/v1/models' || true
echo
echo "注意：拔掉 USB 后映射失效，需要重新执行。"
