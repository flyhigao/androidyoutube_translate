#!/usr/bin/env python3
"""
监听手机/电视的媒体会话，自动把当前视频的整条字幕预热到网关（B 路线 A 方案）。

用法:
    python scripts/watch-and-warm.py c784f5f4
    python scripts/watch-and-warm.py 192.168.2.223:5555 --gateway http://192.168.2.97:8787/a2bxj5

原理: `adb shell dumpsys media_session` 里有 YouTube 的标题，
      交给网关 /yt/resolve 用 yt-dlp 搜索视频 ID → 后台 /yt/warm。
      预热完成后，App 的逐块请求会直接命中 cue 缓存（~50ms）。
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


def media_title(adb: str, serial: str) -> str:
    try:
        out = subprocess.run(
            [adb, "-s", serial, "shell", "dumpsys media_session"],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return ""
    for line in out.splitlines():
        m = META_RE.search(line.strip())
        if m:
            return m.group(1).strip()
    return ""


def call(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("serial", help="adb serial，如 c784f5f4 或 192.168.2.223:5555")
    ap.add_argument("--adb", default="adb")
    ap.add_argument("--gateway", default="http://192.168.2.97:8787/a2bxj5")
    ap.add_argument("--interval", type=float, default=3.0)
    args = ap.parse_args()

    last = ""
    failed = set()
    print(f"watching {args.serial} → {args.gateway}", flush=True)
    while True:
        title = media_title(args.adb, args.serial)
        if title and title != last and title not in SKIP_TITLES and title not in failed:
            q = urllib.parse.urlencode({"title": title})
            try:
                res = call(f"{args.gateway}/yt/resolve?{q}")
                last = title
                print(f"[warm] {res.get('id')} ← {title[:60]}", flush=True)
            except Exception as e:
                failed.add(title)
                print(f"[skip] {title[:60]} ({e})", flush=True)
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
