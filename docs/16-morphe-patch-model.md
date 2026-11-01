# Morphe 补丁是什么模式（2026-11-01）

> 结论：**不是编译整个 YouTube 源码，而是对官方 YouTube APK 做字节码/资源级补丁，
> 重新签名后得到一个独立的 patched APK。**
>
> 类似 ReVanced：输入原版 APK，输出一个包名/签名不同的独立应用；
> 不需要 root，不需要 Xposed，运行时也不依赖官方 YouTube。

## 1. 三个东西的区别

| 名称 | 是什么 | 能否直接安装 |
|---|---|---|
| YouTube 原版 APK / `.apks` | Google 官方安装包（base + split） | 是（原版） |
| Morphe 补丁包 `.mpp` | 补丁定义（Kotlin）+ `extensions/extension.mpe`（Java 扩展 dex） | **否** |
| patched APK | 原版 APK + 注入的补丁代码/资源，重新签名 | 是（独立包名） |

`.mpp` 不是安装包，只是给 Morphe Patcher 用的“补丁说明书 + 扩展代码”。

## 2. 实际流程

以本项目为例：

```text
1. 从手机拉取已安装的官方 YouTube：
   base.apk + split_config.arm64_v8a.apk + split_config.xxxhdpi.apk + split_config.zh.apk
        │
        ▼
2. 打包成 .apks（Morphe CLI 会合并 split）
        │
        ▼
3. Morphe CLI 加载补丁源：
   - 官方 morphe-patches（109 个补丁）
   - AI caption translator.mpp
        │
        ▼
4. Patcher 在**原版 APK 的 dex/资源**里做修改：
   - 按 fingerprint/字符串定位 YouTube 的目标方法；
   - 注入 smali/dex 调用（AI 字幕 hook、设置页、WarmPing 等）；
   - 修改 res/xml 设置页、strings、manifest；
   - GmsCore support 补丁改包名为 app.morphe.android.youtube；
        │
        ▼
5. 重建 APK → zipalign → 用 Morphe keystore 签名
        │
        ▼
6. 得到 app.morphe.android.youtube 21.43.523
```

这里“编译”的只是：

- 补丁定义（Kotlin，打进 `.mpp`）；
- Java 扩展代码（`extensions/extension.mpe`，dex）。

**YouTube 本身没有源码参与编译**；Patcher 是直接改官方 APK 的 dex 和资源。

## 3. 为什么能共存

- 包名被改成 `app.morphe.android.youtube`；
- 签名是 Morphe keystore，和官方 Google 签名不同；
- 所以可以和：
  - 官方 `com.google.android.youtube`
  - RVX `app.rvx.android.youtube`
  同时安装。

它不是“运行时绑定官方 YouTube”，而是**复制了一份官方代码，在副本里注入补丁**。
原版 YouTube 完全不受影响。

## 4. 需不需要 root / Xposed

不需要。

- 不 root；
- 不装 Xposed/LSPosed；
- 不需要 MITM 证书；
- 但需要 **MicroG-RE**（`app.revanced.android.gms`）来提供 Google 登录/服务，
  因为 patched 包签名变了，不能直接用官方 GMS。

## 5. 版本绑定

补丁通过 fingerprint 定位方法，所以**强绑定 YouTube 版本**：

- AI caption translator 1.6.0 声明支持 21.42.241 / 21.41.525 / 21.30.216 等；
- 21.43.523 是实验目标，构建时可能需要 `--force`；
- YouTube 升级后 fingerprint 可能失效，需要补丁作者更新。

这不是“编译一次就通用”，而是“针对某个 APK 版本打补丁”。

## 6. 本项目的实际构建

```bash
# 1) 拉官方分卷 → .apks
# 2) 用官方补丁 + AI 补丁打包
java -jar morphe-desktop.jar patch \
  --patches=/path/to/MorpheApp-morphe-patches/v2.0.0__patches-2.0.0.mpp \
  --patches=/path/to/patches-failover.mpp \
  --out /e/tmp/yt-failover-patched.apk \
  /e/tmp/ytsplit/yt-21.43.523.apks
```

我们改 App 的线路切换时：

- 只重新编译了 Java 扩展（`extension.mpe`）；
- 替换 `.mpp` 里的 extension dex；
- 用 Morphe CLI 重新对**原版 APK** 打补丁；
- 没有重新编译 YouTube。

## 7. 一句话总结

**Morphe = APK 级二进制补丁器。**  
输入官方 YouTube APK，输出一个注入了补丁代码/资源、改了包名并重新签名的独立 APK；
不编译 YouTube 源码，不 root，不依赖 Xposed，运行时也不绑定官方 App。
