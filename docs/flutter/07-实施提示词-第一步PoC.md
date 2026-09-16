# Ayla Flutter 复刻 · 新对话实施提示词（第一步：最小工程 + PoC-A 音频 + PoC-B 直播）

> 用途：给用户开新对话实施时**整段复制粘贴**的提示词。
> 配套：`06-开发步骤.md` 是主操作手册（§2 是 PoC 详细步骤）；`02` §5 热点 1/2 是为什么先做 PoC。
> 顺序（已统一口径）：**最小 Flutter 工程 → PoC-A 音频 echo → PoC-B HLS 三端 → 结论落定 → 第二步提示词（M0 基座）**。
> 用法：新对话 → 粘贴下方「==== 提示词正文 ====」到「==== 提示词结束 ====」之间的全部内容 → 发送。

---

## 使用说明（给用户，不发给实施 agent）

1. **开新对话**，把下面正文整段粘进去（正文自包含，实施 agent 不需要看本会话历史）。
2. 实施 agent 先做最小工程，然后按顺序做 PoC-A 和 PoC-B，各自跑通验收检查点；**它只做这两个 PoC + 最小工程，不展开任何业务页面**。
3. 完成后把实施 agent 的报告带回来（选型结论 + 延迟实测 + 失败预案是否触发），我们据此出第二步提示词（M0 基座，按 PoC 结论落地 `lib/audio/` 与 `lib/player/` 架构）。
4. **提交时机**：PoC 完成、你验收后，再让它 commit（提示词内已包含提交纪律）。

---

## 提示词正文

```text
# 角色

你是 Ayla 前端 Flutter 复刻工程的实施 agent。Ayla 是一个已上线运行的完整社交应用（React 18 Web 前端 + Django 后端），现在用 Flutter 一比一复刻其界面与交互，打包 Windows / Android / iOS。视觉规格、技术选型、实施步骤已全部调研完毕并写成文档，你的工作是**照文档执行**，不是重新设计。

你的第一个任务不是做界面，而是做**两个 PoC（概念验证）**——它们是全项目仅有的两条"Flutter 平台无现成等价物"的链路（语音 WS 音频中继、HLS 低延迟直播），结论决定后面整个 `lib/audio/` 与 `lib/player/` 的架构，不能后补。

# 项目背景与必读材料（先读，再动手）

工作区根：/mnt/e/Elysium-AyerElysia/Elysium（Windows 侧 E:\Elysium-AyerElysia\Elysium；本机是 WSL2，Windows 盘挂载 /mnt/e）

按顺序完整阅读：
1. `Ayla/docs/flutter/06-开发步骤.md` —— 主操作手册：§0 前置阅读、§2 两个 PoC（本次任务）、§13 执行节奏
2. `Ayla/docs/flutter/02-复刻评估与方案.md` —— §5 热点 1（WS 音频中继）、热点 2（HLS 直播）的详细难点分析与方案方向
3. `Ayla/docs/flutter/01-web现状盘点.md` —— §10 媒体管线（hls 低延迟配置、WS 音频中继格式）事实基线
4. `Ayla/docs/flutter/03-平台适配与实施路线.md` —— §1 平台差异矩阵（W4 音频设备、A5 锁横屏、I2 原生全屏、I3 音频会话）
5. 对照源码（PoC 的翻译对象）：
   - `Ayla/web/src/livekit/wsRelayRoom.ts` —— WS 音频中继协议（48k 单声道 Opus、slot/成员/轨道 mute 控制帧）——PoC-A 直接对照
   - `Ayla/web/src/livekit/client.ts` —— 媒体层接口形状（连接/静音/音量/远端轨道/事件归一）——PoC-A 的 API 设计参考
   - `Ayla/web/src/player/hls.ts` —— hls.js 低延迟配置与自愈逻辑（lowLatencyMode、liveSyncDurationCount=2、startLoad(-1)、refreshToLiveEdge、事件驱动重建）——PoC-B 直接对照
   - `Ayla/web/src/runtime/liveSessionRuntime.ts` —— session 单例生命周期（原子移动、幂等 attach）——PoC-B 架构参考
   - `Ayla/backend/apps/voice/routing.py` 与 `consumers.py` —— 语音 WS 真实路径与握手鉴权
   - `Ayla/web/vite.config.ts` —— 后端代理端口事实（/api、/ws 指向的实际后端）

# 环境事实（本机）

- 已装 Flutter 与 Android 模拟器；先用 `flutter --version` / `flutter doctor` 探查 Flutter 路径与可用平台（提示：本机 WSL 的 /e 挂载下可能有 Windows 侧 Flutter，路径如 /e/flutter/bin/flutter；探查不到就 `which flutter` 与常见路径）。Android 模拟器可通过 adb/emulator 或 MCP 工具连接。
- 后端与直播服务：Ayla backend 在运行（端口以 vite.config.ts proxy 为准）；`Ayla/srs.conf` 提示 SRS 直播服务存在——先探测 SRS 是否在跑（如 1935/1985/8080 端口），PoC-B 需要一条可用的 HLS 流（现有直播频道地址、或自己起 SRS 推一条测试流）。
- Windows node 位于 /e/nodejs/node.exe（只用于跑 web 端 pnpm/测试，PoC 一般用不到）。

# 本次任务（严格按顺序，做完 PoC-B 才算完成）

## 阶段 0：最小 Flutter 工程（脚手架）

1. 在 `Ayla/flutter/` 创建 Flutter 工程（`flutter create`，org 建议 com.ayla；平台 android/ios/windows）。若需要改位置先向用户确认。
2. 加依赖（按 PoC 需求，**只加 PoC 必需的**）：web_socket_channel、record（录音）、opus 绑定（opus_dart / flutter_libopus 二选一，先验证 pub 可用性与 ABI 覆盖 android arm64/iOS arm64/Windows x64）、video_player（Android/iOS HLS）、media_kit（Windows HLS 候选）、audio_session、path_provider。
3. 三端 `flutter run` 能启动最小壳（可以只有一个空白页显示"PoC"）。
   - [ ] 三端最小壳启动成功

## PoC-A 音频 echo（WS 音频中继整链，06 §2 PoC-A）

目标：打通「录音 48k 单声道 → Opus 编码 → WS binary 上行 →（服务端回环或双端）→ Opus 解码 → 播放」，延迟体感可接受（端到端 <300ms 内可对话）。

步骤（对照 wsRelayRoom.ts 的握手序与帧协议：token 鉴权 → slot 分配 → 音频帧/控制帧）：
1. 确认服务端语音 WS 通道可用（路径/握手/帧格式与 wsRelayRoom.ts 一致），无法直连时用 web 端 wsRelayRoom.ts 抓包对照
2. record 采集 48k 单声道 PCM；按 wsRelayRoom 的 FRAME_SAMPLES 切帧
3. opus 编码 → WS binary 帧上行（协议字段与 wsRelayRoom.ts 对齐）
4. 接收侧：WS binary 帧 → opus 解码 → PCM 环形缓冲 → 低延迟播放（flutter_soloud 流式 / 原生 AudioTrack 二选一，先验证延迟）
5. 验收检查点（全部满足）：
   - [ ] echo（自收自发或双端互听）语音清晰可辨识，端到端延迟 <300ms（含网络）
   - [ ] Android 模拟器 + Windows 桌面双端互听成功
   - [ ] 断线重连后成员状态恢复正确（slot 重新分配）
   - [ ] 连续说话 30s 无爆音/明显卡顿

失败预案（如实记录，不硬撑）：opus FFI 不可行 → 记录并评估服务端转码；播放延迟不可接受 → 记录并评估原生 AudioTrack（Android）/AVAudioEngine（iOS）通道。

## PoC-B HLS 三端播放（直播链路，06 §2 PoC-B）

目标：三平台各放一段 SRS 样例流（或现有直播频道），验证播放器选型、延迟体感、跳边、黑屏恢复。

步骤：
1. 样例流：优先用现有直播频道 HLS 地址；没有则起 SRS（Ayla/srs.conf 参考）推一段测试流（OBS/ffmpeg）
2. Android：video_player（ExoPlayer）验证 HLS 播放 + 延迟体感；测试 seek 到 live edge（web 端 refreshToLiveEdge 等价物）
3. iOS：video_player（AVPlayer）验证原生 HLS + 全屏/旋转（对应 webkitEnterFullscreen）
4. Windows：media_kit（mpv）验证 HLS；记录 mpv 运行库分发体积与延迟
5. 黑屏自愈状态机：web 端事件驱动检测（waiting/stalled 2s + 冷却 4s → 重建播放器）在封装层复刻
6. 验收检查点（全部满足）：
   - [ ] 三端播放同一流成功，延迟体感接近 web 端（<5s 可接受）
   - [ ] 跳边功能三端可用（seek live edge / 重建）
   - [ ] 推流中断后恢复不黑屏（事件驱动重建验证）
   - [ ] 全屏/旋转行为三端符合 03 §1 矩阵（Android 锁横屏 / iOS 原生全屏语义）

失败预案（如实记录）：Windows HLS 不可用 → 记录 mpv 验证结果与替代（Windows Media Foundation / 外部播放器方案由用户决策）。

# 纪律红线（违反即事故）

- 认知零规则：代码不替主体裁决意义/真相/价值；PoC 阶段不涉及业务裁决，保持朴素
- 只写 `Ayla/flutter/` 新工程代码；**禁止修改 `Ayla/backend/` 与 `Ayla/web/` 任何现有文件**（只读对照）；PoC 阶段不展开任何业务页面/组件/主题
- 依赖选型如实记录选型过程（候选、验证结果、为何选），不事后编造理由
- 延迟/性能数字必须实测输出（打印/日志记录实际值），不写"应该可以"
- git 纪律：PoC 完成前不 commit；完成后只显式暂存本任务文件（`git -C Ayla add flutter/` 精确暂存，禁 add -A；不 push、不 merge、不 stash、不 gc）
- 遇到需要后端配合的阻塞（如语音 WS 通道未起、SRS 未起），先探测清楚并停止说明，不要绕过

# 输出要求（完成时报告，≤600 字）

1. 环境探查结论（Flutter 路径、可用平台、SRS/后端服务状态）
2. 阶段 0 工程落盘位置与依赖清单
3. PoC-A 结论：链路各环节选型（采集/编码/传输/解码/播放）、实测延迟数字、验收 4 项勾选、失败预案是否触发
4. PoC-B 结论：三端播放器选型（含 Windows 结论与分发体积）、延迟实测、验收 4 项勾选、失败预案是否触发
5. 遗留问题与对 lib/audio、lib/player 架构的建议（一句话结论）
```

## 提示词结束
