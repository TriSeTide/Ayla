# Ayla Web 前端现状盘点（Flutter 复刻调研 · 01）

> 调研日期：2026-09-16
> 调研方式：磁盘实测（源码统计探针）+ 源码阅读（路由表/API 客户端/WS 协议/设计规范）
> 用途：为「Flutter 一比一复刻 Ayla Web 前端，打包 Windows/Android/iOS」提供事实基线
> 配套文档：`02-复刻评估与方案.md`、`03-平台适配与实施路线.md`

## 1. 调研范围

- **前端**：`Ayla/web/`（React 18 + Vite 5 + TypeScript + Zustand），源码 `web/src/`
- **后端（只读盘点，只评估对接面）**：`Ayla/backend/`（Django + DRF + SimpleJWT + MySQL + Redis + 对象存储 + SRS）
- **设计规范**：`Ayla/docs/design.md`（714 行，唯一视觉事实源）
- **不覆盖**：后端自身改造、部署运维细节、桌游玩法实现（前端为占位）

## 2. 项目结构速览

```text
Ayla/
├── backend/        # Django 后端（12 apps：accounts/boardgame/chat/common/elysia_bridge/
│                   #   emoji/favorites/live/media/posts/search/voice）
├── web/            # 本次调研主体：React 前端（src/ 406 文件）
├── docs/           # 设计规范 design.md + 阶段计划 + 架构文档 + 验收报告
└── certs/          # 本地开发 HTTPS 证书
```

## 3. 前端技术栈与依赖（web/package.json）

| 类别 | 技术 | 版本 | 说明 |
|---|---|---|---|
| 框架 | React | 18.3.1 | 函数组件 + hooks，无类组件 |
| 构建 | Vite | 5.4.8 | dev 5173 HTTPS + proxy（/api、/ws、/minio、/livekit） |
| 语言 | TypeScript | 5.6.2 | `tsc -b` 编译 |
| 路由 | react-router-dom | 6.26.2 | BrowserRouter，全部同步导入不懒加载 |
| 状态 | Zustand | 4.5.5 | 22 个 store |
| 动效 | framer-motion | 13.1.1 | 仅接管跟手/进出协同/编排三类能力 |
| 直播 | hls.js | 1.7.0 | 低延迟直播播放 |
| 其他 | uuid | 9.0.1 | |

**关键结论**：无 UI 组件库、无 Tailwind——全部界面为手写 React 组件 + 全局 CSS（19 个 css 文件，token 统一在 `styles/tokens.css` CSS 变量）。复刻时没有"组件库迁移"负担，全部视觉组件需 1:1 重写。

## 4. 源码规模统计（磁盘实测）

> 统计方法：递归遍历 `web/src/`，`vitest/` 测试文件单独计入 tests。
> 实测命令输出：`{"total":406,"byExt":{"tsx":227,"ts":160,"css":19},"pages":27,"components":85,"stores":22,"hooks":37,"api":19,"ws":4,"styles":19,"utils":11,"tests":154}`

| 项目 | 数量 | 说明 |
|---|---|---|
| 总文件 | `total=406` | tsx=227、ts=160、css=19 |
| 页面文件 | `pages=27` | 顶层 20 + `pages/group/` 7 个群内场景 |
| 组件 | `components=85` | 含 chat/live/voice/group/home/posts/share/boardgame/motion/overlay/cards 子域 |
| stores | `stores=22` | Zustand，见 §7 |
| hooks | `hooks=37` | 手势/入场/滚动/实时相关自定义 hooks |
| API 模块 | `api=19` | 18 个域模块 + types.ts，见 §8 |
| WS 模块 | `ws=4` | chat/live/voice/presence 四通道 |
| 样式 | `styles=19` | 全局 css（含 tokens.css），无 CSS Modules |
| utils | `utils=11` | 显示状态/媒体播放/分享/搜索/排序等 |
| 测试 | `tests=154` | vitest 文件（含 setup.ts），jsdom 环境 |
| layout | 15 文件 | AppShell/BottomTabs/TopNav/ServerRail/ChannelSidebar/FAB 族等 |
| runtime | 2 文件 | `liveSessionRuntime.ts`(589 行)、`voiceSessionRuntime.ts`(100 行) |
| livekit 适配 | 2 文件 | `client.ts`(251 行薄封装)、`wsRelayRoom.ts`(825 行 WS 音频中继) |
| player | 1 文件 | `hls.ts`(156 行 hls.js 低延迟封装) |

## 5. 路由与页面清单

路由总表在 `web/src/App.tsx`（98 行）。24 条路由：公开 2 条（`/login`、`/register`）+ AppShell 保护 22 条。页面组件**同步导入、不按路由懒加载**（类桌面 SPA 频繁切换，懒加载是负优化）。

### 5.1 一级路由（AppShell 内）

| 路由 | 页面组件 | 职责 |
|---|---|---|
| `/login` | `LoginPage.tsx` | 登录（宽屏左右分栏/窄屏单卡，auth.css） |
| `/register` | `RegisterPage.tsx` | 注册（邮箱验证码） |
| `/`、`/home` | 重定向 `/group` | 兼容入口 |
| `/group` | `HomePage.tsx`(223 行) | 群列表主页（窄屏卡片轮播/宽屏 ServerRail+ChannelSidebar 三列聊天壳） |
| `/voice`、`/voice/:channelId` | `VoiceHubPage.tsx` | 语音大厅 |
| `/live` | `LiveHubPage.tsx` | 直播大厅 |
| `/live/start/:channelId` | `LiveStudioPage.tsx` | 开播控制台 |
| `/live/:channelId` | `LiveRoomPage.tsx`(75 行薄壳) | 直播间（重活在 components/live/LiveRoomBody） |
| `/posts` | `PostsHubPage.tsx` | 帖子信息流 |
| `/posts/mine` | `MyPostsPage.tsx`（经 `UserPostsRoute.tsx` 路由） | 我的帖子 |
| `/posts/:postId` | `PostDetailPage.tsx` | 帖子详情 |
| `/games`、`/games/:roomId` | `GamesHubPage.tsx` | 桌游大厅（玩法占位） |
| `/messages` | `MessagesPage.tsx` | 消息中心（私信/认证消息双 tab） |
| `/search` | `SearchPage.tsx` | 搜索（7 分类） |
| `/profile` | `ProfilePage.tsx` | 个人主页 |
| `/user/:userId` | `UserProfilePage.tsx` | 他人主页 |
| `/user/:userId/posts` | `UserPostsRoute.tsx` | 他人帖子（show_content 守卫） |
| `/favorites` | `FavoritesPage.tsx` | 收藏（六类） |

### 5.2 二级路由

| 路由 | 页面组件 | 职责 |
|---|---|---|
| `/chat/:conversationId` | `ChatConversationRoute.tsx`（内部渲染 `PrivateChatPage.tsx`；群聊会话重定向 /group/:id） | 私聊窗口 |
| `/group/:id` | `GroupPage.tsx`(539 行) | 群主页聚合壳（默认聊天场景） |
| `/group/:id/:scene` | `GroupPage.tsx` | 群内场景：chat/voice/live/posts/games |
| `/group/:id/posts/:postId` | `GroupPage.tsx` | 群内帖子详情 |
| `/group/:id/voice/:voiceChannelId` | `GroupPage.tsx` | 群内语音房 |
| `/group/:id/live/:liveChannelId` | `GroupPage.tsx` | 群内直播间 |

### 5.3 pages/group/ 群内场景（7 文件，全部由 GroupPage 编排）

| 文件 | 职责 |
|---|---|
| `group/GroupChat.tsx` | 聊天场景：消息列表 + 子群条 + composer |
| `group/GroupVoice.tsx` | 语音场景 |
| `group/GroupLive.tsx` | 直播场景 |
| `group/GroupPosts.tsx` | 帖子场景 |
| `group/GroupGames.tsx` | 桌游场景 |
| `group/GroupInfo.tsx` | 群资料/管理/成员 |
| `group/GroupScenePlaceholder.tsx` | 场景占位 |

## 6. 组件体系（85 个，components/ 按子域）

| 子域 | 数量 | 代表组件 |
|---|---|---|
| chat | 12 | MessageBubble/MessageList/MessageInput/ConversationList/EmojiPackPanel/ImageViewer/MediaContent/MentionPicker/PrivateChatPane/ShareBubble/WideMessagesSidebar/QuickMessagesSheet |
| live | 15 | LiveRoomBody/LivePlayer/LiveHall/LiveChannelCard/LiveChannelRail/DanmakuInput/DanmakuList/DanmakuOverlay/LiveMiniPlayer/LiveOwnerPanel/LiveStartSheet/LiveStreamAddresses/LiveViewerSheet/LiveViewerStrip/LiveHostAvatar |
| voice | 7 | VoiceRoomBody/VoiceChannelPanel/VoiceChannelList/VoiceChannelCreate/VoiceChannelCard/VoiceControls/VoiceMemberRow |
| group | 3 | GroupTopTabs/GroupApplyDialog/SubGroupDialog |
| home | 5 | GroupCard/GroupCarousel/GroupListItem/LayoutSwitch/AvatarStatusBadges |
| posts | 5 | PostCard/PostEditor/CommentList/CommentComposer/PostVideoCover |
| share | 2 | ShareButton/ShareSheet（分享消息卡片） |
| boardgame | 3 | GameRoomCard/GameRoomCreate/GameRoomPlaceholder |
| motion | 7 | PageTransition/PrimaryNavPage/FullScreenSwipeBack/PullToRefresh/ConversationTransition/AuroraquaNavHighlight/auroraquaMotion.ts |
| cards | 2 | DirectoryResultCards/cardData.ts |
| 基础 | 19 | Avatar/ResourceImage/SignedVideo/AsyncState/ConfirmDialog/DirectoryFilters/DirectoryLoadMore/FavoriteButton/FullScreenLoader/GroupCreateDialog/HistoryControls/NavigateBridge/PrivacySheet/ProfileContentSections/ProtectedRoute/ScrollingTags/ScrollingText/StablePaginationFooter/UserProfileCard/VisibilitySelector/icons.tsx(20+) |
| overlay | 1 | OverlayScrollbar（自定义滚动条，滚动 owner 生命周期管理） |

## 7. 状态管理（stores=22，Zustand）

| store | 职责 |
|---|---|
| auth | JWT 双令牌、会话恢复、登出、触发 appInit |
| chat | 聊天消息/光标分页/乐观消息/发送状态/群聊+私聊 |
| message | 会话列表/未读/置顶/红点 |
| chatDrafts | 按「会话+子群」隔离草稿 |
| group | 群列表/活跃度排序/当前群 |
| subgroup / subgroupRead | 子群与已读状态 |
| home | 群卡轮播/实时状态卡 |
| voice | 语音房目录/成员/连接状态 |
| live | 直播目录/当前频道/弹幕/看人数/迷你播放器 |
| posts | 帖子流/瀑布流列分配/详情 |
| boardgame | 桌游房目录 |
| directory | 六页面共用目录分页（语音/直播/帖子/桌游/搜索/收藏） |
| favorites / favoriteStatus | 收藏列表与单卡状态 |
| search | 搜索缓存/分类/滚动位置 |
| social | 好友关系（friendIds 集合） |
| presence | 在线状态字典 |
| sessionActivity | 页面会话活动（悬浮球） |
| notices | 通知 |
| realtime | WS 连接状态 |
| shell | 壳层状态（quickMessagesOpen 等） |
| badges | 消息中心红点聚合 |

## 8. 数据层：API 客户端与后端对接面

### 8.1 鉴权机制（api/client.ts）

- JWT access/refresh 双令牌；`ROTATE_REFRESH_TOKENS=True`（refresh 也轮换）
- 请求自动带 `Authorization: Bearer <access>`
- **401 静默刷新 + 重放一次**：互斥锁防并发刷新；刷新失败清 store 跳 `/login?next=` 回跳
- WS 重连前也会调 `refreshAccessToken()` 防临期 token 死循环
- 错误归一：`{detail}` / `{field: [msg]}` → 可读文案

### 8.2 REST 端点盘点（backend 12 apps，11 个 urls.py，实测 108 个 path() 端点）

> 实测口径：`(?:path|re_path)\(` 计数（含 7 个动态段）。曾写「约 70」低估约 54%，已修正为实测值。

| app | path 数 | 端点（前缀 /api/v1/） |
|---|---|---|
| accounts | 17 | `health/` `health/live/` `auth/register/` `auth/login/` `auth/refresh/` `auth/change-password/` `auth/change-email/` `auth/send-email-code/` `me/` `me/profile/` `me/badges/` `users/search/` `users/<id>/` `friends/` 等 |
| chat | 34 | `conversations/` `conversations/group/` `subscriptions/` `group-presence/` `me/join-requests/` `leave-notices/` `leave-notices/<id>/read/` `me/invites/` 等 |
| media | 11 | `uploads` `uploads/<id>` `"<media_id>"` `"<media_id>/"`（+ poster 抽帧回传等子路由） |
| voice | 8 | `channels/` 及成员/上麦/目录过滤等子路由 |
| live | 7 | `channels/` 及 `<id>/status/` `viewers/` 等子路由 |
| elysia_bridge | 7 | 爱莉桥接相关端点 |
| emoji | 9 | `packs/` `search/` 等 |
| boardgame | 6 | `rooms/` 及状态/成员子路由 |
| posts | 5 | `""`（列表/发布） `views/` `"<id>/"`（详情/评论）等 |
| favorites | 3 | `""` `status/` `"<id>/"` |
| search | 1 | `""`（全类型搜索） |

### 8.3 媒体管线（关键对接面）

- **签名加载**：媒体 URL 需 Bearer 鉴权，不能用裸 `<img src>`——前端 `ResourceImage`/`apiRequestBlob` 拉 blob 或走预签名 URL；无签名直链会在服务端 401 破图
- **预签名直传**（三步入场）：`POST /media/uploads` 建会话 → 流式 `PUT` 上传（1MiB 分块，XHR 进度，可取消，413 超限中断）→ 确认落 media；取消自动清理临时对象
- **缩略图**：图片 320px 签名缩略图；GIF 走原图
- **视频秒开**：上传时前端抽首帧回传 poster（JPEG ≤2MB）→ 卡片/详情渲染 thumbnail 海报帧 `<img>` + ▶ 角标，零视频拉流；mp4 faststart 重排（moov 前置）
- **直播**：SRS 推流 → hls.js 低延迟播放（见 §10）

## 9. 实时协议（WS 四通道）

### 9.1 chat 主总线（ws/chat.ts，41 个接收分发 case）

登录后常驻连接（`chatWS.connect()`），重连补拉对账。**41 个 case 全部为接收分发**（按 `type` 字段）；`ping`/`resume`/`subscribe` 是前端**发送帧**（心跳/恢复/订阅），不属于接收分发——两者是不同通道方向，不能混为同一清单。接收事件：

- **消息**：`message.new` `message.poke` `message.read` `message.recall` `history.sync`（历史对账） `chat.subscribed` `typing`（输入中状态）
- **群**：`group.created` `group.joined` `group.member.left` `group.invite.new` `group.request.new` `group.request.resolved`
- **子群**：`subgroup.created` `subgroup.deleted` `subgroup.updated` `subgroup.read`
- **语音目录**：`voice.channel.created` `voice.channel.deleted` `voice.channel.updated` `voice.channel.member_count_changed` + `voice.channel.*` 前缀族（目录失效判定）
- **直播目录**：`live.channel.created` `live.channel.deleted` `live.channel.updated` `live.channel.status.changed` + `live.channel.*` 前缀族 + `live.viewers.changed`（看人数热更新，**不进目录失效命名空间**）
- **帖子**：`post.created` `post.updated` `post.deleted` `post.viewed` `comment.created` `comment.deleted`
- **桌游**：`boardgame.room.created` `boardgame.room.updated` `boardgame.room.deleted` + 前缀族
- **社交**：`friend.request.new` `friend.request.resolved` `favorite.changed` `elysia.reply`
- **连接层**：`pong`（心跳回执） `error`（服务端错误帧）

### 9.2 其他通道

| 通道 | 内容 |
|---|---|
| ws/presence.ts | `presence.status` `presence.update`（在线字典，Redis presence 权威） |
| ws/voice.ts | `voice.state`（应用层成员事实，区别于媒体层轨道 mute） |
| ws/live.ts | 房内弹幕帧（`{"type":"viewers", count, viewers}` 等）+ 房间信令 |
| wsRelayRoom.ts | **音频数据通道**（见 §10.2），Opus 二进制帧 + 控制帧（slot/members/identity） |

## 10. 实时音视频（复刻最大对接面）

### 10.1 直播：hls.js 低延迟（web/src/player/hls.ts）

- `lowLatencyMode: true` + `liveSyncDurationCount: 2`（贴直播边缘 2 分片）+ `startLoad(-1)` 从边缘起播；**不做追帧倍速**（liveSyncPlaybackRate 保持 1.0）
- Safari 原生 HLS 分支：`video.src` 直挂
- 错误恢复：networkError → `startLoad()` 重试；mediaError → `recoverMediaError()`；fatal 不可恢复 → 销毁重建
- `refreshToLiveEdge()`：跳到直播最新（liveSyncPosition → seekable 末尾 → reload+play 三级兜底）
- 黑屏自愈（LiveRoomBody 编排）：videoVersion 重建信号重 attach；全屏冻结 isNarrow 防布局翻转重建；事件驱动卡顿检测（waiting/stalled 2s + 冷却 4s → 重建）
- 迷你小窗（窄屏 App 内）：video 原子移动不重建（liveSessionRuntime 全局单例唯一持有）；桌面端保留原生 PiP
- 全屏：容器 requestFullscreen + 窄屏锁横屏 `screen.orientation.lock("landscape")`；iOS Safari 走 `webkitEnterFullscreen()` 原生视频全屏

### 10.2 语音：WS 音频中继（wsRelayRoom.ts，825 行）

**LiveKit 已整体退役**（2026-09-12 起）：frp 穿透下 UDP 源地址被改写，WebRTC/TURN 媒体面不可用 → 唯一传输为 WS 音频中继：

- **格式**：48kHz 单声道 Opus；采集 AudioWorklet（PCM Float32）→ WebCodecs `AudioEncoder`（opus）→ WS 二进制帧上行；接收 WS 帧 → WebCodecs `AudioDecoder` → AudioContext 播放
- **控制帧**：服务器分配 slot，成员进出/轨道 mute 事件
- **语义边界**：轨道 mute 是媒体事实；store 的 muted/unmuted 是应用层成员事实——两套不混用
- 远端音量是本地播放偏好（不落库）；媒体断线 ≠ 离开频道（只映射 failed，用户决定重进）
- 服务端：`backend/apps/voice/audio_consumer.py` + `audio_relay.py`（中继）

**Flutter 对接面**：录音采集（48k 单声道）+ Opus 编码 + WS 二进制帧收发 + Opus 解码 + 播放。dart 侧需要 libopus 绑定（FFI/插件）或等效方案，无官方现成组件。

## 11. 设计规范提炼（design.md 714 行）

### 11.1 视觉身份：千禧冰樱 Y2K Frost

冰蓝→樱粉极光渐变 + 磨砂玻璃 + hot pink 辉光。**爱莉专属**：粉渐变气泡（grape 字）+ 锥形渐变在线光环 + 3.2s 呼吸辉光。

### 11.2 核心 token（styles/tokens.css）

- 背景 `--bg-aurora`：160° 三色渐变（`#BDD4E9 → #ECF0F2 → #FCD8FF`）fixed
- 正文 `#465B92`（indigo-700，对比度 6.4:1）；次要文字 `#7E95BD`（≥14px 才可用）
- 玻璃卡：`rgba(255,250,251,0.55)` + `blur(18~24px) saturate(1.4)` + `1px rgba(255,255,255,0.65)` 亮边 + 圆角 16px + 阴影 `0 8px 32px rgba(70,91,146,.2)`
- 辉光 `0 0 16px rgba(247,150,255,0.45)`：**全屏 ≤3 处**（爱莉/主 CTA/focus）——复刻时必须保持这个纪律
- 气泡：自己 `#9DBFE6→#BDD4E9` 渐变；爱莉 `#FCD8FF→#F9B0FF` + grape 字（唯一）；他人玻璃底
- 在线光环：`conic-gradient(#9DBFE6, #F9B0FF, #F796FF, #9DBFE6)` 2.5px 环

### 11.3 字体

- Display `Fredoka`(600/500)、Body `Nunito`(400/600/700)、Utility `Space Grotesk`（时间戳/数字）
- CJK 回退：PingFang SC → Hiragino Sans GB → Noto Sans SC → Microsoft YaHei
- 正文最小 13px；字号阶梯 40/28/20/15/14/13/12/11

### 11.4 断点与双形态布局（复刻核心结构）

- 断点：**480 / 768 / 1024 / 1440**；验证视口 375/768/1024/1440
- **窄屏（≤768）**：底部五 tab（玻璃 64px + 主页居中凸起圆形背板 48px）+ 手势矩阵 + 各页面专属顶栏
- **宽屏（>768）**：TopNav（64px 玻璃，品牌 logo ≤1000px 隐藏）+ ServerRail（72px 群头像列）+ ChannelSidebar（260px 频道栏）+ 独立内容滚动（OverlayScrollbar）
- 宽屏群聊三列壳（`.wide-group-shell`）：ServerRail 常驻，只活动标记移动；ChannelSidebar 换群编排进出
- 直播间双形态：窄屏沉浸（视频+弹幕滚动区+底部输入）；宽屏视频主区 + 360px 弹幕侧列
- 帖子流：>1024px 双列等宽瀑布（列分配记忆 key 含列表身份+列数）

### 11.5 动效体系（Auroraqua 配方）

- 时长：按钮 200ms / 卡片 hover 300ms / 路由 300ms / 页面显现与侧栏进入 500ms
- framer-motion 只接管三类：跟手（拖拽/下拉/侧滑 motion value）、进出协同（AnimatePresence）、编排（多层时间线）；其余 CSS keyframes
- 流体极光背景：4 层互质周期（渐变 22s/湍流 17s/光斑 10s）+ 负延迟错相 + SVG feTurbulence 静态纹理 + transform 动画（禁 background-position 重绘）；150vmax 正方形层中心恒等视口中心
- 卡片材料：玻璃卡 300ms 过渡，可交互卡 hover 上浮 2px + shadow 12/40，按下 scale(.98)；Glow CTA/选中导航 600~700ms 扫光
- `prefers-reduced-motion`：关闭全部位移/呼吸/扫光，直接显示最终态

### 11.6 窄屏手势矩阵（design.md §12.12，全部有等效按钮/键盘路径）

| 手势 | 实现 | 松手契约 |
|---|---|---|
| 一级五页横滑（voice/live/group/posts/games） | PrimaryNavPage + useSwipeCommit | 净位移 ≥ 1/3 容器 或 甩动 ≥300px/s 且 ≥40px；交叉轴让位 |
| 群内五场景横滑 | GroupPage | 同上；dragElastic 0.8 |
| 直播间上下滑切台 | LiveRoomBody | 主轴 y；顶栏输入固定，单真实播放器 |
| 图片查看器横滑 | ImageViewer | 同上契约 |
| 私信左边缘右滑返回 | 起手边界 24px，≥120px 或 0.3px/ms | 其余回弹 |
| 下拉返回主页 | 群场景 80px 阈值 | 200ms 回弹 |
| 下拉刷新 | PullToRefresh 状态机 | 原始下拉 64px 触发，视觉阻尼 `96×(1−e^(−dy/90))`，停留 52px |

## 12. 测试体系（tests=154）

- vitest 2.1.1 + jsdom + @testing-library/react；`--maxWorkers=1`
- 覆盖：stores（auth/chat/message/group/live/voice/posts/search…）、API 模块、WS 协议解析、手势 hook（useSwipe/useSwipeCommit）、组件交互（MessageBubble/PostCard/DanmakuOverlay…）、路由行为（页面测试）
- 命令：`/e/nodejs/node.exe node_modules/vitest/vitest.mjs run <file>`（workdir=Ayla/web）

## 13. 关键实现锚点（复刻时逐文件对照）

| 领域 | 文件 |
|---|---|
| 路由/壳 | `App.tsx` `layout/AppShell.tsx` `layout/shellConfig.ts` `components/ProtectedRoute.tsx` |
| 宽屏三列 | `layout/ServerRail.tsx` `layout/ChannelSidebar.tsx` `layout/TopNav.tsx` |
| 窄屏五 tab | `layout/BottomTabs.tsx` `layout/NarrowTopBar.tsx` |
| 群聚合 | `pages/GroupPage.tsx` `pages/group/*`（7 场景）`components/group/GroupTopTabs.tsx` |
| 聊天 | `pages/group/GroupChat.tsx` `components/chat/*`（12）`stores/chat.ts` |
| 私聊 | `pages/PrivateChatPage.tsx` `pages/ChatConversationRoute.tsx` `components/chat/PrivateChatPane.tsx` |
| 语音 | `components/voice/*`（7）`runtime/voiceSessionRuntime.ts` `livekit/wsRelayRoom.ts` |
| 直播 | `components/live/*`（15）`runtime/liveSessionRuntime.ts` `player/hls.ts` |
| 帖子 | `pages/PostsHubPage.tsx` `pages/PostDetailPage.tsx` `components/posts/*` |
| 桌游 | `pages/GamesHubPage.tsx` `components/boardgame/*` |
| 目录六页面 | `components/DirectoryFilters.tsx` `stores/directory.ts` `hooks/useDirectoryPage.ts` |
| 手势 | `components/motion/*` `hooks/useSwipe*.ts` `hooks/usePagerTouchRouter.ts` `hooks/useTouchAxisGuard.ts` |
| 媒体 | `components/ResourceImage.tsx` `components/SignedVideo.tsx` `api/media*.ts` |
| 分享 | `components/share/*` `utils/sharePayload.ts` `utils/shareRoutes.ts` |
| 设计 token | `styles/tokens.css` `styles/auroraqua.css` `components/motion/auroraquaMotion.ts` |

## 14. 复刻工作量第一直觉（详见 02 文档）

- **页面层**：27 页面文件多为壳与编排，重活在 85 个组件与 37 个 hooks
- **视觉层**：无组件库（好事，无迁移负担）但全手写（玻璃卡片族、双形态布局、流体背景、动效体系要整套重造）
- **实时层**：ChatWS 事件总线（37 事件）+ 语音 WS 音频中继（Opus 编解码）+ 直播 hls 低延迟——三块是 Flutter 平台无现成等价物的硬骨头
- **工程整体**：中等偏大型 SPA，结构化良好、契约文档齐全（design.md/architecture/*），复刻有据可依
