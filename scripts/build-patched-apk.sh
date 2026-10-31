#!/usr/bin/env bash
# 构建并安装「A 路线」补丁版 YouTube（Morphe + AI caption translator）
#
# 用法:
#   bash scripts/build-patched-apk.sh <adb-serial>            # 构建 + 安装
#   SKIP_INSTALL=1 bash scripts/build-patched-apk.sh <serial>  # 只构建
#
# 依赖: adb、JDK 21+（默认取 Android Studio 自带 JBR）、约 1.5GB 磁盘
set -euo pipefail

SERIAL="${1:?用法: $0 <adb-serial>（adb devices 查看）}"
ADB="${ADB:-adb} -s $SERIAL"
JAVA="${JAVA:-/e/Program Files/Android/Android Studio/jbr/bin/java.exe}"
WORK="${WORK:-/e/tmp/ytbuild}"
PKG="com.google.android.youtube"
OUT_APK="${OUT_APK:-$WORK/yt-patched.apk}"
JAR="${MORPHE_JAR:-/e/tmp/morphe-desktop.jar}"
OFFICIAL="${OFFICIAL_PATCHES:-https://github.com/MorpheApp/morphe-patches}"
AI="${AI_PATCHES:-https://github.com/YYDarlinker/morphe-ai-caption-translator}"

[ -x "$JAVA" ] || JAVA="java"
[ -f "$JAR" ] || { echo "缺少 Morphe CLI: $JAR（从 MorpheApp/morphe-desktop releases 下载 *-all.jar）"; exit 1; }

mkdir -p "$WORK/splits"
cd "$WORK/splits"

echo "== 1/4 拉取已安装的官方 YouTube 分卷 =="
rm -f ./*.apk
for p in $($ADB shell pm path "$PKG" | sed 's/package://' | tr -d '\r'); do
    "$ADB" pull "$p" . >/dev/null
done
ls -1sh ./*.apk

echo "== 2/4 打包为 .apks（Morphe 会自动合并分卷） =="
BUNDLE="$WORK/yt-bundle.apks"
rm -f "$BUNDLE"
zip -q -0 "$BUNDLE" ./*.apk

echo "== 3/4 打补丁（官方默认组合 + AI caption translator） =="
rm -f "$OUT_APK"
"$JAVA" -jar "$JAR" patch \
    --patches="$OFFICIAL" \
    --patches="$AI" \
    --out "$OUT_APK" \
    "$BUNDLE"

echo "== 4/4 安装 =="
if [ "${SKIP_INSTALL:-0}" = "1" ]; then
    echo "跳过安装。产物: $OUT_APK"
    exit 0
fi
TMP_APK="/data/local/tmp/yt-patched.apk"
MSYS_NO_PATHCONV=1 "$ADB" push "$OUT_APK" "$TMP_APK" >/dev/null
MSYS_NO_PATHCONV=1 "$ADB" shell "pm install -r -t $TMP_APK"
MSYS_NO_PATHCONV=1 "$ADB" shell "rm -f $TMP_APK"

echo
echo "完成。包名: app.morphe.android.youtube（与官方 YouTube / RVX 共存）"
echo "下一步：App → 设置 → Morphe → 视频 → AI 字幕翻译，填："
echo "  API 地址: http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions"
echo "  API Key : 任意非空字符串"
echo "  模型    : hy7b"
