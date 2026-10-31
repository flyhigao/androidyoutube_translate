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

### 推荐：PC 端 CLI 一键构建（本次实际采用）

```bash
bash scripts/build-patched-apk.sh c784f5f4
```

内部做的事：`adb pull` 已安装的官方 YouTube 四件套 → 打包 `.apks` → `morphe-desktop` CLI 合并并打补丁
（官方默认 109 个补丁 + `AI caption translator`）→ 推送到手机 `pm install`。

产物包名是 `app.morphe.android.youtube`（GmsCore support 补丁自动改包名），
所以**与官方 YouTube、RVX 三者共存**，不需要卸载任何现有 App。

### 备选：手机上用 Morphe Manager

1. 装 [Morphe Manager](https://github.com/MorpheApp/morphe-manager/releases/latest)，设置 → 开「专家模式」。
2. 补丁源 → 添加远程：`https://github.com/YYDarlinker/morphe-ai-caption-translator`。
3. 选 YouTube → 输入源：「从已安装应用获取」（Manager 会合并 split；补丁声明 `ApkFileType.APK_REQUIRED`，必须整包）。
4. 补丁选择：**保留官方默认组合**，只额外确认 `AI caption translator`。
5. 打补丁 → 安装。

### App 内配置
   - API 地址：`http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions`
   - 密钥：任意（网关不校验入站 key）
   - 模型：`hy7b`（网关会用 `DEFAULT_MODEL` 覆盖该字段）
   - 点「测试 API」
7. 播放 → 开 CC → 字幕菜单 → 自动翻译 → 中文。

## 已实测结果（2026-10-31）

- 构建：26.7s，109 个补丁，产物 137MB，签名 `CN=Morphe`
- 安装：`pm install -r -t` 成功，启动无 FATAL
- 资源校验：`cap_ai_title`（"AI 字幕翻译"）、`DeepSeekEnabledPreference` 均已在包内
- 网关侧：`json_schema` 请求 200 / 0.3~0.9s

## 踩坑与回退

- **21.43.523 是实验目标**（作者标注 phone acceptance pending）。若设置项报 `AI caption translator` 失败或字幕不出现：
  退回 `21.30.216`（常规目标，minSdk 29）。
- 若「测试 API」报 `response_format ... not supported`：说明上游不支持 JSON Schema，
  补丁会自动降级（本次网关已把上游 4xx 错误体原样透传，正是为这个协商服务）。
- 回退：卸载 `app.morphe.android.youtube` 即可；官方 YouTube 与 RVX 全程不受影响，数据不动。
- `PATH_PREFIX` 必须带上（2.97 上是 `a2bxj5`），漏了会 404。
