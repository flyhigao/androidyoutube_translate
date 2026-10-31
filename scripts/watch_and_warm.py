#!/usr/bin/env python3
"""
监听设备媒体会话，自动把当前视频的整条字幕预热到网关。

部署位置: /opt/immersive-translator-gateway/scripts/watch_and_warm.py（2.97）
用法:
    python3 watch_and_warm.py 192.168.2.204:5555 --gateway http://127.0.0.1:8787/a2bxj5
    python3 watch_and_warm.py 192.168.2.223:5555 --gateway http://127.0.0.1:8787/a2bxj5

原理: dumpsys media_session 里的 YouTube 标题 → 网关 /yt/resolve（yt-dlp 搜索视频 ID）
      → 后台整轨翻译 → 逐块请求命中 cue 缓存（~50ms）。
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

META_RE = re.compile(r"metadata: size=\d+, description=(.+), (.+), (.+)$")
SKIP_TITLES = {"", "null"}


def adb(adb_bin: str, serial: str, *args: str, timeout: int = 15) -> str:
    try:
        return subprocess.run(
            [adb_bin, "-s", serial, *args], capture_output=True, text=True, timeout=timeout
        ).stdout
    except Exception:
        return ""


def ensure_connected(adb_bin: str, serial: str) -> None:
    if ":" in serial:
        state = adb(adb_bin, serial, "get-state").strip()
        if state != "device":
            subprocess.run([adb_bin, "connect", serial], capture_output=True, timeout=20)


def media_title(adb_bin: str, serial: str) -> str:
    out = adb(adb_bin, serial, "shell", "dumpsys media_session")
    for line in out.splitlines():
        m = META_RE.search(line.strip())
        if m:
            return m.group(1).strip()
    return ""


def call(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=180) as r:
        return json.loads(r.read().decode("utf-8"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("serial", help="adb serial，如 192.168.2.204:5555")
    ap.add_argument("--adb", default="adb")
    ap.add_argument("--gateway", default="http://127.0.0.1:8787/a2bxj5")
    ap.add_argument("--interval", type=float, default=3.0)
    args = ap.parse_args()

    ensure_connected(args.adb, args.serial)
    last, failed = "", set()
    print(f"[watch] {args.serial} → {args.gateway}", flush=True)

    while True:
        ensure_connected(args.adb, args.serial)
        title = media_title(args.adb, args.serial)
        if title and title != last and title not in SKIP_TITLES and title not in failed:
            q = urllib.parse.urlencode({"title": title})
            try:
                res = call(f"{args.gateway}/yt/resolve?{q}")
                last = title
                print(f"[warm] {res.get('id')} ← {title[:70]}", flush=True)
            except Exception as e:
                failed.add(title)
                print(f"[skip] {title[:70]} ({e})", flush=True)
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
