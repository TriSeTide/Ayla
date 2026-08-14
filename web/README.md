# Elysia Web 前端（阶段五 M5-1 基座 + M5-2 聊天 + M5-3 语音 + M5-4 直播 + 聚合主页 F1/F2）

React 18 + Vite + TypeScript + Zustand 的 Elysia 多媒体独立应用前端。
M5-1 为工程基座：认证闭环、路由守卫、全局状态、API 客户端、Presence WebSocket、健康检查；
M5-2 为聊天界面：会话列表、聊天窗口、消息渲染、幂等发送、已读/撤回/引用、历史分页、Chat WebSocket、爱莉入口；
M5-3 为语音界面：语音频道（加入/离开/心跳/成员同步）、LiveKit 媒体控制（静音/音量）、爱莉语音控制面闭环；
M5-4 为直播界面：直播大厅 + 开播指引（OBS 推流地址一次性回显）+ HLS 播放器 + 实时弹幕（WS + 历史对账）+ 主播面板（:start/:stop）；
F1 为聚合主页基座：AppShell（窄屏 BottomTabs / 宽屏 TopNav）、CreateFAB 随场景创建入口、手势 hook、路由重构（新一级路由 + 旧 /chat 兼容重定向，后随 F10 移除裸 /chat、私聊独立为 PrivateChatPage）；
F2 为窄屏主页 + 宽屏 /home 重定向：群卡片/列表双布局、群动态轮播、布局开关、最近群重定向；
F3 为群聊场景容器：窄屏进群动画（底栏上移）、五子界面滑动、群头像两级点击、群内聊天（复用）、群信息（角色化）、宽屏三列（ServerRail + ChannelSidebar）；
F4 为直播：一级直播聚合 tab（来源标识）、进房动画（底栏下滑走）、上下滑/键盘切换直播间、群内直播（范围仅该群）、FAB 创建直播间；
F5 为语音：一级语音聚合 tab（来源标识）、进房动画（底栏下滑走）、房内打字发群会话、群内语音（范围仅该群）、FAB 建语音房；
F6 为帖子：信息流（游标分页）、帖子详情（评论/收藏/删除）、发帖两条路径（FAB / 群内输入框）、群内帖子；
F7 为桌游：房间框架（列表/创建/进入占位界面）、join/leave 状态、群内桌游（范围仅该群）、FAB 建桌游室；
F8 为消息中心：私信/好友双选项卡、申请处理闭环（好友/群邀请/入群申请）、badges 红点聚合；
F9 为全局搜索：五类分组结果、用户资料卡（加好友/发消息）、历史 chips、宽屏顶栏内联下拉；
F10 为个人界面扩展：三分区（我的发帖/我的直播间/正在玩的桌游）、收藏页（帖子收藏 + 取消）、更多菜单加收藏。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`；
> 实施步骤见 `../docs/plans/阶段五-M5-1前端基座开发步骤.md`、`阶段五-M5-2聊天界面开发步骤.md`、`阶段五-M5-3语音界面开发步骤.md`、`阶段五-M5-4直播界面开发步骤.md`。

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

## M5-4 直播界面（已完成，契约层）

- [x] 直播大厅（`/live`）：频道卡片（标题/主播昵称/状态徽章）；`只看在播`（`?only_live=1`）；爱莉直播间按普通频道渲染（owner 是爱莉 user 时加"爱莉"角标，无特殊数据通道，M5-6 预留）
- [x] 开播指引（`LiveCreate`）：输标题建频道 → 创建响应**一次性回显** `stream_key`/`rtmp_url`（OBS 服务器 + 串流密钥两个复制框，文案"仅本次显示"）；此后仅详情页 owner 可见（契约）
- [x] HLS 播放器（`player/hls.ts` + `LivePlayer`）：`Hls.isSupported()` 分支（hls.js）/ Safari 原生 HLS；fatal networkError → `startLoad()` 重试、mediaError → `recoverMediaError()`、不可恢复 → "播放失败 + 重试"（重试 = 销毁重建）；`muted autoplay` 起播（浏览器自动播放策略）
- [x] 状态三态渲染（状态真实性，AGENTS.md §8）：播放器区域按 `/status/` SRS 实时判定——`live` → 播放器、`idle` → "未开播"占位（乐观已开播但无流 → "等待推流信号…"）、`degraded` → **"直播服务状态未知"中性提示（禁止渲染成"未开播"）**；15s 轮询，页面隐藏暂停（`visibilitychange` 恢复）
- [x] 实时弹幕：WS `danmaku` 帧 + 进房拉最近 50 条历史 + 发送走 REST POST（**成功不乐观插入，等 WS 回帧渲染**——落库与广播分离，单一数据流避免双份）；按 `id` 去重、内存 500 条定长截断；自动滚动 + 上翻时"有新弹幕"提示；纯文本原样渲染（无 `dangerouslySetInnerHTML`）
- [x] 弹幕 WS（`ws/live.ts`）：`/ws/live/<channel_id>/?token=<jwt>` 单例；指数退避重连（1s→30s）+ 30s 心跳；close 码语义：4401 未认证 → "登录已过期"、4404 频道不存在 → "直播间不存在"（均不重连）；重连成功拉历史对账去重（WS 无补发语义）
- [x] 主播面板（`LiveOwnerPanel`，仅 owner）：推流地址复制（服务器/串流密钥/FLV 备选）+ `:start` 开播 / `:stop` 下播 + 删除频道（直播中删除被 400 拦 → "请先下播"）；`:start` 后轮询等待 SRS 识别推流
- [x] 进房/退房编排（`useLiveRoom`）：详情 → `/status/` → 历史弹幕 → 连 WS；退房销毁清单（hls.destroy → 断 WS → 停轮询 → 清 store），重复进房不叠加
- [x] 契约测试：30 个（`live-api` 10：REST/only_live/403/400/degraded 结构；`live-store` 6：去重/合并/定长/三态；`ws-live` 7：连接/心跳/4401/4404/重连对账钩子；`hls-player` 8：分支/恢复/fatal/销毁幂等）；全量 19 文件 132 例全绿 + `npm run build` 通过

**未验收（需真实 backend + SRS + dev server）**：开播闭环（OBS/ffmpeg 推流 → HLS 出画面）、双浏览器弹幕实时互发、断线重连对账真实链路、停 SRS 的 degraded 真实渲染、越权 UI 验证；爱莉直播（FR-19）不验收（依赖 M4-6 §6.3 Elysium 直播意识接入）。

### 直播状态语义（M5-4 核心约束）

| `/status/` 返回值 | 含义 | 播放器区渲染 |
|---|---|---|
| `live` | SRS 检测到真实推流 | video 播放器 |
| `idle` | SRS 未在播（乐观 `status=live` 时显示"等待推流信号…"） | "未开播"占位 |
| `degraded` | SRS 不可用（**不是未在播**） | "直播服务状态未知"中性提示 |
| `null`（未查询） | 首次加载中 | 乐观 `status` 兜底并标注 |

频道 `status` 字段是应用侧**乐观标记**；播放器区域的真实在播判定一律以 `/status/` 为准，乐观标记与 SRS 不一致时以 SRS 为准更新徽章。

### OBS 推流指引（M5-4 §4.5）

1. 大厅「开播」→ 输标题 → 创建成功弹出推流面板（信息仅本次显示，立即复制）：
   - 服务器：`rtmp://<host>:1935/live`（由 `rtmp_url` 去掉末尾流名）
   - 串流密钥：`<stream_key>`（48 位 hex）
2. OBS 设置 → 直播 → 填服务器与串流密钥 → 开始推流。
3. 直播间点「开播」打乐观标记 → 轮询 `/status/` 至 `live`（SRS 识别推流有秒级延迟，UI 显示"等待推流信号…"）→ 播放器出画面。
4. stream_key 安全：仅 owner 可见、不打日志、不持久化（刷新后从详情重新拉）；泄漏则删除频道重建。

### 已知取舍（M5-4 §9）

- **弹幕单一数据流**：发送不做乐观插入，统一等 WS 回帧渲染（~100ms 感知延迟换"绝不双份"）；慢网络下输入框显示"发送中"态。
- **HLS 为主、FLV 可选**：本期播放器只验 HLS（5-15s 延迟属预期，需求 §4.1）；`flv_url` 在主播面板展示供外部播放器使用；要低延迟再引入 flv.js 或评估 WebRTC。
- **状态轮询 15s**：页面隐藏暂停；WS 频道级 `live.status` 事件后端未实现（M4-6 未做），本期轮询兜底。
- **不做在线人数/礼物/录制**：FR-18 可选项本期全部不做（M4-6 边界继承）。
- **爱莉直播 = 普通频道**：owner 是爱莉 user 的频道无特殊数据通道；阶段三 livestream 订阅预留不做（M4-6 §6.3）；FR-19 不验收。
- **muted autoplay**：播放器默认静音起播（浏览器策略），用户点击取消静音；不绕过浏览器限制。

## F1 AppShell + 路由重构（聚合主页基座，已完成）

聚合主页与多端布局增量的第一个前端步骤（见 `../docs/plans/Ayla聚合主页与多端布局开发步骤.md` F1）：响应式外壳 + 导航 chrome + 路由重构，为 F2-F10 各页面提供统一架子。

- [x] `useMediaQuery` hook：matchMedia 订阅 + change 触发重渲染；`NARROW_QUERY = "(max-width: 768px)"` 形态分界（design.md §9）
- [x] `useSwipe` hook：方向锁 / 阈值 / 取消（状态机抽 `createSwipeTracker` 纯函数，单测直驱）；F3 下拉回主页、F4 上下滑、群内横滑复用
- [x] `AppShell`：窄屏（≤768px）= 内容 + BottomTabs + MessageFAB + CreateFAB；宽屏（>768px）= TopNav + 内容 + CreateFAB；直播间沉浸路由（`/live/:channelId`）不渲染 chrome
- [x] `BottomTabs`：五 tab（语音/直播/主页居中凸起/帖子/桌游），主页圆形背板 48px 上浮 8px 选中辉光；badges prop 预留（F8）
- [x] `TopNav`：头像（→个人页）+ 一级模块链（当前模块 2px `--glow-500` 指示条）+ 消息（未读徽标预留）+ 搜索胶囊（回车进 `/search`）+ 更多菜单（个人主页/退出登录，F10 扩展）
- [x] `CreateFAB`：路由匹配表（`shellConfig.resolveFabAction`，需求 §3.5 全表）——主页/语音/直播/帖子/桌游一级创建 + 群内 voice/live/posts/games 创建；聊天/群信息/直播间/消息/搜索/个人页无 FAB；面板 = 场景动作 + 次级「创建群聊」（打开 GroupCreateDialog 建群对话框：群名必填 + 成员可选，F10.2 后不跳 `/chat`）
- [x] 路由重构（`App.tsx`）：`/` → `/home`；新增 `/home /voice /live /live/:id /posts /games /messages /search /profile /group/:id[/:scene]`；受保护页统一挂 AppShell 布局路由；`/chat/:conversationId` 群聊重定向 `/group/:id`、私聊保留（F10 后私聊独立为 PrivateChatPage、裸 `/chat` 移除）；未落地页面渲染 `PlaceholderPage`（标注 F 步骤）
- [x] 契约测试：新增 use-media-query 3 / use-swipe 8 / shell（路由映射 + 双形态 + FAB 面板）/ chat-conversation-route 6；全量 vitest 174 通过 + `npm run build` 通过 + 两形态（375/1440）冒烟通过

**F1 边界**：页面本体（主页群卡片、群聊容器、帖/桌游等）由 F2-F10 落地；F1 仅搭架 + 统一导航 chrome；`/home` 宽屏重定向最近群属 F2，群内进群动画属 F3，进房动画属 F4。

## F2 窄屏主页 + 宽屏 /home 重定向（已完成）

聚合主页增量第二步（见开发步骤文档 F2）：窄屏主页（群聊集合）与宽屏「家」的定位。

- [x] `GroupHighlight` 类型 + `fetchHighlights(ids)`（S6 批量动态封面 `GET /chat/conversations/highlights/?ids=1,2,3`，空 ids 短路不发请求）
- [x] 角标纯函数（`components/home/badges.ts`）：优先级 未读 > 直播 > 语音 > 桌游（R-H5），最多 3 个，未读 99+ 截断；live/voice/game 数据源由 F4/F5/F7 接入
- [x] `GroupCarousel`：横向滑轨 translateX 300ms 滑入、3s 间隔；IntersectionObserver 进视口启停；`prefers-reduced-motion` 静态首帧；无动态回退群头像（64px 带光环）
- [x] `GroupCard`（卡片：封面轮播 + 右上角标列 + 底部群头像群名，点封面开动态 / 点底部进群，避免 button 嵌套）+ `GroupListItem`（行高 64px 玻璃底）+ `LayoutSwitch`（卡片/列表切换）
- [x] `NarrowTopBar`（窄屏一级页顶栏：头像→个人页 / 搜索胶囊→搜索页 / 更多菜单；补齐 F1 窄屏无个人页与搜索入口的缺口，F4-F7 一级 tab 复用）
- [x] `HomePage`：窄屏双布局 + 空态引导（创建/搜索发现群）+ 骨架屏 + 失败重试 + 增量加载更多（R-H6/H9）；宽屏重定向 `/group/<最近群>`（localStorage，无历史取第一个群，无群空态引导）
- [x] `stores/home.ts`：布局偏好 + 最近群持久化（localStorage）
- [x] 契约测试：home-badges 8 + home-store 3 + highlights-api 3 + group-carousel 5 + home-page 7；全量 vitest 200 通过 + `npm run build` 通过 + 两形态冒烟通过

**F2 已知取舍**（步骤文档 §7 登记）：列表布局「最新消息摘要」需后端会话列表补 `last_message` 字段，本期成员数兜底；会话列表后端无分页，「加载更多」为前端增量渲染（每批 12）。

## F3 GroupPage 容器 + 群内聊天（已完成）

聚合主页增量第三步（见开发步骤文档 F3）：把 `/group/:id` 从 F1 桥接版演进为真正的群聊场景容器。

- [x] `stores/group.ts`：`activeScene`（chat/live/voice/posts/games/info）单一状态源 + 五子界面顺序（语音|直播|聊天|帖子|桌游，聊天居中）
- [x] `useEnterGroupAnimation`：进群动画独立封装（底栏上移到顶部，rAF 双帧进入 + reduced-motion 直入）——与 F4 进房动画（底栏下滑走）方向相反，不共用
- [x] `GroupTopTabs`：窄屏上移后的顶部导航条（四 tab + 中央群头像槽位 + 5 圆点指示），原"主页"槽位形变为群头像（R-G1）；F10.2 起接 `pullHandlers` 顶部下拉手势（R-G6）
- [x] 群头像两级点击（R-G4）：单一 handler 读 `activeScene` 分支——非 chat → 切回聊天；chat → 进群信息；无第二份导航状态
- [x] `ServerRail`（宽屏 72px 群头像列 + 当前群 3px 指示条 + 未读角标 + 底部用户卡）+ `ChannelSidebar`（群名头进群信息 + 五场景项），宽屏三列 = 主页本身
- [x] `GroupChat`：复用 MessageList/MessageInput + loadHistory/sendMessage 等（无侧栏/演示数据/爱莉入口）；`GroupInfo`：群资料 + 成员角色标签 + owner/admin 编辑群资料（真功能）+ 管理项占位标注
- [x] `AppShell` 窄屏群场景隐藏 BottomTabs/MessageFAB（GroupPage 自渲染顶部导航条）；`/group/:id/:scene` 由 GroupPage 统一处理（GroupScenePage 移除）
- [x] 契约测试：group-store 4 + use-enter-group-animation 2 + group-page 7 + group-info 3；全量 vitest 216 通过 + build + 两形态冒烟通过

**F3 已知取舍**（步骤文档 §7 登记）：退出群/转让群主/解散群后端无端点（群信息占位标注）；五子界面滑动 = 手势触发 navigate + key 切换淡入（开发文档 §2.2 明确用 CSS transition）；下拉回主页手势（R-G6）与输入框滑入延迟动画随 F10.2 补齐。

## F4 直播：一级 tab + 群内直播（已完成）

聚合主页增量第四步（见开发步骤文档 F4）：在 M5-4 已验证的直播能力上补多端布局增量。

- [x] `LiveChannelDescriptor` 加 `visibility`/`group`/`group_name`（S1 可见性/群归属，来源标识数据）；`createLiveChannel(title, group)` 支持群归属
- [x] `useEnterRoomAnimation`：进房动画输入框滑入（100ms 延迟）——与 F3 进群动画方向相反，不共用
- [x] `stores/shell.ts`：`bottomTabsLeaving` 跨路由状态，AppShell 据此驱动窄屏直播间底栏**下滑走**（translateY 0→100%，200ms ease-in，R-L2）；`BottomTabs` 直播间时 `data-fixed` 脱离 flex 流
- [x] `LiveRoomBody`（抽核心复用）：播放器三态 + 弹幕列表/输入 + 切换控件（窄屏上下滑 useSwipe / 宽屏两侧按钮 + 键盘 ↑↓）+ 弹幕输入框滑入
- [x] `LiveRoomPage`：进房底栏下滑走 + 全量列表切换 navigate `/live/:nextId`（HLS 靠 channelId 变化重进房）
- [x] `GroupLive`：群内直播子界面，切换范围 = **仅该群**（filter group）；无直播空态 + 发起引导
- [x] `LiveHubPage`（改造 LiveHallPage）：聚合网格（窄屏 2 列 / 宽屏 3-4 列）+ 来源标识（公开/好友/群名）+ 空态
- [x] `CreateFab`：`handler="live"` 接线 `LiveCreate`（一级公开 / 群内归属该群），创建后跳直播间/群内直播
- [x] 契约测试：use-enter-room-animation 2 + group-live 范围 2；全量 vitest 220 通过 + build + 两形态冒烟通过

**F4 已知取舍**（步骤文档 §7 登记）：窄屏弹幕"浮层"沿用 M5-4 底部浮层（覆盖播放器下部）而非重构全屏沉浸视频层。

## F5 语音：一级 tab + 群内语音（已完成）

聚合主页增量第五步（见开发步骤文档 F5）：在 M5-3 已验证语音能力上补多端布局增量。

- [x] `VoiceChannelDescriptor` 加 `visibility`/`group`/`group_name`（S1）；`createVoiceChannel(name, group)` 群归属
- [x] `AppShell` 底栏下滑走改为 `bottomTabsLeaving` 通用驱动（直播/语音房共用，移除 isLiveRoomRoute 判断）
- [x] `VoiceRoomBody`：语音房整页（返回头 + 复用 VoiceChannelPanel 成员/控制排 + 房内打字发群会话，仅群语音房 group 非空显示）
- [x] `VoiceHubPage`（改造 VoicePage）：聚合卡片 + 来源标识 + 空态 + 进房底栏下滑走 + 输入框滑入
- [x] `GroupVoice`：群内语音房范围 = 仅该群（filter group）+ 空态；`GroupPage` voice 子界面接入
- [x] `CreateFab` `handler="voice"` 接 `VoiceChannelCreate`（群内归属）；`VoiceChannelList` 加来源标识
- [x] 契约测试：group-voice 范围 2 + voice-room-body 房内打字 2；全量 vitest 224 通过 + build + 两形态冒烟通过

**F5 已知取舍**（步骤文档 §7 登记）：进房动画与房内打字送达群消息的端到端验证依赖真实 LiveKit（冒烟未覆盖），UI 结构与发送路径由单测覆盖；公开语音房无独立文字流（B10 后置），打字框仅群语音房显示。

## F6 帖子全套（已完成）

聚合主页增量第六步（见开发步骤文档 F6）：信息流 + 详情 + 发帖两条路径。

- [x] `api/posts.ts`（listPosts 游标分页 scope/cursor/limit、createPost/getPost/updatePost/deletePost、评论增删）+ `api/favorites.ts`（listFavorites/addFavorite/removeFavorite 幂等）
- [x] `stores/posts.ts`：信息流游标分页（appendPage 去重）+ `favoriteByPostId` 收藏集合（列表/详情共享收藏态）
- [x] `PostCard`（作者光环 + 正文 3 行折叠 + 九宫格 + 底排评论/IconHeart 收藏）、`PostEditor`（标题可选 + 正文必填 + compact 群内变体）、`CommentList`（评论 + 回复 + 评论作者删）
- [x] `usePostDetailTransition`：帖子详情底栏原位替换输入框（交叉淡化无位移，区别于进群上移/进房下滑）
- [x] `PostsHubPage`（信息流 + 滚到底加载更多 + 收藏即时反馈）、`PostDetailPage`（评论 + 收藏 + 删除二次确认）、`GroupPosts`（群内信息流 + 输入框发帖）
- [x] `AppShell` 帖子详情窄屏让位评论输入框；`CreateFab` `handler="post"` 接 PostEditor；群内 posts 子界面 FAB 隐藏（发帖走输入框）
- [x] 契约测试：posts-store 5 + posts-api 4；全量 vitest 232 通过 + build + 两形态冒烟通过

**F6 已知取舍**（步骤文档 §7 登记）：发帖带图（媒体三步上传前端链路）后置，本期 PostEditor 仅文本；个人页"我的发帖"归 F10。

## F7 桌游房间框架（已完成）

聚合主页增量第七步（见开发步骤文档 F7）：房间框架（玩法引擎与 WS 对局通道后续）。

- [x] `api/boardgame.ts`：listGameRooms（`?mine=1` F10 数据源）、createGameRoom、getGameRoom、deleteGameRoom、joinGameRoom（`:join` 幂等）、leaveGameRoom（`:leave`）
- [x] `GameRoomCard`（封面占位 + 状态 tag 等待中/对局中 + 人数 + 来源标识）、`GameRoomCreate`（房间名必填 + group）、`GameRoomPlaceholder`（进入占位 + join/leave 状态切换）
- [x] `GamesHubPage`（列表 + 空态 + 进入占位闭环）、`GroupGames`（群内范围 filter group）
- [x] `GroupPage` games 子界面接入；`CreateFab` `handler="game"` 接 GameRoomCreate
- [x] 契约测试：boardgame-api 5；全量 vitest 237 通过 + build + 两形态冒烟通过

**说明**：桌游玩法本体与 WS 对局通道后续；"正在玩的桌游"个人页数据源 = `GET /rooms/?mine=1`（F10 接入）。

## F8 消息中心 + badges 红点（已完成）

聚合主页增量第八步（见开发步骤文档 F8）：全站未读聚合与申请审批。

- [x] `api/accounts.ts` `getBadges`（`GET /me/badges/` 五维聚合）；`api/chat.ts` 扩展 listJoinRequests/actionJoinRequest/listMyInvites/actionGroupInvite（S2）
- [x] `stores/badges.ts`：`messageBadge` 聚合（私信未读 + 好友申请 + 群邀请 + 待审批入群申请，群未读不进消息中心红点）
- [x] `MessagesPage`：私信/好友双选项卡 + 三组申请置顶（好友申请/群邀请/待审批入群申请）+ 同意/拒绝即时反馈 + 宽屏双栏
- [x] `AppShell` 进入拉 badges + 30s 轮询（断线降级）+ MessageFab/TopNav 消息项红点
- [x] 契约测试：badges-store 4；全量 vitest 241 通过 + build + 两形态冒烟通过

**说明**：红点实时推送（S2 WS 用户级广播 group.request.resolved/group.invite.new）接线后置，30s 轮询 + 处理 action 后即时 fetch 已覆盖"随处理即时刷新"验收。

## F9 全局搜索（已完成）

聚合主页增量第九步（见开发步骤文档 F9）：聚合搜索（只读，后端已完成可见性过滤）。

- [x] `api/search.ts`：`GET /search/?q=&types=&limit=` 五类分组（user/group/post/live/game，每组 items+total）
- [x] `stores/search.ts`：搜索历史 chips（localStorage 去重栈 + 上限 10 + 清空）
- [x] `UserProfileCard`：用户资料卡（加好友发起申请 + 发消息进私聊）
- [x] `SearchPage`：搜索输入（自动聚焦）+ 历史 chips + 五类分组 + 点用户弹资料卡、其余跳对应界面
- [x] `TopNav` 内联搜索下拉（去抖 300ms，分组前几条，点击跳转）；删除无引用的 PlaceholderPage
- [x] 契约测试：search-store 4 + search-api 3；全量 vitest 248 通过 + build + 两形态冒烟通过

**F9 已知取舍**（步骤文档 §7 登记）：用户资料卡"好友关系状态展示"后置；桌游室搜索结果跳 /games 列表。

## F10 个人界面扩展 + 收藏页 + 更多菜单（已完成）

聚合主页增量第十步（见开发步骤文档 F10）：F1-F10 前端全部落地。

- [x] `FavoritesPage`：帖子收藏列表（target 摘要直接展示）+ 取消收藏即时移除 + 同步 posts store 收藏集合
- [x] `ProfilePage` 扩展三分区：我的发帖（scope=mine）/ 我的直播间（owner=我）/ 正在玩的桌游（?mine=1）
- [x] `TopNav` / `NarrowTopBar` 更多菜单加「我的收藏」（三项：个人主页 / 我的收藏 / 退出登录）
- [x] 契约测试：favorites-page 3；全量 vitest 251 通过 + build + 两形态冒烟通过

## F10.1/F10.2 删除聚合聊天页 + 建群表单 + 下拉返回主页（已完成）

- [x] **F10.1 拆分私聊/群聊**：删除 `ChatPage`（聚合聊天页）与裸 `/chat`；`PrivateChatPage` 独立私聊窗口；`ChatConversationRoute` 私聊→PrivateChatPage、群聊→`/group/:id`
- [x] **F10.2 建群表单**（R-F3 最小集）：`GroupCreateDialog` 直接建群表单（群名必填 + 成员搜索可选 + 点「私聊」发起会话）；`shellConfig.resolveFabAction("/home")` 补 `handler:"group"`；`CreateFab` 主页 FAB 打开建群对话框（不再提示落步骤）
- [x] **F10.2 下拉返回主页**（R-G6）：`GroupTopTabs` 接 `pullHandlers`；`GroupPage` 顶部导航条下拉手势（跟手 translateY + 阈值 80px + 退场动画 250ms）+ `navigate("/home")`；`tokens.css` 补 `--ease-in`
- [x] 契约测试：shell 3（新增主页 FAB 建群）+ group-page 2（下拉过/未过阈值）；全量 vitest 253 通过 + build + 两形态冒烟通过

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
    ├── App.tsx             # 路由表（/home /voice /live /posts /games /messages /search /profile /group/:id[/*] + /chat/:conversationId 私聊/群聊分流；裸 /chat 已移除）
    ├── layout/             # F1/F2/F3：AppShell / BottomTabs / TopNav / CreateFab / MessageFab / NarrowTopBar / ServerRail / ChannelSidebar / shellConfig（路由匹配表）
    ├── api/
    │   ├── client.ts       # fetch 封装：baseURL / Authorization / 错误归一 / 401 刷新重放
    │   ├── auth.ts         # register / login / refresh / me / profile
    │   ├── users.ts        # users/search（M5-2 补实现：搜索用户发起私聊/建群）
    │   ├── chat.ts         # 会话/消息/已读/撤回/typing/群管理 端点（M5-2）
    │   ├── voice.ts        # 语音频道 REST + 爱莉 voice-calls 编排端点（M5-3）
    │   ├── live.ts         # 直播频道/状态/弹幕端点（M5-4）
    │   ├── posts.ts        # 帖子信息流/详情/评论端点（F6）
    │   ├── boardgame.ts    # 桌游室 CRUD + join/leave 端点（F7）
    │   ├── accounts.ts     # badges 全站未读聚合端点（F8）
    │   ├── search.ts       # 聚合搜索端点（F9）
    │   ├── favorites.ts    # 收藏端点（F6/F10）
    │   ├── elysia.ts       # 爱莉 profile（M5-2，只读）
    │   ├── health.ts       # health/live 与 health
    │   └── types.ts        # 与 backend 序列化器对齐的 TS 类型（含 M5-2 聊天域、M5-3 语音域、M5-4 直播域）
    ├── stores/
    │   ├── auth.ts         # token / 当前用户 / 登录登出 / 会话恢复
    │   ├── presence.ts     # 在线用户集合 + 连接状态
    │   ├── chat.ts         # 会话列表 + 未读数 + 当前会话（M5-2）
    │   ├── message.ts      # 消息分桶（按 conversation_id，seq 有序去重）（M5-2）
    │   ├── voice.ts        # 频道列表 + 当前频道 + 成员表 + LiveKit/WS 状态（M5-3）
    │   ├── live.ts         # 频道列表 + 当前直播间（详情/SRS 状态/弹幕去重定长）+ WS 状态（M5-4）
    │   ├── home.ts         # F2：主页布局偏好 + 最近访问群持久化（localStorage）
    │   ├── group.ts        # F3：activeScene（群内子场景单一状态源）+ currentGroupId
    │   ├── shell.ts        # F4：bottomTabsLeaving（窄屏直播间底栏下滑走跨路由动画）
    │   ├── posts.ts        # F6：信息流游标分页 + 收藏集合
    │   ├── badges.ts       # F8：全站未读聚合 + messageBadge 红点
    │   └── search.ts       # F9：搜索历史记录（localStorage）
    ├── ws/
    │   ├── presence.ts     # /ws/presence/ 单例 + 心跳 + 重连
    │   ├── chat.ts         # /ws/chat/ 单例 + 订阅/补发/重连/事件分发（M5-2）
    │   ├── voice.ts        # /ws/voice/ 单例 + subscribe/重连/重订阅/对账钩子（M5-3）
    │   └── live.ts         # /ws/live/<id>/ 单例 + 4401/4404 语义 + 重连对账钩子（M5-4）
    ├── livekit/
    │   └── client.ts       # livekit-client 薄封装：连接/静音/音量/事件归一（依赖倒置可注入 fake）（M5-3）
    ├── player/
    │   └── hls.ts          # hls.js 薄封装：isSupported 分支/错误恢复/销毁幂等（M5-4）
    ├── hooks/
    │   ├── useAuth.ts      # 登录/登出/回跳组合封装
    │   ├── useChat.ts      # 打开会话/加载历史/幂等发送/撤回/标已读（M5-2）
    │   ├── useTyping.ts    # typing 节流声明 + 对端 typing 显示（M5-2）
    │   ├── useMediaQuery.ts    # 响应式断点（F1，matchMedia 订阅）
    │   ├── useSwipe.ts     # 手势：方向锁/阈值/取消（F1）
    │   ├── useEnterGroupAnimation.ts # 进群动画：底栏上移到顶部（F3，独立封装）
    │   ├── useEnterRoomAnimation.ts  # 进房动画：输入框滑入（F4，与进群反方向）
    │   ├── usePostDetailTransition.ts # 帖子详情：底栏原位替换输入框（F6，交叉淡化）
    │   ├── useVoiceChannel.ts  # 加入/离开/心跳/成员同步/断线恢复编排（M5-3）
    │   ├── useElysiaVoice.ts   # 爱莉通话生命周期：创建复用/轮询/文本注入/poll/结束（M5-3）
    │   ├── useLiveRoom.ts  # 进房/退房编排：详情+状态轮询+WS+历史+销毁清单（M5-4）
    │   └── useDanmaku.ts   # 弹幕发送（等回帧）/接收/去重/滚动策略（M5-4）
    ├── pages/
    │   ├── LoginPage.tsx
    │   ├── RegisterPage.tsx
    │   ├── PrivateChatPage.tsx # 私聊窗口（头部 + 消息列表 + 输入框；群聊不再走 /chat/:id）
    │   ├── VoiceHubPage.tsx # F5 一级语音聚合（卡片 + 来源标识）
    │   ├── LiveHubPage.tsx     # F4 一级直播聚合（网格 + 来源标识）
    │   ├── LiveRoomPage.tsx    # M5-4 直播间（路由 /live/:channelId）
    │   ├── GamesHubPage.tsx    # F7 一级桌游（列表 + 进入占位）
    │   ├── MessagesPage.tsx    # F8 消息中心（私信/好友双选项卡 + 申请审批）
    │   ├── SearchPage.tsx      # F9 全局搜索（五类分组 + 用户资料卡）
    │   ├── FavoritesPage.tsx   # F10 收藏页（帖子收藏 + 取消）
    │   ├── ProfilePage.tsx
    │   ├── HomePage.tsx     # F2 窄屏主页（群卡片/列表双布局 + 宽屏 /home 重定向最近群）
    │   ├── PostsHubPage.tsx     # F6 一级帖子信息流（游标分页 + FAB 发帖）
    │   ├── PostDetailPage.tsx   # F6 帖子详情（评论/收藏/删除）
    │   ├── GroupPage.tsx           # F3 群聊场景容器（窄屏进群动画/五子界面/两级点击；宽屏三列）
    │   ├── ChatConversationRoute.tsx # /chat/:id：私聊 → PrivateChatPage、群聊 → /group/:id；裸 /chat 已移除
    │   └── group/           # F3-F7：GroupChat / GroupInfo / GroupLive / GroupVoice / GroupPosts / GroupGames / GroupScenePlaceholder
    ├── components/
    │   ├── ProtectedRoute.tsx
    │   ├── UserProfileCard.tsx  # F9 用户资料卡（加好友/发消息）
    │   ├── chat/           # ConversationList/MessageList/MessageBubble/MessageInput/...（M5-2）
    │   ├── voice/          # VoiceChannelList/Create/Panel/MemberRow/Controls/VoiceRoomBody/ElysiaVoicePanel（M5-3 + F5）
    │   ├── live/           # LiveHall/LiveCreate/LivePlayer/LiveRoomBody/DanmakuList/DanmakuInput/LiveOwnerPanel（M5-4 + F4）
    │   ├── home/           # F2：GroupCard/GroupListItem/GroupCarousel/LayoutSwitch/badges（角标纯函数）
    │   ├── group/          # F3：GroupTopTabs（窄屏上移导航条）
    │   ├── posts/          # F6：PostCard/PostEditor/CommentList
    │   └── boardgame/      # F7：GameRoomCard/GameRoomCreate/GameRoomPlaceholder
    ├── styles/             # tokens.css / base.css / app.css（M5-2..M5-4）/ shell.css（F1）/ home.css（F2）/ group.css（F3）/ live.css（F4）/ voice.css（F5）/ posts.css（F6）/ boardgame.css（F7）/ messages.css（F8）/ search.css（F9）/ profile.css（F10）
    └── vitest/             # 单测 + 契约测试（M5-1..M5-4；直播：live-api/live-store/ws-live/hls-player）
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

# 4) 测试（Vitest：M5-1 auth store / client 401 重放与互斥 / 路由守卫 / presence；M5-2 消息与会话 store / chat API / WS 契约；M5-3 语音 store/WS/LiveKit；M5-4 直播 API/store/WS/HLS）
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
