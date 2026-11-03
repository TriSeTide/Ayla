# Ayla Flutter 存储位置清单与 C 盘整改

> 状态：**已整改并验收（2026-11-02）**。
> 触发原因：用户实报「更新几次后 C 盘被 Ayla 占了 7G 且不自动删除」。
> 用户裁决（两轮，后者覆盖前者的边界）：
> ① 「**全部改到 `<exe目录>\data\`。不允许任何动 C 盘，也不允许任何 C 盘的降级回退。**」
> ② 「**万一真有人把包放进 Program Files 呢 —— 加个判断吧**」→「**如果真有，就让他装在那里正常用，
> 这种情况允许写 C 盘，装 C 盘就允许写 C 盘，但是 data 还是全部写在 exe 同级。**」
>
> ⇒ 最终口径：**data 目录语义不变（永远是显式的 `data`）**；
> exe 同级不可写时（Program Files 受 UAC 保护）**回落到 `%LOCALAPPDATA%\Ayla\data`**，
> 应用照常使用；**任何时候都不回到** `%APPDATA%\Roaming\<Company>\<Product>`
> 那种用户看不见的隐式目录（那正是 7.79 GB 事故没人发现的根源）。
> 关联：`docs/architecture/flutter-local-media-cache.md`、`docs/operations/客户端发布与更新.md`。

## 0. 结论摘要

**问题**：7.79 GB 全部来自自更新暂存的 `updates/` 目录树。它按「安装包 sha256」建目录 ⇒ 每发一版多一个；
每个目录同时躺着 zip 与解包体（解包体是 zip 的 1.5~2.4 倍）；清理函数 `cleanupUpdateStaging` 全仓零调用点、
覆盖脚本没有一行 `del`/`rd`、启动期也没有回收层 ⇒「更新次数」被线性映射成「磁盘占用」。

**修复**：引入统一存储根 `<exe目录>/data`（Windows），**删除全部 C 盘回退分支**，
并加上启动期回收。整改后 C 盘 `%APPDATA%\com.ayla` 从 **7785.92 MB → 0.00 MB**。

## 1. 整改后的存储布局（唯一事实源）

Windows 上一律落在 **`<exe 所在目录>/data/`**，即与安装盘一致（装在 E 盘就全在 E 盘）。

```
<exe目录>/data/
├── profile/
│   ├── flutter_secure_storage.dat      DPAPI 加密的账号口令 + refresh token
│   ├── ayla_chat_drafts.json           聊天草稿（明文）
│   ├── ayla_search_history.json        搜索历史
│   └── ayla_home_prefs.json            首页偏好
├── media-cache/                        媒体漫游缓存
│   └── <kind>/<id前2位>/<id>[.thumb].<ext>
├── updates/                            自更新暂存（启动期回收，只留当前版本）
├── voice/                              语音录制临时文件
├── download-queue.json                 离线下载队列
└── ayla_jank.log                       掉帧探针（仅 debug/profile 且显式开启）
```

**exe 同级不可写时（唯一例外，且必须有判断）**：
`%LOCALAPPDATA%\Ayla\data\` —— 目录结构完全相同（profile / media-cache / updates / voice），
只是宿主位置换成用户可写的本地应用数据区。启动日志与诊断会打印实际根路径。

> 为什么不是 `%APPDATA%\Roaming\com.ayla`：那是 path_provider 按 exe VERSIONINFO
> 自动派生的路径，**用户完全看不到**，Windows 磁盘清理也不碰它 —— 7.79 GB 就是这样
> 长期无人察觉的。`%LOCALAPPDATA%\Ayla` 是显式命名、可见、可整体搬走。

Android / iOS：`getApplicationSupportDirectory()`（应用私有沙盒），**不再有外部存储分支**。

### 1.1 唯一解析入口

`lib/core/storage/ayla_storage_paths.dart`：

| 函数 | 返回 | 说明 |
|---|---|---|
| `aylaEnsureDataRoot()` | `String` | 解析并试写探测；**不可写即抛 [AylaStorageException]，没有回退** |
| `aylaProfileDirectory()` | `Directory` | `<data>/profile` |
| `aylaMediaCacheDirectory()` | `Directory` | `<data>/media-cache` |
| `aylaUpdatesDirectory()` | `Directory` | `<data>/updates` |
| `aylaVoiceDirectory()` | `Directory` | `<data>/voice` |
| `aylaMigrateLegacyAppData()` | `Future<void>` | 旧落点一次性迁移 + **删除旧目录** |

**任何新增落盘点必须走这里**，禁止再用 `path_provider` 的默认目录
（回归锁 `test/storage_no_c_drive_lock_test.dart` 会静态扫描 `lib/` 拦截）。

## 2. 本次改了哪些文件

| 文件 | 改动 |
|---|---|
| `lib/core/storage/ayla_storage_paths.dart` | **新增**：统一存储根 + 迁移 |
| `lib/core/storage/ayla_dpapi_secure_store.dart` | **新增**：Windows 自管 DPAPI 凭据文件（插件无法配置目录） |
| `lib/core/update/update_retention.dart` | **新增**：`updates/` 启动期回收（本次 7.79 GB 的根因修复） |
| `lib/core/update/update_downloader.dart` | 暂存根 → `aylaUpdatesDirectory()`，删掉 `getApplicationSupportDirectory` 分支 |
| `lib/core/update/update_applier.dart` | 覆盖脚本在 `robocopy` 成功后 `rd /s /q "%SRC%"` 删解包体（立省 60% 体积） |
| `lib/core/media/media_cache_paths.dart` | 删除 Windows「不可写 ⇒ 静默降级 `%APPDATA%`」分支，改为抛错；删除 Android 外部存储分支 |
| `lib/core/media/media_cache.dart` | `ensureReady()` 返回可空；不可写 ⇒ **不缓存**（不降级） |
| `lib/core/media/media_download_queue.dart` | 队列文件 → `<data>/download-queue.json` |
| `lib/core/media/voice_recorder.dart` | 录音临时文件 `%TEMP%` → `<data>/voice/` |
| `lib/state/chat_drafts.dart` / `search_history.dart` / `home_prefs.dart` | 落点 → `<data>/profile/` |
| `lib/state/auth_prefs.dart` | 改为 re-export 新的 DPAPI 实现 |
| `lib/main.dart` | 启动期：解析数据根 → 迁移旧落点 → 回收 `updates/`；掉帧日志改绝对路径 |
| `test/storage_no_c_drive_lock_test.dart` | **新增**：11 条回归锁 |

## 3. 根因（保留，供后续排查）

五条机制叠加，缺一条都不会长到 7.8 GB：

1. **目录名 = 包内容 sha256，先天不可复用。** 新版本 zip 字节必然不同 ⇒ 必然新建目录；
   唯一的目录级清理只在「同名目录已存在」时触发，跨版本**永不命中**。
2. **写了清理函数但没接线。** `cleanupUpdateStaging` 全仓 0 调用点，没有任何类持有
   「这个目录我负责销毁」的语义。
3. **成功路径主动放弃清理时机。** Windows 覆盖安装必须「脚本等本进程退出后替换文件」，
   apply 一启动就 `exit(0)`，Dart 侧再无回调；而脚本本身只有
   `taskkill/ping/robocopy/start/exit`，**没有一行 `del`/`rd`**。
4. **体积是双份。** zip 原包 + `extracted/` 长期共存（实测 3134 MB + 4676 MB）。
5. **没有任何兜底回收层。** 启动期零命中；`%APPDATA%\Roaming` 不是 `%TEMP%`，
   Windows 不会回收；文档还把落点误写成 `%TEMP%`，导致长期无人察觉。

## 4. 清理动作（已执行）

```powershell
# 1) 历史更新暂存（7785.92 MB → 0）
Remove-Item -Path "$env:APPDATA\com.ayla\ayla_flutter\updates" -Recurse -Force
# 2) 测试残留的 294 个 ayla-* 临时目录
Get-ChildItem $env:TEMP -Directory | Where-Object Name -match '^ayla-' | Remove-Item -Recurse -Force
```

结果：`%APPDATA%\com.ayla` 从 **7785.92 MB / 1670 文件 → 0.00 MB / 4 文件**
（只剩 4 个小 json/凭据；新版本首次启动会把它们搬到 `<exe>/data/profile` 并删除旧目录）。

## 5. 验收标准与结果

| 项 | 判据 | 结果 |
|---|---|---|
| 数据根不在 C 盘 | `aylaEnsureDataRoot()` 不以 `%APPDATA%`/`%TEMP%` 开头 | ✅ 回归锁锁定 |
| 无 C 盘回退 | Windows 缓存根不可写 ⇒ 抛错且 `<support>/media-cache` 不被创建 | ✅ 2 条端到端测试 |
| 旧落点迁移 | 迁移后旧目录被删除，幂等 | ✅ 回归锁 |
| 更新暂存回收 | 只留最近 1 个 + 当前版本，其余删除 | ✅ 4 条回归锁 |
| 静态扫描 | `lib/` 除白名单外不出现 `getApplicationSupportDirectory`/`getTemporaryDirectory` | ✅ 回归锁 |
| 静态分析 | `dart analyze lib` 零 error | ✅ |
| C 盘占用 | `%APPDATA%\com.ayla` ≈ 0 | ✅ 实测 0.00 MB |

## 5.5 Program Files 场景（2026-11-02 用户第二轮裁决）

**问题**：若用户把 Ayla 装进 `C:\Program Files\Ayla`，exe 同级 `data/` 受 UAC 保护不可写。

**处置**（`lib/core/storage/ayla_storage_diagnosis.dart` + `ayla_storage_paths.dart`）：

| 场景 | exe 同级可写？ | 实际数据根 | 应用可用性 |
|---|---|---|---|
| 装在 D:/E: 自建目录（推荐） | ✅ | `<exe目录>/data` | 正常 |
| 装在 `C:\Program Files\...` | ❌ | `%LOCALAPPDATA%\Ayla\data` | **正常**（允许写 C 盘，但仍是显式 Ayla 目录） |
| 任何位置 | — | **绝不**用 `%APPDATA%\Roaming\com.ayla` | — |

**判断方式**：不猜路径，只做**可写性探测**（建目录 + 试写 1 字节 + 删除）。
判据与路径名无关 —— 用户可能把 `D:\Program Files` 的 ACL 放开，猜目录名会误伤。

**用户可见性**：启动日志打印实际根路径与来源；`aylaDataRootSource` 取值
`exe-data` / `local-appdata` / `mobile-support`，可直接用于支持排查。

**可选的搬迁入口**：`aylaRelocateInstallation()` 把整个安装目录（含 `data/`）复制到
`%LOCALAPPDATA%\Programs\Ayla`，**不删原目录**（用户确认能跑后再自己删）。
UI 入口 `lib/widgets/base/storage_blocked_screen.dart` 已实现，但**当前不阻断启动**，
保留给「用户主动想搬」的场景。

## 5.6 连带事故：Android「点安装跳浏览器」（2026-11-02 用户实报）

**症状**：手机端检查更新 → 下载完成 → 点「安装」→ **跳到浏览器去下载 APK**，
而包其实已经下载好了。

**根因（存储整改的连带破坏）**：
APK 落点从「系统临时目录（cacheDir）」改成了「数据根/updates」
（Android 上 = `getFilesDir()/updates`）。但两处旧契约没跟着改：

| 层 | 旧契约 | 后果 |
|---|---|---|
| `MainActivity.installApk` | 只校验文件在 `cacheDir` 之下 | **合法 APK 被判非法路径** ⇒ 返回 false |
| `res/xml/file_paths.xml` | 只声明 `<cache-path>` | FileProvider 也不授权 `filesDir` 路径 |
| `update_applier._applyAndroidApk` | 收到 false **静默** `openUrl(下载页)` | 用户看到「跳浏览器重复下载」 |

**修复**：
1. `file_paths.xml` 同时声明 `<files-path>`（现行）与 `<cache-path>`（兼容旧版本残留）；
2. `installApk` 同时接受 `filesDir` 与 `cacheDir`，仍然**拒绝任意路径**；
3. 安装器返回 `AylaApkInstallOutcome{launched, reason}`（不再是裸 bool）；
4. `update_applier` **只有「当前构建没有内置安装器」才允许打开下载页**，
   其余失败（权限被关 / 路径被拒 / 包已删除）一律抛 `AylaUpdateApplyException`
   把原因显示给用户，**保留已校验的 APK** 供重试。

**回归锁**：`test/android_apk_install_lock_test.dart`（5 条）
+ `test/update_applier_test.dart` 新增「安装器被拒 ⇒ 抛错且不打开浏览器」。

> **教训**：改「文件落在哪」会同时改变**原生侧路径校验**与 **FileProvider 授权**这两条
> 隐式契约。以后任何落点迁移，必须同时核对：`MainActivity` 的 allowed roots、
> `file_paths.xml` 的 `<paths>`、以及各平台「用路径换 content:// 或 file://」的地方。

## 6. 已知取舍（显式登记）

1. **凭据文件从插件改为自管 DPAPI 文件**：`flutter_secure_storage` 的 Windows 实现固定写
   `%APPDATA%` 且无配置入口，只能自管。加密算法与插件一致（`CryptProtectData`，当前用户作用域），
   安全级别不变；但**已保存的账号密码会在迁移后保留**（迁移会复制 `.dat`）。
2. **装到 `Program Files` 不再报错**：回落 `%LOCALAPPDATA%\Ayla\data`，
   应用正常使用（用户 2026-11-02 第二轮裁决）。代价是数据不跟安装目录走，
   且 `%LOCALAPPDATA%` 仍在 C 盘 —— 但它是**显式可见**的 Ayla 目录，不是隐式缓存。
3. **`updates/` 保留当前版本 + 最近 1 个**：给「安装失败后重试」留一次机会；
   若磁盘紧张可把 `kAylaUpdateStagingKeep` 调 0。
4. **媒体缓存仍无总量上限/LRU**（本次未做，属独立议题）：目前只是不再落 C 盘。
