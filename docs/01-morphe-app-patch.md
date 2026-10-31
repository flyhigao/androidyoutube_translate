# 手机端：Morphe + AI caption translator

## 前提事实（2026-10 实测，OnePlus PJZ110 / Android 17 / SDK 37 / arm64-v8a）

| 项 | 值 |
|---|---|
| 官方 YouTube | `com.google.android.youtube` 21.43.523，versionCode `1561307650` |
| RVX | `app.rvx.android.youtube` 20.05.46（**独立包名，可共存**） |
| root | 无 |
| YouTube NSC | `base-config cleartextTrafficPermitted=true`，仅 youtube.com / googleapis.com 关闭 → `http://` 到内网可用 |
| 补丁目标版本 | `21.43.523` 是 `AI caption translator` 的实验目标（`Constants.kt`），`21.30.216` 是常规目标 |

补丁只作用于 `com.google.android.youtube`，与 RVX 无关；两者签名/包名都不同，不需要卸载 RVX。

## 步骤

1. 装 [Morphe Manager](https://github.com/MorpheApp/morphe-manager/releases/latest)，设置 → 开「专家模式」。
2. 补丁源 → 添加远程：`https://github.com/YYDarlinker/morphe-ai-caption-translator`。
3. 选 YouTube → 输入源：
   - 优先「从已安装应用获取」（Manager 会合并 split；补丁声明 `ApkFileType.APK_REQUIRED`，必须整包）；
   - 或下载 21.43.523 的 `.apkm` 交给 Manager 自动转 APK。
4. 补丁选择：**保留官方默认组合**（Captions / 设置 / GmsCore 支持等），
   只额外确认勾选 `AI caption translator`（该源内 `default = true`）。
5. 打补丁 → 安装（签名变化，系统会要求先卸载官方 YouTube）。
6. YouTube → 设置 → Morphe → 视频 → **AI字幕翻译**：
   - API 地址：`http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions`
   - 密钥：任意（网关不校验入站 key）
   - 模型：`hy7b`（网关会用 `DEFAULT_MODEL` 覆盖该字段）
   - 点「测试 API」
7. 播放 → 开 CC → 字幕菜单 → 自动翻译 → 中文。

## 踩坑与回退

- **21.43.523 是实验目标**（作者标注 phone acceptance pending）。若设置项报 `AI caption translator` 失败或字幕不出现：
  退回 `21.30.216`（常规目标，minSdk 29）。
- 若「测试 API」报 `response_format ... not supported`：说明上游不支持 JSON Schema，
  补丁会自动降级（本次网关已把上游 4xx 错误体原样透传，正是为这个协商服务）。
- 回退：卸载补丁版 YouTube，装回 Play 商店版；RVX 全程不受影响，数据不动。
- `PATH_PREFIX` 必须带上（2.97 上是 `a2bxj5`），漏了会 404。
