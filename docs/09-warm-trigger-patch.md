# 在补丁里加"自动预热"（不改源码、不需要 GitHub token）

Morphe 的补丁包 `.mpp` 里带了一个 `extensions/extension.mpe`（其实就是 **dex**）。
AI 字幕补丁的所有 Java 扩展代码都在这个 dex 里，包括 `DeepSeekCaptionHook.onVideoId(String)`。
只要改这个 dex，再让 Morphe CLI 重新打一次包，就能在 App 里加功能——**不用重新编译补丁源码**。

## 加的东西

`WarmPing` + `WarmPing$1`（见 `patches/warm-ping/`）：拿到视频 ID 后，在后台线程 GET
`<配置的 API 地址>/yt/warm?v=<id>`。地址由 App 里已配置的 API URL 推导：

```
http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions
  --replace("/v1/plain/chat/completions", "/yt/warm")-->
http://192.168.2.97:8787/a2bxj5/yt/warm?v=dQw4w9WgXcQ
```

所以换服务器/前缀时不用改包，只要在 App 里改 API 地址。

插入点（`DeepSeekCaptionHook.onVideoId`，已有 Context 在 v0）：

```smali
invoke-static {v0, p0}, Lapp/yydarlinker/deepseekcaptions/TokenCostAudit;->onVideoId(Landroid/content/Context;Ljava/lang/String;)V
invoke-static {v0, p0}, Lapp/yydarlinker/deepseekcaptions/WarmPing;->ping(Landroid/content/Context;Ljava/lang/String;)V
```

## 复现步骤

```bash
# 0) 工具：baksmali/smali 2.5.2 + 依赖（guava/jsr305/jcommander/antlr）
#    下载后放在 /e/tmp/smali，classpath 见下

# 1) 从 mpp 里取出扩展 dex
MPP=morphe-data/patches/YYDarlinker-morphe-ai-caption-translator/v1.6.0__patches-1.6.0.mpp
unzip -o "$MPP" extensions/extension.mpe -d /e/tmp/mpe

# 2) 反汇编
java -cp "baksmali.jar;dexlib2.jar;util.jar;guava.jar;jsr305.jar;jcommander.jar" \
     org.jf.baksmali.Main d /e/tmp/mpe/extensions/extension.mpe -o /e/tmp/mpe/smali

# 3) 放入 WarmPing*.smali，并在 DeepSeekCaptionHook.smali 里加一行 invoke-static（见上）

# 4) 汇编回 dex
java -cp "smali.jar;util.jar;dexlib2.jar;guava.jar;jsr305.jar;jcommander.jar;antlr.jar" \
     org.jf.smali.Main a /e/tmp/mpe/smali -o /e/tmp/mpe/extensions/extension_new.mpe

# 5) 替换进 mpp 副本
cp "$MPP" /e/tmp/ai-warm.mpp
cp /e/tmp/mpe/extensions/extension_new.mpe /e/tmp/mpe/extensions/extension.mpe
(cd /e/tmp/mpe && zip -q /e/tmp/ai-warm.mpp extensions/extension.mpe)

# 6) 用改过的 mpp 重新打包 YouTube
java -jar morphe-desktop.jar patch \
  --patches=https://github.com/MorpheApp/morphe-patches \
  --patches=/e/tmp/ai-warm.mpp \
  --out /e/tmp/yt-warm-patched.apk /e/tmp/ytsplit/yt-21.43.523.apks
```

实测：109 个补丁、27.3s、137MB，`classes13.dex` 里能找到 `WarmPing`；
签名与旧包一致（`3c2350a7…`），所以 `adb install -r` 直接覆盖、保留配置。

## 装完后的行为

1. 打开任意视频 → App 在后台打 `/yt/warm?v=<id>`；
2. 网关开始整轨翻译（20 分钟视频约 15s），此期间逐块请求被 `YT_HOLD_WHILE_WARMING`
   拦下返回空事件 → 播放器只显示「翻译中…」；
3. 预热完成 → 逐块请求命中 cue 缓存（~57ms）→ 字幕正常显示。

不需要 adb、不需要伴生 App、不需要 GitHub token。
