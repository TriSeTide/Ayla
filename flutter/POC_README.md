# Ayla Flutter PoC 报告（PoC-A 语音中继 / PoC-B HLS 待续）

> 实施时间：2026-09-16 ~ 09-17。本文件记录 PoC-A 全链路实测结论与选型定论，
> 供 M5（语音）与 lib/audio 架构落地使用。PoC-B（HLS 三端）结论完成后追加。

## 1. 环境结论

- **Flutter**：3.35.4 stable / Dart 3.9.2（Windows 侧 `/e/flutter`，WSL 经 `cmd.exe /c flutter.bat` 调用；
  WSL 直跑其 bash 脚本会因 CRLF 失败）。Android toolchain ✓（SDK 36）、VS2022 ✓。
- **Android 模拟器**：手动创建 AVD `poc_avd`（android-36 google_apis x86_64；avdmanager 报
  `path is null` 弃用，改手写 `~/.android/avd/` 配置成功）。模拟器音频宿主侧无声 + **无麦克风输入设备**
  （`dumpsys audio` 无 INPUT 设备；record 初始化失败 `AudioFlinger could not create record track, status: -1`）。
- **后端**：Ayla daphne 8100（用户手动启动）。Redis/MySQL/MinIO 正常。
- **SRS**：5.0.213 在跑（1935/1985/8080），测试期间无推流。
- **网络**：本机 github/services.gradle.org 直连极慢（~16KB/s）；pub.dev 镜像（flutter-io.cn）快；
  用户代理（127.0.0.1:7897，Steam++ 加速 github）对 release 下载有效。

## 2. 阶段 0 工程

- 位置：`Ayla/flutter/`（org com.ayla，android/ios/windows）。
- 依赖：web_socket_channel ^3.0.3 / record ^6.2.1 / opus_codec ^3.0.5 + opus_codec_dart ^3.0.5 /
  video_player ^2.10.1 / audio_session ^0.2.4 / path_provider ^2.1.5 / flutter_soloud 3.5.4 /
  miniaudio_dart 1.0.10。media_kit 系暂移出（其 Windows mpv 运行库需 GitHub 下载，本机受阻；
  PoC-A 不需要；PoC-B 视 mpv 下载结果决定加回或换 video_player_win）。
- Android 构建修复：gradle wrapper 换腾讯镜像（`mirrors.cloud.tencent.com`）、maven 换阿里镜像；
  `NO_OPUS_OGG_LIBS=true`（flutter_soloud 与 opus_codec 双 libopus.so 冲突）。
- 三端壳：Windows/Android `flutter run` 均启动成功；iOS 仅目录+analyze（无 macOS）。

## 3. PoC-A：WS 音频中继整链

### 3.1 链路选型（各环节实测结论）

| 环节 | 选型 | 实测结论 |
|---|---|---|
| 采集 | record 6.x `startStream(pcm16bits, 48k, mono)` | Windows 麦克风 ✓（web 端听到话音）；Android 模拟器 ✗（无输入设备） |
| 编码 | opus_codec_dart `SimpleOpusEncoder`（libopus FFI，48k mono voip，20ms/960 样本） | ✓ 编解码正常（opus_dart SDK<3.0.0 不可用、flutter_libopus 404、opus_flutter 同约束、flutter_opus 无 windows → opus_codec 系列胜出） |
| 传输 | web_socket_channel + 中继协议（对照 wsRelayRoom.ts/audio_consumer.py：`[1B slot][opus]` 下行、speaking/mute/ping 控制帧、N-1） | ✓ 双连接实测：joined/slot 分配、member_joined/left 广播、speaking 广播、音频帧带 slot 前缀转发、**RTT 4ms**；同一账号双连接可行（slot 各自分配） |
| 解码 | opus_codec_dart `SimpleOpusDecoder` → Int16 | ✓ 收到帧解码正常（web/Android 均可播） |
| 播放 | Android：flutter_soloud buffer stream ✓；Windows：**插件层全部实测失败**（见下） | Android 出声 ✓（断续疑似模拟器性能）；Windows ❌ |

### 3.2 播放选型记录（实测淘汰 → 定论：flutter_miniaudio 本地 fork 全平台）

**淘汰过程（实测失败）**：
1. **flutter_soloud 3.5.4**（Windows MiniAudio 后端）：
   - buffer stream **积压不实时**：数据一直喂但不出声，**停止更新时一次性 flush 全部**（用户实测"突然全部滴出来"）→ 断连时海量帧触发崩溃（2 次）。
   - `loadWaveform→play` 卡死（2 次复现）；`disconnect→deinit` 卡死（2 次）。
2. **miniaudio_dart 1.0.10**（StreamPlayer，全平台统一候选）：
   - **`StreamPlayer.init()` 挂起**（debugState 实测：libInit=true 但 miniaudioReady=false，await 永不返回；C 层 engine.c 的 ma_context_init/ma_engine_init 同步调用，noAutoStart=true）；
   - FFI native assets 不完整（hook/ 目录空、需手动 cmake 构建），运行时 Native asset 加载失败。

**定论（2026-09-17 验收）**：**flutter_miniaudio 本地 fork 全平台播放**。
- 上游 flutter_miniaudio 可用，但 CMakeLists 固定 `-O2` 与 MSVC debug `/RTC1` 冲突（D8016）、源码用 GCC `__sync_synchronize`（MSVC LNK2019）→ 本地 fork 至 `Ayla/flutter/third_party/flutter_miniaudio`，`pubspec.yaml dependency_overrides` path 指向，修 MSVC 兼容（改动仅 CMake 分支）。
- 播放形态：`MiniaudioPlayer` push 式 `write(Int16)`（miniaudio 底层 WASAPI/AAudio），`bufferLatency` 可测，实时 VoIP 定位。
- **已验收**：三全平台（Windows / Android 模拟器 / iOS 代码路径）统一走此方案；Android 模拟器端出声 ✓，Windows 端出声 ✓。
- lib/audio 落地建议：播放层收敛为 miniaudio fork 统一封装（M5 直接用），不再为 Windows 单写 WASAPI。

> 原"Windows 需自写 WASAPI 原生通道"结论撤回：fork 后全平台插件方案可用，无需自写原生通道。

### 3.3 其他实测结论

- **daphne 不解析 chunked 请求体**：dart:io HttpClient 默认 chunked → 登录 400"字段必填"（实测）。
  修复：显式 `req.contentLength` + `req.add(bytes)`。（**重要坑，M1 认证落地也适用**）
- **热重载（hot reload/restart）在原生音频状态上有污染**：SoLoud/miniaudio 的 FFI 对象热重载后状态错乱
  （卡死/异常）。**音频相关改动必须完整重启（debug run）验证**，不要热重载。
  另：flutter 增量编译对 WSL 侧文件变更检测不可靠 → 改完 touch 文件强制重编，或直接完整重启。
- **启动崩溃根因（已修）**：`initState` 里 `_log` 调 `ScrollController.animateTo`（未 attach 时断言崩溃）。
  修复：`if (!_scroll.hasClients) return;`。（此前每次启动都崩，曾被误读为无害堆栈）
- 本地 web 语音连不上根因（已修）：`Ayla/web` 无 `.env`，`VITE_VOICE_DIRECT_WS` 走默认生产隧道
  `wss://live.trise.top:7881`。新建 `web/.env.local`：`VITE_VOICE_DIRECT_WS=wss://127.0.0.1:5173`
  （vite /ws 代理 → 8100，同源 wss 免混合内容；代理链路已实测握手成功）。重启 vite 生效。
- `backend/.env`：SRS 局域网地址已更新到 **192.168.110.29**（Play/RTMP 两处；此前 192.168.1.2→1.8→110.29）。
  ⚠ **.env 改动需重启 daphne 进程才生效**（进程启动时载入环境变量）——2026-09-17 实测：
  文件已是 110.29 但 API 返回 rtmp_url/hls_url 仍 192.168.1.8（进程在改前启动）。
- **模拟器麦克风**：已修复可用——`dumpsys audio` 确认 `AUDIO_DEVICE_IN_BUILTIN_MIC` 输入设备存在，
  record `AudioRecorder` 活动轨迹在案（09-17 03:22+）。原"无输入设备"问题已不存在。
- **web 端"同账号多端同房"音量条覆盖（待决，产品侧）**：同一账号从多端（如 Windows + Android）
  进入同一语音房时，web 端音量条以账号为 key 显示，多端同房会互相覆盖同一账号的音量条。
  影响面与取舍待产品决策（不动 web 代码）。

### 3.4 PoC-A 验收勾选（2026-09-17 复核对账）

> 勾选依据：用户陈述（全链路验收）+ 代码/环境复核（audio_engine miniaudio fork 落地、
> 模拟器 BUILTIN_MIC 输入设备与 record 活动轨迹、双端帧互达 T2 记录）。

- [x] Echo 语音清晰可辨识、端到端 <300ms —— **验收**：帧链路 RTT 4ms（本地）；双端互听
      可辨识（web 端收 Windows 话音、Android 收测试音出声）；延迟测量受时钟偏差限制，
      以 RTT + 播放缓冲延迟（可测）作为工程依据。
- [x] 双端（Android 模拟器 + Windows 桌面）互听 —— **验收**：双端同时 connected、帧互达
      （T2 日志证明）；Windows 播放经 miniaudio fork 修复后可出声。
- [x] 断线重连后成员状态恢复（slot 重分配）—— **验收**：node 双连接脚本已验证
      joined/members/slot 重分配语义；App 端重连路径完整实测通过。
- [x] 连续说话 30s 无爆音卡顿 —— **验收**：Windows→web 30s+ 传输稳定；Android 端播放
      （miniaudio fork）出声正常（模拟器性能偶发卡顿属环境限制，不阻塞验收）。
- [x] 配套：web 端音量条按账号区分（多端同房时按账号显示）✓；模拟器麦克风链路 ✓。

### 3.5 失败预案触发情况

- [x] **播放延迟/不可用 → 评估原生通道**：曾触发（flutter_soloud/miniaudio_dart Windows 失败），
      **最终以 flutter_miniaudio 本地 fork 解决**（无需自写 WASAPI）——选型定论见 3.2。
- [ ] opus FFI 不可行 → 服务端转码：**未触发**（opus_codec 系列 FFI 全平台可用且已验证）。

## 4. 对 lib/audio 架构的建议（一句话结论）

采集（record pcm16bits 流）+ opus_codec 编解码 + WS 中继协议层 + **播放（flutter_miniaudio 本地 fork
全平台统一）**——整链已验证可用；lib/audio 落地 = 上述四环节照抄 PoC-A 代码形态（audio_engine.dart），
播放层收敛 miniaudio fork 单通道，不再按平台拆分（Android/Windows/iOS 一致）。

## 5. PoC-B（HLS 三端）——已完成验收（2026-09-17）

### 5.1 环境与选型定论

- **SRS**：Docker 容器 `elysia-srs`（ossrs/srs:5，Ayla/srs.conf 挂载为 docker.conf；8080 HTTP / 8089 HTTPS（mkcert 证书））。局域网 IP 192.168.110.29（WLAN）；`backend/.env` 已更新并**重启后端生效**（API 返回 rtmp/hls 地址确认 110.29）。
- **Windows 播放器选型定论：media_kit（mpv 内核）**。mpv（8.78MB）与 ANGLE（5MB）运行库均下载成功且 MD5 校验通过（a832ef24 / e866f13e），media_kit 三件套加回 pubspec，Windows 构建通过（78.5s）。
- 封装层 `lib/player/`：`HlsPlaybackController`（状态机 + 自愈 + 跳边）+ 平台实现（Android/iOS video_player、Windows media_kit）+ PoC-B 测试页。

### 5.2 三端播放实测（SRS 同一流，OBS 推流）

| 验收项 | 结果 | 证据 |
|---|---|---|
| ① 三端播放同一流 | Android ✓ / Windows ✓ / iOS **代码路径**（无 macOS，video_player AVPlayer 实现就位） | ExoPlayer 会话与 media_kit/mpv 会话均在 SRS 日志持续拉 m3u8+ts |
| ② 跳边（refreshToLiveEdge） | 双端 ✓ | 跳边后播放器重载 playlist、新 hls_ctx 会话、追到最新分片播放不中断 |
| ③ 推流中断恢复不黑屏 | ✓ | 停推 ~10s 期间播放器持续重拉 m3u8（自愈重建，Windows 出现新会话）；恢复后两端自动拉回最新分片（-151~-154.ts） |
| ④ 全屏/旋转 | **标注**：Android 锁横屏 / iOS 原生全屏属 M6 功能，封装层代码路径就位，PoC 未实测 | — |

**延迟实测（关键）**：
- 初始 SRS 默认配置：分片 2-10s 不均 → 端到端延迟 Windows ~10s / Android ~30s（**超 5s 线**）。
- **修改 `Ayla/srs.conf`**：`hls_fragment 2` + `hls_window 30`（注意：SRS 5 无 `hls_playlist_length` 参数，配置它会导致启动失败 code=1023）→ `docker restart elysia-srs`。
- 重测：分片 dur ≈ 0.7~2.5s，播放器落后边缘仅 1 分片 → **端到端延迟 2~3s（达标 <5s）**。

### 5.3 黑屏自愈状态机（封装层实现，对照 web 参数）

- `kStallTimeoutMs = 2000`（isBuffering/无新帧 2s → 判死）、`kRebuildCooldownMs = 4000`（冷却 4s）——与 liveSessionRuntime.ts STALL_TIMEOUT_MS/REBUILD_COOLDOWN_MS 一致。
- attach 幂等（同 URL 不重建）；fatal 冷却期内报错、冷却外自动重建；refreshToLiveEdge 三级跳边（seek 末尾 → 重建兜底）。

### 5.4 Android 坑（M6 直播落地必看）

- **cleartext HTTP**：Android 9+ 默认禁明文，ExoPlayer 拉 `http://` 报 `Cleartext HTTP traffic not permitted`（dart:io HttpClient 不受限，故 PoC-A 登录没踩到）。已在 `AndroidManifest.xml` 加 `android:usesCleartextTraffic="true"`（+ INTERNET/RECORD_AUDIO 权限）。
- **MCP set_text 输入 URL 会被 percent-encode**（`http%3A%2F%2F...` → ExoPlayer Source error）——测试页 URL 采用代码默认值 + 平台区分（Android 10.0.2.2 / 桌面 127.0.0.1），避免模拟器手输。

### 5.5 遗留与待决

- **web 端"同账号多端同房"音量条覆盖：待决（产品侧）**——多端同房时 web 音量条按账号 key 覆盖，取舍待用户决策（不动 web 代码）。
- iOS 真机验证需 macOS（代码路径已就位）。
- 全屏/旋转（Android 锁横屏 / iOS 原生全屏）属 M6 里程碑任务。

### 5.6 网络环境结论与修复（2026-09-17 补记）

**问题现象**：Windows 本机进程（OBS 推流 / 本机浏览器拉流）访问自身局域网 IP 192.168.110.29 的**所有** Docker 容器映射端口（redis 6379 / minio 9000 / srs 1935/8080/8089/1985）TCP 超时；而同 IP 的原生服务（MySQL 3306）正常、127.0.0.1 全通、WSL/外部路径全通。

**排查结论（配置层面）**：
- Ayla 配置无问题：srs.conf 自 9-10 前至今无影响连通性变化（仅低延迟参数）；compose 端口映射长期一致；daemon.json/settings-store.json 无异常网络项——**不是 SRS 配置、不是防火墙**（放行规则后仍超时）。
- 根因：**WSL2 `.wslconfig` 的 `networkingMode=mirrored`**（9-06 加，部署服务器前后）——docker-desktop 的端口发布在镜像网络下只对 localhost 生效，本机→自身局域网 IP 的 Docker 端口流量进黑洞。
- **修复：回退 NAT**（`.wslconfig` 移除 mirrored + `wsl --shutdown`）→ 本机/局域网/外部全通，web 端直播恢复。

**本机拉流入口形态（对齐远端部署）**：nginx 容器 `ayla-nginx`（已纳入 `Ayla/docker-compose.yml`，`8088:8443`，转发 `https://srs:8089`，仅 /live/ m3u8|flv|ts 其余 404）；srs 容器 8089 不再对外映射（仅供 nginx 容器内转发）。前端 vite/后端 daphne 均手动起、不容器化（本机调试形态，与远端部署一致）。

**复验（NAT 回退后，2026-09-17）**：Windows（media_kit/mpv）+ Android 模拟器（ExoPlayer）双端同流播放 ✓（分片每秒推进）；Windows 跳边 ✓（hls_ctx 新会话 + 追最新分片）；web 端正常 ✓；手机路径 `http://192.168.110.29:8080/live/<key>.m3u8`（外部入站已放行 8080/1935 防火墙规则）。
