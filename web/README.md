# Elysia Web 前端（阶段五 M5-1 基座 + M5-2 聊天界面 + M5-3 语音界面）

React 18 + Vite + TypeScript + Zustand 的 Elysia 多媒体独立应用前端。
M5-1 为工程基座：认证闭环、路由守卫、全局状态、API 客户端、Presence WebSocket、健康检查；
M5-2 为聊天界面：会话列表、聊天窗口、消息渲染、幂等发送、已读/撤回/引用、历史分页、Chat WebSocket、爱莉入口；
M5-3 为语音界面：语音频道（加入/离开/心跳/成员同步）、LiveKit 媒体控制（静音/音量）、爱莉语音控制面闭环。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`；
> 实施步骤见 `../docs/plans/阶段五-M5-1前端基座开发步骤.md`、`阶段五-M5-2聊天界面开发步骤.md`、`阶段五-M5-3语音界面开发步骤.md`。

## 当前里程碑（M5-1，已完成）

- [x] Vite + React 18 + TS 工程脚手架（`web/` 目录）
- [x] 路由（React Router 6）：登录/注册公开；受保护主布局（会话/设置占位）
- [x] 全局状态（Zustand）：auth（token/当前用户）、presence（在线用户）、连接状态
- [x] 认证闭环：注册 → 登录 → JWT 存取与自动刷新 → 登出；401 拦截静默续期 + 重放
- [x] API 客户端（fetch 封装）：自动 Authorization、错误归一（DRF detail/字段错误）、401 刷新互斥锁
- [x] Presence WebSocket：`/ws/presence/?token=<jwt>` 单例连接 + 心跳 + 指数退避重连
- [x] 健康检查接线：`GET /api/v1/health/live/` 启动自检（侧边栏显示后端状态）
- [x] 端到端验收：注册/登录/登出/刷新恢复/回跳/守卫，真实浏览器通过

**不包含（里程碑边界）**：媒体真实发送（M4-3 后端未做，`image/voice/file/emoji` 只渲染占位、发送置灰）、语音（M5-3）、直播（M5-4）、桌游（M5-5）、爱莉集成完整闭环（M5-6，本期仅入口占位）。

## M5-2 聊天界面（已完成）

- [x] 会话列表：私聊（对方昵称/头像/在线状态）+ 群聊（群名）；未读数徽标；`unread_count` + 实时 `message.new` 增量
- [x] 聊天窗口：文本/媒体占位渲染、气泡区分自己/他人、5 分钟时间分组
- [x] 发送：文本输入 + 幂等发送（`idempotency_key`）、回车发送、typing 节流声明（2s）+ 对端"正在输入"
- [x] 已读/撤回/引用：标已读（幂等）；撤回（限时 120s、仅自己）；点击消息 → 引用条 → 发送
- [x] 历史分页：`before_seq` 游标上拉加载更早消息（前插，`<limit` 置 `hasMore=false`）
- [x] Chat WebSocket：`/ws/chat/?token=<jwt>` 单例 + 指数退避重连 + 30s 心跳 + `seq` 幂等补发去重
- [x] 爱莉入口（M5-6 预留）：`GET /elysia/profile/` 存在 `enabled` profile → 会话列表顶部"爱莉"卡 → 走私聊；`elysia.reply` 帧只渲染不生成（AGENTS.md §4.1）
- [x] 演示模式兜底：后端不可达时注入演示会话/消息（界面标"演示模式"），便于无后端查看与调样式
- [x] 契约测试：32 个（message store 分桶/seq 去重、幂等发送、撤回、已读、WS 协议/补发/分发、未读、爱莉入口）

**未验收（需真实 backend + Redis + Elysium）**：两人实时收发、群聊多人、离线补发、断线重连、爱莉真实对话（依赖 M4-4 E2E）。

### Chat WebSocket 协议（与 backend `consumers.py` 对齐）

客户端 → 服务端：

```json
{"type": "subscribe", "conversation_ids": ["1", "2"]}
{"type": "resume", "conversation_id": "1", "last_message_seq": 5}
{"type": "ping", "ts": 123456}
```

服务端 → 客户端：`chat.subscribed`（含各会话 `last_seq`）、`message.new`、`message.recall`、`message.read`、`typing`、`history.sync`（补发完成信号）、`elysia.reply`（爱莉回复投影）、`error`、`pong`。

要点：未认证 `close(4401)`；非成员订阅**忽略**；断线重连后对每个已订阅会话按 `lastSeq` 发 `resume`，服务端补发 `seq > last_seq` 消息（升序），客户端以 `seq` 去重（幂等恢复，不跳尾部）。

### 幂等发送语义

- 前端为每条消息生成 `idempotency_key`（`crypto.randomUUID()`）；发送失败重试**复用同一 key**，服务端幂等返回原消息不重复落库。
- 同 key 但内容/type 不同 → 409，按用户可见"重复提交冲突"提示，不静默丢弃。

### 撤回时限

- `MESSAGE_RECALL_SECONDS=120`（backend settings）；仅自己发、未撤回、120s 窗口内才显示"撤回"按钮。
- 超时（400）→ "超过撤回时限"；越权（403）→ "只有发送者本人可撤回"。

### 爱莉消息边界

- 前端**永不生成爱莉第一人称内容**；爱莉消息文本仅来自 `elysia.reply` / `message.new` 帧的 `content`，前端只渲染。
- `display_name` 仅 UI 展示，绝不写回 Elysium 主体文件（AGENTS.md §4.1）。

### 演示模式

- 登录后若会话/消息接口不可达（如后端未启动），自动注入 `DEMO_CONVERSATIONS` 演示会话与消息，界面顶部显示"演示模式"横幅，方便无后端查看与调样式；后端恢复后刷新即走真实数据。

## M5-3 语音界面（已完成，契约层）

- [x] 频道列表/建频道：`GET/POST /voice/channels/`；卡片显示名称/人数/mine 标记
- [x] 加入/离开：`POST join/` 拿 LiveKit token → `livekit-client` 连房间；`POST leave/` 断开媒体；503（LiveKit 未配置）显式提示"语音服务未配置"，不进入媒体连接
- [x] 通话控制双层：静音 = `localParticipant.setMicrophoneEnabled()`（媒体层，乐观 UI + 失败回滚）；成员音量 = `RemoteAudioTrack.setVolume()`（本地播放偏好，不落库、刷新重置）
- [x] 成员同步：`voice.state`（joined/left/heartbeat/muted）合并 + WS 重连后 `GET members/` 对账（voice.state 无补发语义）
- [x] presence 心跳：在频道期间每 40s `POST heartbeat/`（`VOICE_MEMBER_TIMEOUT_SECONDS` 默认 120s 的 1/3 量级）；403（被超时清理）→ 本地重置未加入态；离开/卸载停止，重复加入不叠加定时器
- [x] 断线恢复双层：应用 WS（voice.state）指数退避重连 + 重 subscribe + 对账；LiveKit 媒体由 SDK 重连，`Reconnecting` → "媒体重连中"（成员面板不清空），`Disconnected` → 提示 + "重新加入"（媒体断线 ≠ 离开频道，不自动 leave/）
- [x] 爱莉语音控制面闭环：`POST /elysia/voice-calls/` 创建/复用（reused=true 正常接入）、文本注入（空文本前端拦截）、`POST .../end/` 幂等结束、`POST .../poll/` 增量转写投影（语音页只显示"已投影 N 条"中性计数，爱莉发言在聊天链渲染，单一渲染源）
- [x] 契约测试：44 个（频道 REST/WS 协议/store 合并/LiveKit 封装/加入离开编排/心跳/爱莉编排）

**未验收（需真实 backend + LiveKit + Elysium）**：双人实时语音互通、静音/音量跨端、断线恢复真实链路、心跳超时清理、爱莉语音 E2E（依赖 M4-5 真实 LiveKit 闭环）。

### 加入流程与心跳节奏

1. `POST join/` → `{token, ws_url, room_name, ttl}`（token 是媒体凭据，不打日志、不跨房间复用）；503 → "语音服务未配置"终止。
2. LiveKit 连接 → 默认关麦加入（避免误入即广播环境音；麦克风权限被拒时保持静音加入并提示）。
3. `GET members/` 铺底 → 启动 40s 心跳 → Voice WS `subscribe [channel_id]`（**必须先 join 成功再 subscribe**：非成员订阅被服务端静默忽略）。
4. 离开：`POST leave/` → 断开 LiveKit → 停心跳 → WS 本地退订（服务端无退订帧）。
5. 异常路径：join 成功但媒体连接失败 → 调 `leave/` 回滚成员状态；心跳 403 → 视为已被移出，本地重置。

### LiveKit 事件映射（livekit/client.ts）

| RoomEvent | store 状态 | UI |
|---|---|---|
| `Reconnecting` | `livekit="reconnecting"` | "媒体重连中…"（成员面板不清空） |
| `Reconnected` | `livekit="connected"` | 恢复 |
| `Disconnected` | `livekit="failed"` | 提示 + "重新加入"（走 join 幂等路径） |
| `TrackMuted/TrackUnmuted` | 成员 muted 标记（媒体事实） | 静音图标以 LiveKit 为准 |

token TTL（默认 600s）到期前 SDK 不断线则无需续签；SDK 报 token 过期断线 → "重新加入"走 `join/` 幂等拿新 token。

### 爱莉语音闭环用法

- 语音页底部"爱莉语音"面板：打开即 `POST /elysia/voice-calls/`（单并发复用 `reused:true` 不报错）；状态每 5s 轮询；文本注入把真人想对爱莉说的话送入 Voice Live；每 10s `POST .../poll/` 触发增量转写投影，爱莉发言出现在聊天页爱莉会话（语音页只显示投影计数）。
- 主体性铁律：前端不生成任何爱莉第一人称内容；`voice.state` 里爱莉的技术状态只渲染中性标签（"通话中/输出中/接收中"），禁止主观化文案。
- 错误语义：profile 未初始化/禁用 → 503；Elysium 侧错误 → 502 "爱莉侧不可用"。

### 已知取舍（M5-3 §9）

- 加入默认关麦；音量不落库（本地偏好，刷新重置）；mute 状态双通道（应用层 `voice.state` 前端不上报，媒体事实以 LiveKit `TrackMuted` 为准）；真人 ↔ 爱莉实时双向音频互通本期不做（M4-5 §5.3 未决点，爱莉语音只到控制面 + 文本注入 + 转写投影）。

## 目录结构

```text
web/
├── package.json
├── vite.config.ts          # React + TS + dev proxy（/api、/ws 代理到后端）
├── tsconfig.json
├── index.html
├── .env.example            # VITE_API_BASE_URL / VITE_WS_BASE_URL
├── .gitignore
└── src/
    ├── main.tsx            # 入口：会话恢复 + Router 挂载 + chat WS 启动
    ├── App.tsx             # 路由表（/chat、/chat/:conversationId）
    ├── api/
    │   ├── client.ts       # fetch 封装：baseURL / Authorization / 错误归一 / 401 刷新重放
    │   ├── auth.ts         # register / login / refresh / me / profile
    │   ├── users.ts        # users/search（M5-2 补实现：搜索用户发起私聊/建群）
    │   ├── chat.ts         # 会话/消息/已读/撤回/typing/群管理 端点（M5-2）
    │   ├── voice.ts        # 语音频道 REST + 爱莉 voice-calls 编排端点（M5-3）
    │   ├── elysia.ts       # 爱莉 profile（M5-2，只读）
    │   ├── health.ts       # health/live 与 health
    │   └── types.ts        # 与 backend 序列化器对齐的 TS 类型（含 M5-2 聊天域、M5-3 语音域）
    ├── stores/
    │   ├── auth.ts         # token / 当前用户 / 登录登出 / 会话恢复
    │   ├── presence.ts     # 在线用户集合 + 连接状态
    │   ├── chat.ts         # 会话列表 + 未读数 + 当前会话（M5-2）
    │   ├── message.ts      # 消息分桶（按 conversation_id，seq 有序去重）（M5-2）
    │   └── voice.ts        # 频道列表 + 当前频道 + 成员表 + LiveKit/WS 状态（M5-3）
    ├── ws/
    │   ├── presence.ts     # /ws/presence/ 单例 + 心跳 + 重连
    │   ├── chat.ts         # /ws/chat/ 单例 + 订阅/补发/重连/事件分发（M5-2）
    │   └── voice.ts        # /ws/voice/ 单例 + subscribe/重连/重订阅/对账钩子（M5-3）
    ├── livekit/
    │   └── client.ts       # livekit-client 薄封装：连接/静音/音量/事件归一（依赖倒置可注入 fake）（M5-3）
    ├── hooks/
    │   ├── useAuth.ts      # 登录/登出/回跳组合封装
    │   ├── useChat.ts      # 打开会话/加载历史/幂等发送/撤回/标已读（M5-2）
    │   ├── useTyping.ts    # typing 节流声明 + 对端 typing 显示（M5-2）
    │   ├── useVoiceChannel.ts  # 加入/离开/心跳/成员同步/断线恢复编排（M5-3）
    │   └── useElysiaVoice.ts   # 爱莉通话生命周期：创建复用/轮询/文本注入/poll/结束（M5-3）
    ├── pages/
    │   ├── LoginPage.tsx
    │   ├── RegisterPage.tsx
    │   ├── ChatPage.tsx    # M5-2 主页面（会话列表 + 聊天窗口，侧栏含语音入口）
    │   ├── VoicePage.tsx   # M5-3 语音主页面（频道列表 + 当前频道面板 + 爱莉语音面板）
    │   └── ProfilePage.tsx
    ├── components/
    │   ├── ProtectedRoute.tsx
    │   ├── chat/           # ConversationList/MessageList/MessageBubble/MessageInput/...（M5-2）
    │   └── voice/          # VoiceChannelList/Create/Panel/MemberRow/Controls/ElysiaVoicePanel（M5-3）
    ├── styles/             # tokens.css / base.css / app.css（含 M5-3 语音组件样式）
    └── vitest/             # 单测 + 契约测试（M5-1: auth/presence/guard/client；M5-2: message-store/chat-store/chat-api/ws-chat；M5-3: voice-api/voice-store/ws-voice/livekit-client/use-voice-channel/use-elysia-voice）
```

## 启动方式

```bash
# 0) 前置：后端已启动（见 backend/README.md）
#    注意：Ayla 后端在 8100 端口启动（8000 被 Elysium 主进程占用）
#    Ayla/backend/.venv/Scripts/python.exe manage.py runserver 127.0.0.1:8100

# 1) 安装依赖
npm install

# 2) 启动 dev server（默认代理到 127.0.0.1:8100）
npm run dev

# 3) 构建
npm run build

# 4) 测试（Vitest：M5-1 auth store / client 401 重放与互斥 / 路由守卫 / presence；M5-2 消息与会话 store / chat API / WS 契约）
npm run test        # 全量（Windows 沙箱建议串行，已默认 --maxWorkers=1 --minWorkers=1）
npm run test:m52    # 仅 M5-2 四个测试文件
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VITE_API_BASE_URL` | 空（走 Vite proxy） | 生产环境 API 根地址，如 `https://app.example.com` |
| `VITE_WS_BASE_URL` | 空（走 Vite proxy，`ws:` 自动） | 生产环境 WS 根地址，如 `wss://app.example.com` |
| `VITE_DEV_PROXY_TARGET` | `http://127.0.0.1:8100` | 仅开发；Vite dev proxy 目标后端地址（Ayla 后端在 8100） |

开发默认同源走 Vite proxy（`/api` → 后端、`/ws` → 后端，`ws: true`），无需 CORS。
后端 `ALLOWED_HOSTS=["*"]` 已放行本地。

## 与后端契约对齐要点

- 用户 `id` 为字符串（UUID），`UserPublic` 字段：`id/username/nickname/avatar/signature/status/online/date_joined`
- JWT：`ROTATE_REFRESH_TOKENS=True` → **每次 refresh 都返回新 refresh，前端必须用返回值覆盖旧值**（已实现）
- Presence WS：`/ws/presence/?token=<jwt>`；服务端推 `presence.update` 增量；`ping`→`pong` 心跳

## 已知取舍（M5-1 决策）

1. **refresh token 持久化**：存 `sessionStorage`（关闭标签页即失效，XSS 面小于 localStorage，刷新页面可恢复会话）。access 只存内存。
2. **样式方案**：本期只做全局 CSS + 最小 CSS 变量，无组件库/设计 token；视觉系统留待 M5-2 或后续统一。
3. **CORS**：本地 dev 走 Vite proxy 同源；若未来前端直连后端域名，需评估在 backend 加 `django-cors-headers`（公共契约变更，先说明再动）。
4. **登录/注册 401**：认证端点标记 `noRetry401`，401 原样归一给页面展示后端错误，不触发刷新重放（避免登录失败误报"登录已过期"）。
5. **Presence 增量**：后端推 `presence.update` 增量帧，前端按 `user_id` 合并/移除（与 backend `consumers.py` 对齐）。
6. **会话恢复**：页面启动时若 `sessionStorage` 有 refresh，先续期拿 access 再拉 `me`，恢复完成前不渲染路由，避免已登录用户闪跳登录页。

### M5-2 决策

7. **测试串行执行**：Windows 沙箱下并发拉起多个 jsdom worker 会触发进程级中止（exit 1 无输出）；`npm run test` 默认 `--maxWorkers=1 --minWorkers=1` 串行执行，全量 58 测试通过。
8. **媒体消息占位**：M4-3 后端未做，`image/voice/file/emoji` 发送按钮置灰，只渲染历史消息占位（图标 + 文本描述）。
9. **未读策略**：未打开会话只记未读数（`unread_count` + 实时 `message.new` 增量），不缓存整段消息（避免内存膨胀）。
10. **已读范围**：私聊必做；群聊后端不广播已读成员列表，前端只显示"我是否读过"。
11. **爱莉会话身份**：爱莉 = profile 绑定的应用内 user，与其私聊即普通私聊；前端靠 `sender_id` 判断是否"爱莉"气泡样式。
12. **演示模式兜底**：后端不可达时注入演示数据，便于无后端查看/调样式；属可观测降级（界面明确标注），不伪造真实数据。
13. **uuid 依赖**：`crypto.randomUUID` 为主，`uuid` 包兜底（非安全上下文/旧浏览器）。
