# Ayla Flutter 存储位置清单与 C 盘整改

> 状态：**审计结论已定稿（2026-11-02）**；改造方案待实施。
> 触发原因：用户实报「更新几次后 C 盘被 Ayla 占了 7G 且不自动删除」。
> 审计方式：只读源码 + 本机磁盘实测（未改任何代码、未跑 build）。
> 关联：`docs/architecture/flutter-local-media-cache.md`、`docs/operations/客户端发布与更新.md`。

## 0. 结论摘要（一句话）

**7.8 GB 全部来自自更新暂存的 `updates/` 目录树；它按「安装包 sha256」建目录 ⇒ 每发一版就多一个；
每个目录同时躺着 zip 原包与解包体（解包体是 zip 的 1.5~2.4 倍）；
而清理函数 `cleanupUpdateStaging` 全仓零调用点、覆盖安装脚本里没有一行 `del`/`rd`、启动期也没有任何回收层。
于是「更新次数」被线性映射成「磁盘占用」。**

实测：`C:\Users\ricer\AppData\Roaming\com.ayla\ayla_flutter\updates` = **7785.9 MB / 1666 文件 / 28 个 staging 目录**
（26 个完整 + 2 个只剩 `.part` 的孤儿）。

## 1. 本机实测：C 盘到底存了什么

| 路径 | 体积 | 内容 | 归属 |
|---|---|---|---|
| `%APPDATA%\com.ayla\ayla_flutter\updates\` | **7785.9 MB** | 28 个 `<sha256>/` 目录，各含 `*.zip` + `extracted/` + `apply-update.cmd` + `apply-update.log` | **自更新暂存（唯一大头）** |
| `%APPDATA%\com.ayla\ayla_flutter\flutter_secure_storage.dat` | 646 B | 记住的账号口令 + refresh token（DPAPI 整文件加密） | 账号凭据 |
| `%APPDATA%\com.ayla\ayla_flutter\ayla_chat_drafts.json` | 164 B | 聊天草稿（**明文**，用户未发送的原话） | 账号数据 |
| `%APPDATA%\com.ayla\ayla_flutter\ayla_home_prefs.json` | 56 B | 首页布局 + 最近群 id | 账号数据 |
| `%APPDATA%\com.ayla\ayla_flutter\ayla_search_history.json` | 8 B | 搜索历史 | 账号数据 |
| `%TEMP%\ayla-*` × **294 个目录** | ≈0 MB | `ayla-dlq`142 / `ayla-cache`76 / `ayla-permanent`75 / `ayla-audio`1 | 测试残留（非 App 运行时） |
| **合计** | **≈7.79 GB** | 其中 99.97% 是更新包 | |

> **媒体缓存不在 C 盘**：本机 `%APPDATA%\com.ayla\ayla_flutter\media-cache` **不存在**；
> 实际落在 `E:\ayla-windows-x64-1.0.1+2\data\media-cache`（120 MB）。见 §3.2。

## 2. 更新包存储（本次 7.8 GB 的全部来源）

### 2.1 落点解析链（源码确证）

| 环节 | 证据 |
|---|---|
| Dart 选目录 | `lib/core/update/update_downloader.dart:156-165` `_updatesRoot()`：`Platform.isAndroid \|\| Platform.isIOS ? getTemporaryDirectory() : getApplicationSupportDirectory()`（`:157-159`），拼 `/updates`（`:160-163`） |
| Windows 实际值 | `getApplicationSupportDirectory()` → `path_provider_windows-2.3.0/lib/src/path_provider_windows_real.dart:119-120` `_createApplicationSubdirectory(WindowsKnownFolder.RoamingAppData)`；子目录名取 exe 的 VERSIONINFO `CompanyName\ProductName`（`:180-226`），Ayla 在 `windows/runner/Runner.rc:92,98` 声明为 `com.ayla` / `ayla_flutter` ⇒ **`%APPDATA%\com.ayla\ayla_flutter\updates`** |
| staging 目录名 | `update_downloader.dart:90-92` = `_safeDirName(download.sha256)`（`:187-190`）⇒ **按安装包内容 sha256 命名** |
| 下载写 `.part` | `:97-98`、`:112-124`（`dio.download(partPath, deleteOnError: true)`） |
| 校验后 rename | `:126-136`（尺寸 + SHA-256 双校验，`part.rename(finalPath)`） |
| 解包目录 | `lib/core/update/update_applier.dart:146-150` `stagingDir/extracted`（`:149` 仅同目录重试时先删） |
| 安装脚本/日志 | `update_applier.dart:167-170`、`:253-284` `buildWindowsApplyScript` |
| 覆盖目标 | `:226-230` `_resolveTargetDir()` = 当前 exe 父目录；`:271` `robocopy /E /COPY:DAT`（**只覆盖不删**） |

Android：`cacheDir/updates/<sha>/`（`path_provider_android-2.3.1/lib/src/path_provider_android_real.dart:22-25` 的 `getTemporaryPath()` 直接返回 `getApplicationCachePath()`）。
iOS：`Library/Caches/updates/`，但 `update_applier.dart:118-130` 的 iOS 分支**根本不调 downloader** ⇒ **不落盘**。

### 2.2 体积构成（本机实测）

| 组成 | 体积 | 占比 |
|---|---|---|
| `extracted/`（解包体） | ≈4676 MB | **60%** |
| `*.zip`（安装包原件） | ≈3134 MB | 40% |
| `apply-update.cmd` + `apply-update.log` | ≈30 KB | ~0 |

实测膨胀比：38→92 MB、118→173 MB、125→189 MB、129→193 MB ⇒ **1.5~2.4 倍**。

### 2.3 根因：五条机制叠加（缺一不可）

1. **目录名 = 包内容 sha256，先天不可复用。** 任何新版本 zip 字节都不同 ⇒ sha 不同 ⇒ 必然新建目录。
   而唯一的目录级清理 `update_downloader.dart:93-95`（`if (await staging.exists()) delete(recursive: true)`）
   前提是「同名目录已存在」，跨版本**永不触发**。
2. **写了清理函数但没有接线。** `cleanupUpdateStaging`（`update_applier.dart:287-294`）**全仓 0 调用点**（含测试）。
   `AylaPreparedUpdate` 只携带 `stagingDir` 字符串（`update_downloader.dart:45/57/141`），
   没有任何类持有「这个目录我负责销毁」的语义。
3. **成功路径主动放弃清理时机。** Windows 覆盖安装必须「脚本等本进程退出后替换文件」
   （`update_applier.dart:12-16` 设计说明）⇒ apply 一启动就必须 `_requestExit(0)`
   （`update_controller.dart:285-290`）。进程退出后 Dart 侧再无回调可执行；
   而脚本本身只有 `taskkill/ping/robocopy/start/exit`（`:260-283`），**没有一行 `del`/`rd`**。
4. **体积是双份而非单份。** zip 与 `extracted/` 长期共存；`:149` 只在「同目录再 apply」时清解包体。
5. **没有任何兜底回收层。**
   - 启动期：`main.dart` 对 `update|cleanup|delete` **零命中**；`windows/runner/*.cpp` 同样零命中。
   - 系统层：`%APPDATA%\Roaming` **不是** `%TEMP%`，Windows 磁盘清理/存储感知**不会**回收它。
   - 文档层：`docs/operations/客户端发布与更新.md:191` 与 `update_applier.dart:15/:263` 都把这处写成
     **`%TEMP%`**，导致运维误以为「系统会自己清」。**这是本次残留能长到 7.8 GB 而长期无人察觉的直接原因。**

> **一句话**：7.8 GB 不是内存泄漏式的 bug，是**设计导致的线性累积**——
> 「更新过多少版」直接等于「磁盘上留多少个 150~320 MB 的目录」。

### 2.4 清理矩阵（哪些时机真的会删）

| 时机 | 是否清理 | 证据 |
|---|---|---|
| `cleanupUpdateStaging` 被调用 | **从不（0 调用点）** | `update_applier.dart:287` 定义处之外全仓零引用 |
| 下载成功 | **否**（只 rename） | `update_downloader.dart:136-142` |
| 尺寸/SHA 校验失败 | 仅删 `.part` 文件 | `:126-135` → `:147-149` `_deleteQuietly` |
| 下载异常（DioException） | 只靠 Dio 的 `deleteOnError`，不删目录 | `:143-146`、`:116` |
| 解包失败 / 缺 exe / 脚本启动失败 | **否** | `update_applier.dart:157-165`、`:180-183` |
| apply 成功（Windows） | **否**（随即 exit(0)） | `:184-189` → `update_controller.dart:285-290` |
| apply 成功（Android） | **否**（注释明写「保留 APK」） | `:199-208` |
| 同 sha 重试下载 / 同目录重试 apply | 是（删该目录 / 删 extracted） | `update_downloader.dart:93-95`、`update_applier.dart:149` |
| App 启动 | **无任何回收** | `main.dart`、`windows/runner/*.cpp` 零命中 |

### 2.5 实测佐证

- 读到了真实生成的 `apply-update.cmd`：`SRC=…\updates\<sha>\extracted`、`DST=E:\ayla-windows-x64-1.0.1+2`、
  `robocopy "%SRC%" "%DST%" /E`、`start "" "%DST%\%EXE%"`、`exit /b 0` —— **没有任何删除步骤**。
- 26 份 `apply-update.log` 全部是 `Ayla update start` → `Ayla update done`，即**成功路径 = 残留路径**。
- 孤儿目录 2 个（1.7 MB / 29 MB），证明「下载中断连目录一起留下」。

## 3. 媒体与聊天记录存储

### 3.1 聊天记录本身：**不落盘**

消息来自后端 API + WS（`lib/core/api/chat_api.dart:228-266`），运行时只在内存
（`lib/state/message_state.dart:62-66`、`lib/state/chat_state.dart:52-58`）；
依赖清单无 sqflite/hive/isar/drift/sembast（`pubspec.yaml:30-83`），`lib/` 内上述关键词**零命中**。
进程退出即丢，下次进会话重新分页拉取。**因此「聊天记录」不会占 C 盘。**

### 3.2 媒体缓存：Windows 跟着 exe 走，**另有静默降级到 C 盘的隐藏分支**

| 平台 | 首选根 | 降级根（含触发条件） |
|---|---|---|
| Windows | `<exe目录>\data\media-cache\`（`media_cache_paths.dart:212-222`） | `%APPDATA%\com.ayla\ayla_flutter\media-cache\`（`:223-234`），当 exe 同级不可写时触发，**只打一行 debugPrint** |
| Android | `/storage/emulated/0/Android/data/com.ayla.ayla_flutter/files/media-cache/`（`:244-255`） | `getApplicationSupportDirectory()/media-cache`（`:257-274`） |
| iOS | `<沙盒>/Library/Application Support/media-cache/`（`:277-287`） | 无降级 |

- 本机 exe 在 `E:\Elysium-AyerElysia\Elysium\Ayla\flutter\build\windows\x64\runner\Release` ⇒ 缓存 84 MB 在 **E 盘**；
  正式安装目录 `E:\ayla-windows-x64-1.0.1+2\data\media-cache` = 120 MB，同样在 E 盘。
  **C 盘无 media-cache，降级分支本机未触发。**
- 布局：`media-cache/<kind>/<media_id前2位>/<media_id>[.thumb].<ext>`，kind ∈ image/voice/video/file/emoji。
- **容量控制：完全没有。** 无总量上限、无 LRU、无 TTL 淘汰（`media_cache.dart:12-17` 文档化「D2：不做」）；
  启动只清 `*.tmp`（`:799-826`）；`evict()`（`:713`）、`stats()`（`:748`）、
  队列的 `clearFailed()`（`media_download_queue.dart:506`）**全部零调用**；**没有任何用户可见的「清理缓存」入口**。
- 单张原图实测可达 84 MB（`media_cache.dart:679-680` 自承），而缓存**只增不减**。
- 下载队列文件：`<缓存根同级>/download-queue.json`（`media_download_queue.dart:275-279`）；条目无上限、failed 记录永不自动清。
- 语音录制临时文件：`getTemporaryDirectory()/voice-<ms>.<ext>`（`voice_recorder.dart:166-168`）；
  **只有 `cancel()` 会删**（`:241-244`），发送成功/失败/过短/页面关闭/异常 5 条路径都在系统 Temp 残留。

## 4. 账号数据存储（体积极小，但敏感度最高）

| 数据 | Windows 路径 | 证据 | 敏感度 |
|---|---|---|---|
| 记住的账号 + 口令 + refresh token | `%APPDATA%\com.ayla\ayla_flutter\flutter_secure_storage.dat`（DPAPI 整文件加密） | `state/auth_prefs.dart:40`（无参 `FlutterSecureStorage()`）；`flutter_secure_storage_windows-4.2.2/lib/src/flutter_secure_storage_windows_ffi.dart:257`（文件名常量）、`:275-284`（`getApplicationSupportDirectory()`）、`:430` `CryptProtectData` | **最高**：同机同用户可解密，可还原明文口令 |
| 聊天草稿（**明文**） | `…\ayla_chat_drafts.json` | `state/chat_drafts.dart:39/107-110/123-126` | 中高：未发送原话 |
| 搜索历史 | `…\ayla_search_history.json` | `state/search_history.dart:39/109-112/126-129` | 低 |
| 首页偏好 | `…\ayla_home_prefs.json` | `state/home_prefs.dart:53/145-148/161-164` | 低（暴露最近群 id） |

Android：`/data/data/com.ayla.ayla_flutter/files/`（三个 json）+ `shared_prefs/FlutterSecureStorage.xml`（AES-GCM，密钥在 KeyStore）。
iOS：`<沙盒>/Library/Application Support/` 三个 json + Keychain（凭据）。

其它确认**不落盘 / 不写用户目录**：`window_manager`（不持久化窗口位置，`window_manager-0.5.2` 无持久化依赖）、
`package_info_plus`（只读 exe 版本资源）、`url_launcher`、`media_kit`（纯 FFI）、
`video_poster`（内存 JPEG 直接上行）；业务代码**零使用** `shared_preferences`（故无 `shared_preferences.json`）。
唯一例外：`main.dart:103` 的掉帧探针 `ayla_jank.log` 用的是**相对路径**（写进程 CWD，开发机实测 41.8 MB），
debug 恒开、release 需 `--dart-define=AYLA_FRAME_PROBE=true`。

## 5. 「绝对不能存 C 盘」——现状差距

| 要求 | 现状 | 差距 |
|---|---|---|
| 更新包不得落 C 盘 | Windows **固定**落 `%APPDATA%\Roaming\...\updates`，且**永不删除** | ❌ 主违规 |
| 媒体缓存不得落 C 盘 | 首选跟 exe 走（装在 E 盘则 OK），但**不可写时静默降级到 C 盘**，且无 UI 告知、无迁移 | ⚠️ 条件违规 |
| 账号数据不得落 C 盘 | 三个 json + 凭据 **100% 固定**在 `%APPDATA%\Roaming`，**没有任何配置能改** | ❌ 结构上做不到 |
| 用户可见的清理入口 | **完全没有** | ❌ |
| 容量上限 / 自动淘汰 | **完全没有** | ❌ |

**关键约束（决定方案形状）**：
1. `getApplicationSupportDirectory()` 在 Windows 上恒为 `%APPDATA%\Roaming\<Company>\<Product>`，
   由 exe 的 VERSIONINFO 决定，**Dart 侧无法改**。
2. 因此「把账号数据搬离 C 盘」只有两条路：**自定义存储根**（Ayla 自己解析，不再依赖 path_provider）
   或 **符号链接**（`mklink /J`，需要开发者模式或管理员）。
3. 更新流程必须进程退出后才能覆盖自身文件 ⇒ **清理只能在「下一次启动」或「脚本尾部」发生**。

## 6. 整改方案（三选一，按彻底程度排序）

### 方案 A（推荐）：引入统一存储根 `AylaPaths`，默认落在 exe 同级 `data/`

新增 `lib/core/storage/ayla_paths.dart`，统一解析五类目录，优先级：
`--dart-define=AYLA_DATA_ROOT` → 便携标记文件 `<exe目录>\ayla-portable.json` → 默认 `<exe目录>\data\`（可写探测）→ 最后才回落 `getApplicationSupportDirectory()`（并在 UI 上显式告知）。

- 更新包 → `<root>/updates/<sha256>/`
- 媒体缓存 → `<root>/media-cache/`（复用现有布局）
- 账号数据 → `<root>/profile/`（三个 json）
- 凭据 → 仍用 `flutter_secure_storage`（DPAPI 文件位置随 `getApplicationSupportDirectory` 走，**无法改**）
  ⇒ 或改用自管 DPAPI 文件（`CryptProtectData` 通过 FFI），落到 `<root>/profile/credentials.dat`

**配套必做（缺一不可）**：
- 一次性迁移：首次启动检测 `%APPDATA%\Roaming\com.ayla\ayla_flutter\` 旧文件 → 复制到新根 → 原处留 `.migrated` 标记（**不删**，可回滚）。
- 启动期回收：`main()` 早期扫描 `updates/`，保留「当前版本 sha + 最近 1 个」，其余 `delete(recursive:true)`。
- 大小上限：`updates/` 总量阈值（如 2 GB）+ 媒体缓存阈值（如 5 GB）+ LRU 淘汰。
- 脚本收尾：`buildWindowsApplyScript` 在 `robocopy` 成功后追加 `rd /s /q "%SRC%"`（删解包体）与 `del /f /q "%LOG%"`。
- UI：设置页新增「存储位置」展示实际根路径 + 「清理更新包 / 清理媒体缓存」按钮（把已有死代码 `evict`/`stats`/`clearFailed` 接上）。
- 修文档：`客户端发布与更新.md:191`、`update_applier.dart:15/:263` 的 `%TEMP%` 改为真实路径。

### 方案 B：仅止血（最小改动，1~2 天）

不动存储根，只做三件事：
1. **启动期回收 `updates/`**（唯一能覆盖「成功路径必须退出」约束的位置）；
2. **接上 `cleanupUpdateStaging`** 到所有失败分支 + 非 Windows 分支；
3. **脚本尾部删 `extracted/`**（立省 60% 体积）。

效果：一次性可回收 **7.79 GB**，之后每版稳态占用从 ~320 MB 降到约 0。缺点：账号数据仍在 C 盘。

### 方案 C：符号链接（不改代码，但要求权限）

`mklink /J "C:\Users\<u>\AppData\Roaming\com.ayla" "E:\AylaData\com.ayla"`。
缺点：需开发者模式/管理员；对已有目录要先迁移；安装到别的机器要重复操作。**不推荐作为产品方案**。

## 7. 验收标准

- [ ] 全新安装到 E 盘后，跑完 3 次更新，`C:\Users\<u>\AppData\Roaming\com.ayla` **不存在**或 **< 1 MB**；
- [ ] `updates/` 在每次启动后只剩 ≤2 个目录，总量 ≤ 2×单包；
- [ ] `C:Users\...\Roaming\com.ayla\ayla_flutter\media-cache` 永不出现（降级分支需改为报错或明确 UI 提示）；
- [ ] 设置页可看到真实存储根路径与占用，并能一键清理；
- [ ] 定向测试：启动期回收（保留当前 sha、删其余）、清理失败不阻塞启动、迁移幂等（跑两次结果一致）。

## 8. 立即止血（本次已确认可安全执行的命令，**未执行**）

> 关掉 Ayla 进程后执行；只删 `updates/`，其余 4 个小文件保留。

```powershell
Remove-Item -Path "$env:APPDATA\com.ayla\ayla_flutter\updates" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\ayla-cache-timing-*","$env:TEMP\ayla-dlq-test-*","$env:TEMP\ayla-permanent-*","$env:TEMP\ayla-audio-backup-*" -Recurse -Force -ErrorAction SilentlyContinue
```

（`updates/` 全部是历史版本的下载包与解包体，删除不影响当前安装与登录状态。）
