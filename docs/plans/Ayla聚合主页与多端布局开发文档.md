# Ayla 聚合主页与多端布局开发文档

> 对应需求：`Ayla聚合主页与多端布局需求文档.md`。本文给出后端增量（基于现状缺口分析）与前端增量（基于现有 React 代码结构）的开发方案。
> 前端一切视觉实现必须先读 `Ayla/docs/design.md`（Y2K Frost 唯一事实源）与项目级 skill `.workbuddy/skills/ayla-frontend-design`；组件内禁止裸 hex，一律用 `web/src/styles/tokens.css` 变量。

## 0. 现状盘点结论（输入）

**后端已有**：JWT 认证、用户资料 PATCH、好友（Friendship/FriendRequest 全流程）、私聊/群聊（消息、已读、撤回、typing、unread_count、群成员 owner/admin 直接管理）、媒体三步上传、语音频道（LiveKit）、直播频道（SRS）+ 弹幕、爱莉桥接。

**后端缺口（本期需补）**：

| # | 缺口 | 现状 |
|---|---|---|
| B1 | 群申请/邀请 | 仅群主直接加人，无 GroupJoinRequest/GroupInvite |
| B2 | 帖子/评论 | 无 posts app（media 可复用做配图） |
| B3 | 桌游室 | 无模型/路由 |
| B4 | 全站聚合搜索 | 仅 `users/search/` 与 emoji search |
| B5 | 通用收藏 | 无 Favorite 模型 |
| B6 | 房间可见性 | Live/VoiceChannel 无 visibility 字段，准入 = 全体登录用户 |
| B7 | 群归属房间 | Live/VoiceChannel 无 group 外键，无法按群聚合 |
| B8 | 群动态轮播数据 | 无"某群最新动态封面"聚合接口 |
| B9 | 全站未读聚合 | 仅会话 unread_count，无消息中心红点聚合 |
| B10 | 语音房文字消息 | 语音房无聊天通道（需求 R-V2 要求房内打字） |

## 1. 后端增量设计

### 1.1 可见性与群归属（B6/B7）——最优先，多模块依赖它 【S1 已落地 2026-08-14】

> 落地记录：`apps/common/visibility.py`（Visibility 枚举 + `visible_queryset`/`can_view`/`can_join`），
> live/voice 模型加 `visibility`+`group` 字段（迁移 0002，存量默认 public 零感知），
> 创建接口支持 `group`/`visibility` 参数（group 非空默认 group 可见；visibility=group 的群归属
> 来自单群 `group` 或多群 `allowed_groups` 白名单——全局列表创建"指定群可见"场景，两者皆空则 400），
> 列表/详情/弹幕/join/成员列表接入过滤与 403 校验，序列化输出 visibility/group/group_name/allowed_group_ids。
> 契约测试：`apps/common/tests/test_visibility.py`（可见性矩阵）+ live/voice `test_visibility_api.py`，全量 335 通过。

```python
# 新增枚举（建议放 apps/common 或各 app 内统一定义）
class Visibility(models.TextChoices):
    PUBLIC = "public", "公开"
    FRIENDS = "friends", "好友可见"
    GROUP = "group", "群成员可见"
```

- `live.LiveChannel` / `voice.VoiceChannel` 增加字段：
  - `visibility = CharField(choices=Visibility, default="public")`
  - `group = ForeignKey(chat.Conversation, null=True, blank=True, limit_choices_to={"type": "group"})`
  - 约束：`visibility="group"` 时群归属来自 `group` 或 `allowed_groups` 白名单（两者皆空则拒绝创建/修改）；`group` 非空时默认 `visibility="group"`。
- **新建的 posts.Post / boardgame.GameRoom 模型直接内置** `visibility` + `group` 字段（同枚举、同约束），S3/S4 建表即带，无需二次迁移。
- **准入校验层** `services.can_view(user, obj)` / `can_join(user, obj)`：
  - public → 任何登录用户；
  - friends → owner 本人或其 accepted 好友；
  - group → 该群 ConversationMember。
- 列表接口统一加可见性过滤：`Q(visibility=public) | Q(owner=me) | Q(visibility=friends, owner__in=my_friends) | Q(group__in=my_groups)`。抽成共用 queryset helper（`apps/common/visibility.py`），live/voice/posts/boardgame 复用。
- 迁移：存量房间默认 `public`，行为不变，零风险。

### 1.2 群申请/邀请（B1）——chat app 扩展 【S2 已落地 2026-08-14】

> 落地记录：`GroupJoinRequest`/`GroupInvite` 模型（迁移 0002）；路由
> `conversations/<id>/join-requests/`（GET owner/admin 审批列表 / POST 申请，幂等）、
> `join-requests/<id>/action/`（accept 事务内建成员）、`conversations/<id>/invites/`（群成员邀请）、
> `me/invites/`、`invites/<id>/action/`（仅被邀请人本人）。
> WS：ChatConsumer 新增用户级组 `chat_user_<id>`，消息类型 `group.request.resolved`/`group.invite.new`。
> 契约测试：`apps/chat/tests/test_group_requests.py`、`test_group_ws.py`。
> 已知取舍：Conversation 无可见性字段，"公开/好友"群区分后置（见开发步骤 §7）。

- 新模型 `GroupJoinRequest`（conversation, applicant, message, status pending/accepted/rejected, handled_by, handled_at）与 `GroupInvite`（conversation, inviter, invitee, status, handled_at）。
- 路由（挂在 `/api/v1/chat/`）：
  - `POST conversations/<id>/join-requests/` 申请入群（幂等：同人同群 pending 唯一约束）
  - `GET conversations/<id>/join-requests/`（owner/admin 查看）
  - `POST join-requests/<id>/action/`（accept/reject，accept 事务内创建 ConversationMember）
  - `POST conversations/<id>/invites/`（群成员邀请好友）
  - `GET me/invites/`、`POST invites/<id>/action/`（被邀请人处理）
- **权限矩阵**：
  - 申请入群：任何登录用户可申请**公开群**；好友群仅好友可申请；群成员群不可申请（无发现路径）；
  - 审批申请：仅 owner/admin；
  - 邀请：仅群成员（成员邀请好友入群）；
  - 处理邀请：仅被邀请人本人。
- WS：处理后给申请人/被邀请人推 `group.request.resolved` / `group.invite.new`（走现有 ws/chat 通道加消息类型）；申请/邀请数量变化同时触发 `me/badges/` 重新拉取。

### 1.3 帖子（B2）——新建 `apps/posts`

- 模型：
  - `Post`(id, author, group FK 可空, visibility, title, body, created_at/updated_at)
  - `PostImage`(post, media FK, order)（复用 media 三步上传）
  - `Comment`(id, post, author, body, reply_to 可空, created_at)
- 路由 `/api/v1/posts/`：
  - `GET posts/`（信息流：可见性过滤 + 范围参数 `?scope=feed|group:<id>|mine`，游标分页 `?cursor=<base64>&limit=20`，返回 `{results, next_cursor, has_more}`）
  - `POST posts/`（含 images: [media_id]，≤9 张）
  - `GET/PATCH/DELETE posts/<id>/`（PATCH/DELETE 仅 author）
  - `GET/POST posts/<id>/comments/`、`DELETE comments/<id>/`（仅评论作者本人）
- 信息流排序：`created_at` desc 游标分页；群内帖子列表同接口 `scope=group:<id>`。

### 1.4 桌游室（B3）——新建 `apps/boardgame`，仅房间框架

- 模型：`GameRoom`(id, name, owner, group FK 可空, visibility, game_type 默认占位, status waiting/playing/ended, created_at)、`GameRoomMember`(room, user, seat, joined_at)。
- 路由 `/api/v1/boardgame/`：`GET/POST rooms/`、`GET/DELETE rooms/<id>/`、`POST rooms/<id>:join` / `:leave`。
- 玩法引擎、WS 对局通道明确**非本期目标**，前端进入后是占位界面。

### 1.5 聚合搜索（B4）——新建 `apps/search`（只读聚合层）

- 路由 `GET /api/v1/search/?q=&types=user,group,post,live,game&limit=`。
- 实现：分发给各 app 的轻量查询（`__icontains` + 可见性过滤），按类型分组返回 `{users: [...], groups: [...], posts: [...], lives: [...], games: [...]}`，每组截断 N 条 + total。
- 不建索引、不引搜索引擎（数据量小）；每类查询独立 `LIMIT`，超时预算 2s。
- users 搜索复用 accounts 逻辑；groups = 我可见的群（公开群 + 我所在群）；live/game/post 走 1.1 的可见性 helper。

### 1.6 收藏（B5）——新建 `apps/favorites`

- 通用模型 `Favorite`(user, target_type post/live/voice/game/group, target_id, created_at)，唯一约束 `(user, target_type, target_id)`。
- 路由：`GET /api/v1/favorites/?type=`、`POST favorites/`（幂等）、`DELETE favorites/<id>/`。
- 前端"更多 → 收藏"页本期展示帖子收藏即可，其余类型留扩展。

> 落地记录（任务 07，2026-08-26）：
> - **收藏跳转全类型直达**：`FavoritesPage.openTarget`——voice → `/voice/{target_id}`
>   （VoiceHubPage 已有直达进房逻辑）、game → `/games/{room_id}`（**新增路由**，GamesHubPage
>   按 room id 自动 join 进房，返回回大厅）、live → `/live/{id}`、post → `/posts/{id}`、
>   group → `/group/{id}`、message → `/chat/{conversation_id}`（target 摘要带 conversation_id）。
> - **收藏 WS 热更新**：收藏/取消收藏后向用户级组 `chat_user_<user_id>` 广播
>   `favorite.changed` `{target_type, target_id, favorite_id, action: added|removed}`
>   （`apps/favorites/services.py::broadcast_favorite_changed` 复用 chat 用户级广播；
>   ChatConsumer 新增 `favorite_changed` 处理器）。收藏是用户私有数据，只推给收藏者本人，
>   同账号各界面（帖子卡片/详情、直播/语音/桌游/群卡片、收藏页）实时同步。
>   前端 `ws/chat.ts` 分发：post → posts store `favoriteByPostId`；其余类型 →
>   `FavoriteButton` 模块缓存订阅（`applyFavoriteChanged` 更新缓存并通知挂载按钮）；
>   收藏页订阅后 removed 本地移除 / added 重新拉取权威列表。
> - **群内帖子收藏键**：`GroupPosts` 接入真实收藏（favorited 取 posts store，挂载时
>   `listFavorites("post")` 铺底，toggle 走 favoritesApi + store 即时反馈）。
> - **收藏页导航条**：`.favorites-filters` 加 `min-width:0; width:100%`（flex column 子项
>   被七个 tab 撑开导致整页横向溢出的经典问题），顶栏标题加 ellipsis；宽/窄屏
>   Playwright 实测数据见验收记录。

### 1.7 群动态轮播（B8）——chat app 聚合端点

- `GET /api/v1/chat/conversations/<id>/highlights/`：返回该群最近动态封面列表 `[{type: live|post|game, title, cover_url, target_url, created_at}]`，按时间 desc 取前 5：
  - live：群内 status=live 的直播间封面；
  - post：群内最新带图帖子的首图；
  - game：群内进行中的桌游室封面（无图用默认）。
- 主页**卡片布局批量场景**再加 `GET conversations/highlights/?ids=...`（避免 N+1，前端进入主页一次性拉取）。
- 群内动态变化（新直播/新帖/新桌游室）由对应 WS 事件触发前端重新拉取 highlights；拉取失败降级为群头像封面，不阻塞主页渲染。

### 1.8 全站未读聚合（B9）——accounts 或独立 health 式端点 【S2 已落地 2026-08-14】

> 落地记录：`accounts/views.py` `BadgesView`，`GET /api/v1/me/badges/`；未读口径与
> `ConversationSerializer.get_unread_count` 一致（非本人发送、非撤回、无 MessageRead）；
> 契约测试 `tests/test_badges.py`。

- `GET /api/v1/me/badges/`：返回 `{private_unread, group_unread, friend_requests, group_invites, join_requests_pending}`。
- 数据来源：现有会话 unread_count 聚合 + FriendRequest pending + 1.2 的邀请/申请。
- 前端消息入口红点、主页群卡片红点分别消费（群卡片仍用会话自己的 unread_count，此端点服务消息入口总红点）。

### 1.9 语音房文字消息（B10）

- 最小方案：语音房打字**复用 chat 通道**——创建语音房时可关联/复用一个会话（群内语音房直接用群会话；独立语音房后续再说），前端在房内输入框发的就是群消息。
- 若要求房间独立文字流：`voice` 加 `VoiceMessage` + ws/voice 加 `voice.chat` 消息类型。**建议本期用复用方案**，独立文字流列为后续。

### 1.10 后端实施顺序

```
S1 可见性枚举 + Live/Voice 字段与准入 + queryset helper（含迁移与回归测试）
S2 群申请/邀请（B1）＋ 未读聚合（B9，依赖 S2 的邀请数据）
S3 posts app（B2）
S4 boardgame 房间框架（B3）
S5 搜索聚合（B4，依赖 S1/S3/S4）
S6 收藏（B5）＋ 群动态 highlights（B8，依赖 S1/S3/S4）
```

每一步配 DRF API 契约测试；可见性 helper 单独覆盖 public/friends/group × owner/好友/群员/路人 矩阵；S2 覆盖申请状态机（pending→accepted/rejected 幂等、重复申请、非 owner 审批 403）。

## 2. 前端增量设计

### 2.1 新架构骨架：AppShell + 场景路由

```
src/
  layout/
    AppShell.tsx            # 响应式外壳（useMediaQuery 768px）：窄屏=BottomTabs 系，宽屏=TopNav+可选左栏
    BottomTabs.tsx          # 窄屏：五 tab（主页中央凸起），含未读点；支持"上移到顶部"与"下滑走"两种形态
    MessageFab.tsx          # 窄屏左下消息入口（红点）
    CreateFab.tsx           # 右下 FAB，按 route context 决定动作（两种形态都有）
    TopNav.tsx              # 宽屏顶部常驻：头像 主页 语音 直播 帖子 桌游 消息 搜索 更多
    ServerRail.tsx          # 宽屏主页/群场景最左 72px：群头像列 + 底部用户卡
    ChannelSidebar.tsx      # 宽屏主页/群场景 240-280px：群名 + 聊天/语音/直播/帖子/桌游（带状态标识）
  pages/
    HomePage.tsx            # 窄屏：群卡片/列表网格 + 布局开关 + 轮播；宽屏：重定向到最近群 /group/:id
    GroupPage.tsx           # 群聊场景（窄屏：底栏上移 + 五子界面滑动；宽屏：TopNav+ServerRail+ChannelSidebar+内容区）
    group/GroupChat.tsx     # 复用现有聊天组件
    group/GroupLive.tsx     # 群内直播（窄屏沉浸式上下滑，范围=仅该群；宽屏视频主区+弹幕侧列 360px）
    group/GroupVoice.tsx    # 群内语音房卡片
    group/GroupPosts.tsx    # 群内帖子（输入框发帖）
    group/GroupGames.tsx    # 群内桌游室卡片
    group/GroupInfo.tsx     # 群信息界面
    VoiceHubPage.tsx        # 一级语音 tab（聚合卡片）
    LiveHubPage.tsx         # 一级直播 tab（卡片网格，改造现有 LiveHall）
    PostsHubPage.tsx        # 一级帖子 tab（信息流 + FAB 发帖）
    GamesHubPage.tsx        # 一级桌游 tab
    MessagesPage.tsx        # 私信 / 好友列表 双选项卡（宽屏双栏）
    SearchPage.tsx          # 全局搜索
    PostDetailPage.tsx      # 帖子详情 + 评论输入框
  components/posts/         # PostCard, PostEditor, CommentList
  components/boardgame/     # GameRoomCard, GameRoomCreate, GameRoomPlaceholder
  components/home/          # GroupCard(轮播), GroupListItem, LayoutSwitch
  stores/                   # 新增 posts, boardgame, favorites, badges, search
  hooks/
    useMediaQuery.ts        # 断点 hook
    useSwipe.ts             # 手势 hook（方向锁/阈值/取消）
    useEnterGroupAnimation.ts    # 进群动画：底栏上移到顶部（独立封装，见 §2.2 动画纪律）
    useEnterRoomAnimation.ts     # 进直播间/语音房动画：底栏下滑走+输入框滑入
    usePostDetailTransition.ts   # 帖子详情：底栏原位替换为输入框
```

路由（两种形态共路由，组件内按断点分渲染；保留旧路由作兼容重定向）：

```
/                       → /home
/home                   窄屏：HomePage 群网格；宽屏：重定向 /group/<最近群或第一个群>
/voice                  VoiceHubPage
/live                   LiveHubPage          （旧 LiveHall 改造）
/live/:channelId        LiveRoomPage         （窄屏沉浸式；宽屏视频+弹幕侧列）
/posts                  PostsHubPage
/posts/:postId          PostDetailPage
/games                  GamesHubPage
/games/:roomId          GamesHubPage（任务 07：直达进房——自动 join 并渲染房内占位，返回回大厅）
/messages               MessagesPage         （宽屏双栏）
/search                 SearchPage
/profile                ProfilePage（扩展我的帖子/直播间/桌游）
/group/:id              GroupPage → 默认聊天场景（宽屏 = TopNav+ServerRail+ChannelSidebar 三列）
/group/:id/(voice|live|posts|games|info)
/chat/:conversationId   私聊 → PrivateChatPage（独立私聊窗口）；群聊会话重定向 /group/:id（裸 /chat 已移除，F10 后）
```

### 2.2 关键交互实现要点（动画方向与点击语义精确化）

- **五 tab 滑动切换（仅窄屏）**：`useSwipe` + `translateX` 跟随手势；路由切换用 `navigate` + CSS transition，不保持五页同时挂载（状态经 zustand 持久）。
- **进群动画（仅窄屏，底栏上移到顶部）**：BottomTabs 容器 `translateY(0 → -(100vh - 64px))`（整体上移到视口顶部，不是滑出），250ms ease-out；中央槽位"主页"文本交叉淡化为群头像（槽位宽 48→64px 弹性过渡）；输入框 `translateY(100%→0)` 250ms 延迟 100ms 滑入。**独立封装 `useEnterGroupAnimation`，不得与进房动画共用。**
- **群头像两级点击（仅窄屏，单一 handler 分支）**：由"当前子界面是否为 chat"驱动——非 chat 子界面点击 → 切回 chat；chat 子界面点击 → 打开 GroupInfo 覆盖层。**不允许两层导航状态各自监听点击。**
- **群内五子界面滑动（仅窄屏）**：子路由 + 手势，同五 tab 机制复用；顺序 `voice | live | chat | posts | games`。宽屏由 ChannelSidebar 点击切换，无手势。
- **下拉回主页（仅窄屏）**：顶部导航条 touch 区域监听垂直下拉（仅在子界面滚动到顶时启用），超过阈值 80px 触发反向动画（顶栏下移回底部、"主页"字样复原）+ `navigate(/home)`。
- **进直播间/语音房动画（仅窄屏，与进群方向相反）**：BottomTabs `translateY(0→100%)` 滑出底部（200ms ease-in）＋ 输入框 `translateY(100%→0)` 滑入（250ms ease-out 延迟 100ms）。**独立封装 `useEnterRoomAnimation`。** 帖子详情则**原位替换**底栏为输入框（交叉淡化 200ms，无位移），独立封装 `usePostDetailTransition`。
- **直播间切换**：LiveRoomPage 接收有序频道列表上下文（来源 = 群内直播 or 一级直播聚合——范围不同：群内=仅该群，tab=公开+好友+已加入群）；窄屏垂直滑动手势 prev/next，宽屏为两侧切换按钮 + 键盘 ↑↓；切换时 HLS 重连，保留输入框。
- **输入框显隐**：由路由 context 驱动——chat/live/posts 子界面与帖子详情、直播间、语音房渲染 `<MessageInput/>` 变体；群内 voice/games 子界面不渲染（缩下去）。两种形态规则一致。
- **FAB**：`CreateFab` 读取当前路由匹配表（需求 §3.5）弹出对应创建表单；创建成功后跳转到新房间/新帖。
- **卡片轮播**：GroupCard 内轻量轮播（setInterval + translateX，300ms 滑入 / 3s 间隔），数据来自 `conversations/highlights/?ids=`；无动态时回退群头像做封面。轮播属装饰性循环动画的例外，进入视口才启动、离开视口暂停（IntersectionObserver），并遵守 `prefers-reduced-motion`（降级为首帧静态）。
- **红点**：进入 AppShell 轮询/WS 推送 `me/badges/` → 窄屏 MessageFab / 宽屏 TopNav 消息项红点；群卡片红点用会话列表 unread_count（已有）。

### 2.3 宽屏适配（一等形态）

宽屏与窄屏共享组件与数据层，差异集中在 AppShell 与 GroupPage 两个容器：

- `useMediaQuery('(max-width: 768px)')` 在 AppShell 层二选一渲染窄屏 BottomTabs 系 / 宽屏 TopNav 系；断点体系沿用 design.md §9（480/768/1024/1440）。
- **宽屏主页 = 群聊三列界面**：宽屏访问 `/home` 直接重定向到 `/group/<最近群或第一个群>`（最近群存 localStorage），即宽屏没有"群卡片网格主页"这一中间层——ServerRail（72px 群头像列）+ ChannelSidebar（240–280px 五场景）+ 内容区就是主页本身。语音/直播/帖子/桌游 tab 页面无左栏、内容铺满 TopNav 下方。
- **宽屏手势替代**：一级模块点击（TopNav）、群内子场景点击（ChannelSidebar）、LiveRoom 两侧切换按钮 + 键盘 ↑↓；无"返回主页"按钮（宽屏本就在主页，切模块用 TopNav）。
- **宽屏网格列数**（仅聚合 tab 与卡片列表场景）：直播网格 3–4 列、帖子单列 max-width 680px 居中、桌游 4 列。
- **宽屏消息页双栏**：左 300px（私信/好友选项卡 + 列表）+ 右侧聊天面板或申请详情。
- **宽屏直播间**：视频主区 + 弹幕侧列 360px（替代窄屏的弹幕浮层）。
- 窄屏布局移动优先编写，宽屏用 `min-width: 769px` 增强；全部样式只用 tokens.css 变量，遵守 design.md §8 Do/Don't（辉光 ≤3 处/屏、≤768px 辉光降 30%、无重投影、emoji 不作图标）。

### 2.4 前端实施顺序

```
F1 AppShell + TopNav/BottomTabs + useMediaQuery + 路由重构（旧路由重定向）【已落地 2026-08-14，见开发步骤文档 F1】
F2 窄屏主页（群卡片/列表、布局开关、轮播、红点）+ 宽屏 /home → /group/<最近群> 重定向 【已落地 2026-08-14，见开发步骤文档 F2】
F3 GroupPage 容器（窄屏：底栏上移 + 五子界面滑动 + 群头像两级点击；宽屏：TopNav+ServerRail+ChannelSidebar）
   + 进群/退群动画（窄屏）+ 群内聊天（复用现有）+ 群信息界面 【已落地 2026-08-14，见开发步骤文档 F3】
F4 一级直播 tab + 直播间切换（窄屏：底栏下滑走+输入框滑入、上下滑切全部可见；宽屏：按钮+键盘、弹幕侧列）；群内直播子界面（范围=仅该群） 【已落地 2026-08-14，见开发步骤文档 F4】
F5 一级语音 tab + 语音房输入框；群内语音子界面 【已落地 2026-08-14，见开发步骤文档 F5】
F6 posts 全套（信息流、详情评论、FAB 发帖、群内输入框发帖、个人页我的帖子） 【已落地 2026-08-14，见开发步骤文档 F6】
F7 桌游房间框架（列表、创建、占位界面） 【已落地 2026-08-14，见开发步骤文档 F7】
F8 消息中心（私信 + 好友/群申请）+ badges 红点 【已落地 2026-08-14，见开发步骤文档 F8】
F9 全局搜索页 【已落地 2026-08-14，见开发步骤文档 F9】
F10 个人界面扩展、收藏页占位、更多菜单 【已落地 2026-08-14，见开发步骤文档 F10】
```

### 2.5 前后端依赖对齐

| 前端步骤 | 依赖后端步骤 |
|---|---|
| F2（窄屏主页轮播/红点） | S6 highlights、S1（群卡片状态角标的房间数据） |
| F3（群申请入口在群信息） | S2 |
| F4/F5（可见范围聚合列表） | S1 |
| F6 | S3 |
| F7 | S4 |
| F8 | S2（邀请/申请）、S1 之前即可做私信部分 |
| F9 | S5 |
| F10 收藏 | S6 |

## 3. 测试策略

- 后端：每 app 新增契约测试；可见性矩阵、群申请状态机、帖子信息流分页游标、搜索分组与截断、badges 聚合并发一致性。
- 前端：vitest 组件测试（CreateFab 路由映射、GroupCard 轮播、输入框显隐规则、**群头像两级点击分支**、**三种转场动画方向各自独立**）；playwright 走通主链路两遍——窄屏 390px（主页→进群动画[底栏上移]→发消息→**群头像两级点击：语音子界面点头像回聊天、聊天界面点头像进群信息**→下拉回主页→直播 tab→进直播间[底栏下滑走+输入框滑入]→上下滑切换）与宽屏 1440px（TopNav→进群→频道侧栏切子场景→直播间键盘切换→弹幕侧列）；并按 design.md §10 跑可访问性检查（focus ring、对比度、键盘遍历）。
- 回归：旧聊天/语音/直播路由重定向不破坏既有 playwright 用例（必要时更新路径断言）。

## 4. 风险与取舍

1. **动画方向串味**：进群（底栏上移）、进直播间/语音房（底栏下滑走+输入框滑入）、帖子详情（底栏原位替换）三种转场方向不同——必须各自独立封装 hook（§2.2），防止共用一个动画组件导致方向错误；Playwright 断言动画终点位置（顶栏 vs 消失 vs 替换）。
2. **手势冲突**：五 tab 横滑 vs 群内五子界面横滑 vs 聊天列表横向元素——GroupPage 内禁用一级 tab 横滑，仅子界面横滑；直播间上下滑与页面滚动冲突时用方向锁（先判主轴）。
3. **群头像两级点击**状态竞争：点击语义由"当前子界面是否为 chat"单一驱动（store 中维护 `activeScene`），不引入第二份状态，避免"界面已切到语音但 handler 仍按 chat 处理"。
4. **语音房文字消息**走"复用群会话"方案，独立房间文字流后置，避免本期再开一条 WS 通道。
5. **可见性过滤**是全站横切改动，必须在 S1 一次性把 helper 做对并全量回归 live/voice 旧行为（存量默认 public 无感知）。
6. 搜索不做引擎，量级上来后再评估 PostgreSQL FTS / Meilisearch。
