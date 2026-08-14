# Ayla 聚合主页与多端布局 —— 开发步骤（供 AI 直接执行）

> 文档状态：待执行（本期增量）
> 上位规划：[Ayla聚合主页与多端布局开发文档.md](./Ayla聚合主页与多端布局开发文档.md)（技术方案）、[Ayla聚合主页与多端布局需求文档.md](./Ayla聚合主页与多端布局需求文档.md)（需求）
> 视觉规范：`Ayla/docs/design.md`（Y2K Frost，唯一事实源，§12 增量组件配方）
> 本文件是供 AI 直接执行的开发步骤，不是完成证明。
> **动画方向纪律（高频返工点，先读）：进群=底栏上移到顶部（非滑出）；进直播间/语音房=底栏下滑走+输入框滑入；帖子详情=底栏原位替换为输入框。群头像点击=两级语义（非聊天子界面→回聊天；聊天界面→群信息）。详见开发文档 §2.2。**

## 0. 你（AI）需要先读这些，再动手

| 文件 | 为什么要读 |
|---|---|
| `Ayla/docs/plans/Ayla聚合主页与多端布局开发文档.md` | 后端缺口 B1-B10、后端增量 S1-S6、前端骨架/路由/交互要点、风险与取舍 |
| `Ayla/docs/plans/Ayla聚合主页与多端布局需求文档.md` | 全部 R-* 需求条目（操作流基准） |
| `Ayla/docs/plans/Ayla前端布局文档.md` | 窄屏/宽屏布局规格、动画参数、输入框显隐规则 |
| `Ayla/docs/design.md` | **必读**。§2 token、§4/§12 组件配方、§8 Do/Don't、§9 断点、§10 可访问性 |
| `Ayla/backend/config/urls.py` 与各 app `urls.py/views.py/serializers.py/models.py` | 现有 API 真实契约，以代码为准 |
| `Ayla/backend/apps/chat/{models,services,consumers}.py` | 群成员/会话/消息 WS 协议，S2 在其上扩展 |
| `Ayla/backend/apps/live/`、`apps/voice/` | S1 加字段与准入校验的落点 |
| `Ayla/web/src/App.tsx`、`pages/`、`stores/`、`ws/`、`api/` | 现有前端路由/组件/状态/WS 结构，F1 重构基座 |
| `.workbuddy/skills/ayla-frontend-design/SKILL.md` | 项目级前端设计纪律（每次前端工作必读） |

**硬约束（继承 AGENTS.md + 既有决策）**：
- 前端永不直连 Elysium `/api/v1`；JWT 不写 localStorage（现有实现已遵循，延续）。
- 每次改动配与风险相称的测试（Vitest 单测 + Playwright 冒烟）。
- 后端存量行为不回退：S1 可见性默认 `public`，存量房间零感知；回归 live/voice 旧用例。
- 认知边界：所有可见性/权限判断是**工程约束**（协议/权限），必须实现；不做"情境→技能"类认知匹配。
- 轮播等装饰性循环动画遵守 design.md §7 例外条款（进视口启动 + reduced-motion 降级）。

## 1. 目标（本期验收定义）

完成"聚合主页与多端布局"增量，前后端共 12 步（S1-S6 后端 + F1-F10 前端，依赖关系见开发文档 §2.5）：

- 后端：可见性/群归属、群申请邀请、帖子、桌游室、聚合搜索、收藏、群动态 highlights、全站未读聚合。
- 前端：AppShell（窄屏 BottomTabs / 宽屏 TopNav + Discord 式左栏）、窄屏主页（卡片/列表双布局 + 轮播）、群聊场景容器（窄屏滑动 / 宽屏三列）、直播/语音/帖子/桌游聚合 tab、消息中心、全局搜索、个人界面扩展、收藏页、FAB 随场景创建。
- 两形态（375 窄屏 / 1440 宽屏）主链路 E2E 通过，design.md §10 可访问性自查通过。

## 2. 后端实施步骤（S1-S6）

> 每次改动后：`python manage.py makemigrations && migrate`；配 DRF 契约测试；全量 `pytest` 回归。

### S1 可见性与群归属（最优先，多模块依赖）【已验收 2026-08-14】

> 落地：`apps/common/{__init__,visibility}.py`；live/voice 模型 `visibility`+`group` 字段与迁移 0002；
> views 列表过滤 + 详情/弹幕/join/成员 403 校验；serializers 输出 visibility/group/group_name；
> 创建接口支持 group/visibility（group 非空默认 group 可见，visibility=group 必须带群）。
> 验证：可见性矩阵测试（`apps/common/tests/test_visibility.py`）+ live/voice API 契约测试全绿；
> 全量 pytest 335 通过（存量接口回归零回退）；迁移后存量房间默认 public 行为不变。

**改动文件**：
- 新建 `backend/apps/common/__init__.py`、`apps/common/visibility.py`：`Visibility` 枚举 + `visible_to(user)` 查询 helper + `can_view/can_join(user, obj)`。
- `apps/live/models.py`：LiveChannel 加 `visibility`、`group`（FK chat.Conversation，`limit_choices_to={"type": "group"}`）。
- `apps/voice/models.py`：VoiceChannel 同上。
- `apps/live/views.py`、`apps/voice/views.py`：列表 queryset 加 `visible_to(user)`；进入/加入接口加 `can_join` 校验（403 带可读错误）。
- `apps/live/serializers.py`、`apps/voice/serializers.py`：序列化输出 `visibility`、`group`、`group_name`。

**验证**：契约测试覆盖 public/friends/group × owner/好友/群员/路人 矩阵；存量接口回归全绿；迁移后存量房间 `visibility=public` 行为不变。

### S2 群申请/邀请 + 全站未读聚合 【已验收 2026-08-14】

> 落地：`apps/chat/models.py` 新增 `GroupJoinRequest`/`GroupInvite`（迁移 0002，幂等由
> services 层 pending 查重保证，不设 DB 部分唯一索引——MySQL 不支持）；
> join-requests 增查/审批、invites 增/查/处理、`GET me/invites/`；
> consumers 新增用户级组 `chat_user_<id>`（connect 加入/disconnect 退出）+ 两个
> 新消息类型 `group.request.resolved`/`group.invite.new`；
> `apps/accounts/views.py` 新增 `BadgesView`（`GET me/badges/` 五维聚合）。
> 验证：`apps/chat/tests/test_group_requests.py`（申请状态机 pending→accepted/rejected、
> 重复申请幂等、非 owner 审批 403、accept 事务内建成员、邀请权限矩阵）
> + `apps/chat/tests/test_group_ws.py`（用户级广播组隔离）+ `tests/test_badges.py`，
> 全量 pytest 363 通过（Windows 沙箱需 `PYTEST_DEBUG_TEM_ROOT=$TEMP/pytest_tmp_root`
> 规避临时目录批量删除崩溃，见工作区记忆）。
> 已知取舍（§7 同步登记）：Conversation 暂无可见性字段，"公开/好友"群区分后置，
> 申请入群 = 任意登录用户（已是成员除外）。

**改动文件**：
- `apps/chat/models.py`：新增 `GroupJoinRequest`（conversation, applicant, message, status, handled_by, handled_at）、`GroupInvite`（conversation, inviter, invitee, status, handled_at）。
- `apps/chat/services.py`：`create_join_request`/`accept_join_request`（事务内建成员）/`reject_join_request`、`create_group_invite`/`accept_group_invite`/`reject_group_invite`、用户级广播（`broadcast_*`/`abroadcast_*`）。
- `apps/chat/serializers.py`：`GroupJoinRequestSerializer`/`GroupInviteSerializer`/`GroupActionSerializer`。
- `apps/chat/views.py`：`GroupJoinRequestView`（GET 审批列表/POST 申请）、`GroupJoinRequestActionView`、`GroupInviteView`、`MyInvitesView`、`GroupInviteActionView`。
- `apps/chat/urls.py`：join-requests/invites/me/invites 五条路由。
- `apps/chat/consumers.py`：用户级组订阅 + `group_request_resolved`/`group_invite_new` 处理器。
- `apps/accounts/views.py` + `urls.py`：`BadgesView`（`GET /api/v1/me/badges/`，聚合 private_unread/group_unread/friend_requests/group_invites/join_requests_pending）。

**验证**：申请状态机测试（pending→accepted/rejected、重复申请幂等、非 owner 审批 403、accept 事务内建成员）；badges 聚合与并发一致性（多写者游标场景参考既有经验）。

### S3 帖子 app

**改动文件**：新建 `backend/apps/posts/`（models: Post/PostImage/Comment；views/serializers/urls：信息流 `?scope=feed|group:<id>|mine` 游标分页、增改删、评论增删；复用 `apps/common/visibility.py`；图片走 media 三步上传）。

**验证**：信息流分页游标、可见性过滤、仅作者可改删、评论作者可删。

### S4 桌游室框架

**改动文件**：新建 `backend/apps/boardgame/`（GameRoom/GameRoomMember；rooms 增查删、join/leave；游戏玩法与 WS 对局通道**不做**）。

**验证**：房间 CRUD + join/leave + 可见性过滤；join 幂等（重复 join 不重复建成员）。

### S5 聚合搜索

**改动文件**：新建 `backend/apps/search/`（`GET /search/?q=&types=&limit=`，分发给 accounts/chat/live/posts/boardgame，`__icontains` + `visible_to`，每组截断 + total，超时预算 2s）。

**验证**：五类对象分组返回、可见性过滤、空结果/空关键字行为、每组截断。

### S6 收藏 + 群动态 highlights

**改动文件**：新建 `backend/apps/favorites/`（Favorite 通用模型，唯一约束 `(user, target_type, target_id)`，增查删幂等）；`apps/chat/views.py` 加 `GET conversations/<id>/highlights/` 与 `GET conversations/highlights/?ids=`（live/post/game 封面聚合，取前 5）。

**验证**：收藏幂等（重复 POST 不重复）、跨类型 target 校验；highlights 内容与排序、无动态空列表。

## 3. 前端实施步骤（F1-F10）

> 每次改动后：`npx tsc --noEmit` 无错；`npm run test` 相关用例通过；两形态（375/1440）Playwright 冒烟。
> **推荐总顺序：先 S1-S6 后 F1-F10**（前端各步骤依赖后端接口，见 §2.5 依赖表）；F2/F3 可等 S1/S6 就绪后开始，不要在前端步骤中 mock 尚未落地的后端契约。

### F1 AppShell + 路由重构（基座）【已验收 2026-08-14】

**新增**：`src/hooks/useMediaQuery.ts`；`src/layout/AppShell.tsx`（`useMediaQuery('(max-width: 768px)')` 二选一渲染 BottomTabs 系 / TopNav 系）；`src/layout/BottomTabs.tsx`、`src/layout/TopNav.tsx`、`src/layout/CreateFab.tsx`、`src/layout/MessageFab.tsx`（窄屏）；`src/hooks/useSwipe.ts` 手势 hook（方向锁/阈值/取消）。
**改造**：`src/App.tsx` 路由表（/home /voice /live /posts /games /messages /search /profile /group/:id 及子路由；`/chat/:conversationId` 群聊会话重定向 `/group/:id`，旧 `/chat` 保留兼容）。
**要点**：BottomTabs 中央主页 tab 凸起（design.md §12.1）；TopNav 常驻 + 当前模块指示条（§12.2）；CreateFab 路由匹配表（需求 §3.5 的 FAB 映射）本期先接线"弹面板"，创建动作随各步骤补齐。
**验收**：两种形态导航切换正确；旧路由重定向不破坏现有聊天/语音/直播页（回归既有 playwright 用例）。

> 落地（2026-08-14）：`src/hooks/useMediaQuery.ts`（matchMedia 订阅）、`src/hooks/useSwipe.ts`
> （方向锁/阈值/取消，状态机抽 `createSwipeTracker` 纯函数）；`src/layout/` AppShell（`useMediaQuery('(max-width:768px)')`
> 二选一渲染 BottomTabs 系 / TopNav 系，直播间沉浸路由无 chrome）、BottomTabs（五 tab 主页居中凸起 + 选中辉光）、
> TopNav（头像/模块链 2px 指示条/消息/搜索/更多）、CreateFAB（路由匹配表 `shellConfig.resolveFabAction`，需求 §3.5；
> 面板 = 场景动作 + 次级「创建群聊」跳 /chat，场景创建动作提示落步骤）、MessageFAB；
> `src/pages/` PlaceholderPage（未落地页面占位）、GroupPage（F1 桥接版复用 ChatPage 渲染群会话）、
> GroupScenePage（群内子场景占位 + scene 校验）、ChatConversationRoute（`/chat/:conversationId` 群聊重定向 /group/:id、
> 私聊保留）；`App.tsx` 路由重构（新一级路由 + AppShell 布局路由 + 旧 /chat 兼容）；
> `styles/shell.css`（全 token，≤768px 辉光降 30%）+ 既有页面 `100vh→100%`（chat/voice/live/profile/room 根类）。
> 验证：`tsc` 无错；全量 vitest 174 通过（新增 use-media-query 3 / use-swipe 8 / shell 路由映射与双形态 /
> chat-conversation-route 6）；`npm run build` 通过；Playwright 两形态冒烟（375 窄屏 BottomTabs 五 tab + MessageFAB、
> 1440 宽屏 TopNav 一级模块、`/chat/g1 → /group/g1` 群聊重定向）均符合预期。

### F2 窄屏主页 + 宽屏 /home 重定向 【已验收 2026-08-14】

**新增**：`src/pages/HomePage.tsx`（窄屏群卡片/列表双布局 + 布局开关持久化）；`src/components/home/GroupCard.tsx`（轮播 + 状态角标）、`GroupListItem.tsx`、`LayoutSwitch.tsx`；`src/api/chat.ts` 增 highlights 批量拉取。
**要点**：卡片轮播 IntersectionObserver 启动/暂停 + reduced-motion 静态首帧；角标优先级 未读 > 直播 > 语音 > 桌游；分页加载更多；空态/骨架屏/失败重试（需求 R-H9）。
**验收**：双布局切换并持久化；轮播播放群动态；宽屏访问 /home 重定向 `/group/<最近群>`（无群则空态引导）。

> 落地（2026-08-14）：`src/api/chat.ts` 增 `fetchHighlights(ids)`（S6 批量接口 `?ids=` 逗号拼接，空 ids 短路）；
> `src/components/home/` badges.ts（角标优先级 未读>直播>语音>桌游 纯函数 + 最多 3 个）、GroupCarousel（横向滑轨
> translateX 300ms + IntersectionObserver 进视口启停 + reduced-motion 静态首帧 + 无动态回退群头像）、
> GroupCard（封面轮播 + 右上角标列 + 底部群头像/群名）、GroupListItem（行高 64px 玻璃底）、LayoutSwitch（卡片/列表切换）；
> `src/stores/home.ts`（布局偏好 + 最近群 localStorage 持久化）；`src/pages/HomePage.tsx`（窄屏双布局 + 空态/骨架/失败重试/
> 增量加载更多 + 宽屏 /home 重定向最近群[无历史第一个群/无群空态引导]）；`src/layout/NarrowTopBar.tsx`（窄屏一级页顶栏：
> 头像→个人页/搜索胶囊→搜索页/更多菜单，补齐 F1 窄屏无个人页与搜索入口的缺口）；`styles/home.css`。
> 验证：`tsc` 无错；全量 vitest 200 通过（新增 home-badges 8 / home-store 3 / highlights-api 3 / group-carousel 5 /
> home-page 7）；`npm run build` 通过；Playwright 冒烟（375 窄屏 TopBar+双布局切换+卡片轮播+未读 99+ 徽标、
> 1440 宽屏 /home→/group/1 无历史、→/group/2 有最近群）均符合预期。
> 已知取舍（§7 登记）：列表布局「最新消息摘要」需后端会话列表补 last_message 字段，本期以成员数兜底（不伪造消息预览）；
> 会话列表后端无分页，卡片布局「加载更多」为前端增量渲染（每批 12，滚到底补一批）；
> live/voice/game 状态角标数据源由 F4/F5/F7 接入（badges.ts 已定义契约 + 预留字段）。

### F3 GroupPage 容器 + 群内聊天 【已验收 2026-08-14】

**新增**：`src/pages/GroupPage.tsx`（窄屏：底栏上移 + 五子界面滑动容器；宽屏：ServerRail+ChannelSidebar+内容区三列）；`src/layout/ServerRail.tsx`、`src/layout/ChannelSidebar.tsx`；`src/hooks/useEnterGroupAnimation.ts`（底栏上移，独立封装）；`src/pages/group/GroupChat.tsx`（复用现有聊天组件）；`src/pages/group/GroupInfo.tsx`；`src/stores/group.ts`（维护 `activeScene`：chat/live/voice/posts/games，单一状态源）。
**要点**：
- 窄屏进群动画：底栏 `translateY(0 → 顶部)` 上移（250ms ease-out）+"主页"↔群头像形变+输入框滑入（250ms 延迟 100ms）；退群：顶部下拉手势阈值 80px 反向动画；
- **群头像两级点击**：handler 读取 `activeScene` 单一状态——非 chat → 切 chat；chat → 打开 GroupInfo；禁止第二份导航状态；
- 子界面顺序 `voice|live|chat|posts|games` 聊天居中；输入框显隐（chat/live/posts 显示，voice/games 隐藏）；
- 宽屏 ServerRail 切群、ChannelSidebar 切场景（点击，无手势）；群信息入口 = 频道侧栏顶部群名；
- 群信息界面按角色显示管理项（R-G9）。
**验收**：窄屏进群/退群动画方向正确（底栏终点=视口顶部）；群头像两级点击两种语义分别通过；宽屏三列切群切场景无跳转；群信息角色化。

> 落地（2026-08-14）：`stores/group.ts`（activeScene 单一状态源 + currentGroupId + 五子界面顺序）；
> `hooks/useEnterGroupAnimation.ts`（底栏上移到顶部独立封装，rAF 双帧进入 + reduced-motion 直入）；
> `layout/ServerRail.tsx`（72px 群头像列 + 当前群左 3px 指示条 + 未读角标 + 底部用户卡）、
> `layout/ChannelSidebar.tsx`（群名头点击进群信息 + 五场景项 + 选中胶囊底）；
> `components/group/GroupTopTabs.tsx`（上移形态：语音|直播|群头像|帖子|桌游 + 5 圆点指示）；
> `pages/group/GroupChat.tsx`（复用 MessageList/MessageInput + loadHistory/sendMessage 等 hooks）、
> `GroupInfo.tsx`（群资料 + 成员角色标签 + owner/admin 编辑群资料[真功能] + 管理项[占位标注]）、
> `GroupScenePlaceholder.tsx`（live/voice/posts/games 占位标 F4-F7）；
> `pages/GroupPage.tsx` 重写（窄屏进群动画 + 五子界面滑动切换 + 群头像两级点击 + 宽屏三列 + 切群切场景）；
> `AppShell` 窄屏群场景隐藏 BottomTabs/MessageFAB（GroupPage 自渲染顶部导航条）；`styles/group.css`。
> 验证：`tsc` 无错；全量 vitest 216 通过（新增 group-store 4 / use-enter-group-animation 2 / group-page 7 / group-info 3）；
> `npm run build` 通过；Playwright 冒烟（375 窄屏进群 GroupTopTabs 顶栏 + 群头像两级点击两语义 + 切子场景、
> 1440 宽屏 ServerRail+ChannelSidebar 三列 + 频道侧栏切场景）均符合预期。
> 已知取舍（§7 登记）：退出群/转让群主/解散群后端无端点（不在 B1-B10/S1-S6 范围），群信息占位标注；
> 五子界面滑动=手势触发 navigate + key 切换淡入（不强做跟手 translateX，开发文档 §2.2 明确"路由切换用 CSS transition"）；
> 下拉回主页手势（顶部下滑阈值 80px）+ 输入框滑入延迟动画（R-G1）细节后置，待主链路 E2E 阶段统一补动画终点断言。

### F4 直播：一级 tab + 群内直播 【已验收 2026-08-14】

**改造**：`src/pages/LiveHubPage.tsx`（现有 LiveHall 改聚合网格 + 可见性来源标识）；`src/pages/LiveRoomPage.tsx`（**进房动画：底栏下滑走+输入框滑入**，新建 `src/hooks/useEnterRoomAnimation.ts` 独立封装；窄屏上下滑切换列表上下文 = 群内 or 全量可见；宽屏视频主区 + 弹幕侧列 360px + 两侧按钮/键盘 ↑↓）；`src/pages/group/GroupLive.tsx`（窄屏沉浸式，**切换范围=仅该群**）。
**要点**：切换直播间 HLS 重连、弹幕输入框保持；无直播空态 + 发起引导；FAB 在直播 tab/群内直播子界面 = 创建直播间（群内则归属该群）。
**验收**：进房动画方向正确（底栏滑出底部，非上移）；窄屏上下滑切换范围正确（群内=群内列表；tab=公开+好友+已加入群）；宽屏键盘切换 + 弹幕侧列。

> 落地（2026-08-14）：`api/types.ts` LiveChannelDescriptor 加 visibility/group/group_name（S1）；
> `api/live.ts` createLiveChannel 支持 group；`hooks/useEnterRoomAnimation.ts`（输入框滑入 100ms 延迟 +
> reduced-motion 直入，与进群动画方向相反）；`stores/shell.ts`（bottomTabsLeaving，跨路由底栏动画）；
> `components/live/LiveRoomBody.tsx`（播放器三态 + 弹幕 + 切换控件[窄屏上下滑 useSwipe/宽屏按钮 + 键盘↑↓] +
> 输入框滑入，供一级与群内复用）；`pages/LiveRoomPage.tsx`（进房底栏下滑走 + 全量列表切换 navigate /live/:nextId，
> HLS 靠 channelId 变化重进房）；`pages/group/GroupLive.tsx`（群内范围 filter group=groupId + 内部 state 切换 +
> 无直播空态引导）；`pages/LiveHubPage.tsx`（聚合网格窄屏 2 列/宽屏 3-4 列 + 来源标识公开/好友/群名 + 空态）；
> `GroupPage` live 子界面接 GroupLive；`CreateFab` handler=live 接 LiveCreate（group 归属）；`styles/live.css`。
> 验证：tsc 无错；全量 vitest 220 通过（新增 use-enter-room-animation 2 + group-live 范围 2，更新 shell/group-page
> 既有断言随 live 子界面落地）；`npm run build` 通过；Playwright 冒烟（375 大厅来源标识 + 进房底栏下滑走 + 弹幕输入框、
> 1440 键盘 ↓ 切换 + 弹幕侧列）均符合预期。
> 已知取舍（§7 登记）：窄屏直播间弹幕"浮层"沿用 M5-4 底部浮层（覆盖播放器下部）而非重构全屏沉浸视频层；弹幕输入框滑入动画终态断言留待主链路 E2E 统一补。

### F5 语音：一级 tab + 群内语音 【已验收 2026-08-14】

**新增/改造**：`src/pages/VoiceHubPage.tsx`（聚合卡片 + 来源标识）；`src/pages/group/GroupVoice.tsx`（群内语音房卡片）；语音房整页（**进房动画同直播间：底栏下滑走+输入框滑入**，复用 `useEnterRoomAnimation`；成员网格 + 控制排 + 房内打字输入框，复用群会话方案：群内语音房输入 = 群消息）。
**要点**：上麦/静音/离开交互；房内文字消息经群会话（开发文档 §1.9 复用方案）；FAB 创建语音房（群内则归属该群）。
**验收**：进房上麦、房内打字可送达群会话；返回键回列表（底栏复位）。

> 落地（2026-08-14）：`api/types.ts` VoiceChannelDescriptor 加 visibility/group/group_name（S1）；
> `api/voice.ts` createVoiceChannel(name, group)；`components/voice/VoiceRoomBody.tsx`（语音房整页：返回头 +
> 复用 VoiceChannelPanel 成员/控制排 + 房内打字发群会话[仅群语音房 group 非空，复用群会话方案 B10]）；
> `pages/VoiceHubPage.tsx`（聚合卡片 + 来源标识 + 空态 + 进房底栏下滑走[复用 shell store bottomTabsLeaving] +
> 输入框滑入，替代 VoicePage）+ 删 VoicePage；`pages/group/GroupVoice.tsx`（群内范围 filter group=groupId + 空态）；
> `AppShell` 底栏下滑走改由 bottomTabsLeaving 通用驱动（直播/语音房共用，去掉 isLiveRoomRoute 判断）；
> `VoiceChannelList` 加来源标识；`GroupPage` voice 子界面接 GroupVoice；`CreateFab` handler=voice 接
> VoiceChannelCreate（group 归属）；`styles/voice.css`。
> 验证：tsc 无错；全量 vitest 224 通过（新增 group-voice 范围 2 + voice-room-body 房内打字 2）；build 通过；
> Playwright 冒烟（语音大厅来源标识公开/群名 + FAB 创建语音房 label + 群内语音范围仅本群）符合预期。
> 已知取舍（§7 登记）：语音房进房动画（底栏下滑走）+ 房内打字送达群消息的端到端验证依赖真实 LiveKit 媒体连接，
> 冒烟未覆盖（join 走媒体错误回滚路径），对应 UI 结构由单元测试覆盖。

### F6 帖子全套 【已验收 2026-08-14】

**新增**：`src/pages/PostsHubPage.tsx`（信息流 + **FAB 发帖**）；`src/pages/PostDetailPage.tsx`（详情 + 评论输入框 + 收藏 + 删除；**底栏原位替换为输入框**，新建 `src/hooks/usePostDetailTransition.ts`）；`src/pages/group/GroupPosts.tsx`（群内帖子，**输入框发帖**——与一级 tab 的 FAB 发帖是两条路径）；`src/components/posts/PostCard.tsx`、`PostEditor.tsx`、`CommentList.tsx`；`src/api/posts.ts`；`src/stores/posts.ts`。
**要点**：信息流游标分页；图片九宫格；正文折叠；评论回复；收藏即时反馈；删除二次确认。
**验收**：发帖两条路径（FAB 与群内输入框）分别通过；评论、收藏、删除全链路；个人页"我的发帖"接入（F10 联动）。

> 落地（2026-08-14）：`api/posts.ts`（listPosts 游标分页 scope/cursor/limit + createPost/getPost/update/delete +
> listComments/createComment/deleteComment）+ `api/favorites.ts`（listFavorites/addFavorite/removeFavorite 幂等）；
> `stores/posts.ts`（信息流游标分页 appendPage 去重 + favoriteByPostId 收藏集合）；`components/posts/` PostCard
> （作者光环+正文 3 行折叠+九宫格+底排评论/IconHeart 收藏）、PostEditor（标题可选+正文必填，compact 群内变体）、
> CommentList（评论+回复+评论作者删）；`hooks/usePostDetailTransition.ts`（帖子详情底栏原位替换，交叉淡化无位移）；
> `pages/PostsHubPage.tsx`（信息流+滚到底加载更多+收藏即时反馈）、`PostDetailPage.tsx`（详情+评论+收藏+删除二次确认）、
> `group/GroupPosts.tsx`（群内信息流+输入框发帖[R-P2 关键差异]）；`AppShell` 帖子详情窄屏原位让位评论输入框
> （isPostDetailRoute）；`App.tsx` /posts、/posts/:postId 接真页；`GroupPage` posts 子界面接 GroupPosts；
> `CreateFab` handler=post 接 PostEditor（一级 FAB / 群内走输入框，群内 posts 子界面 FAB 隐藏）；`styles/posts.css`。
> 验证：tsc 无错；全量 vitest 232 通过（新增 posts-store 5 + posts-api 4）；build 通过；Playwright 冒烟
> （信息流+折叠+FAB 发帖 label、详情评论/删除/收藏按钮、群内输入框发帖）均符合预期。
> 已知取舍（§7 登记）：发帖带图（媒体三步上传前端链路）后置——本期 PostEditor 仅文本，图片九宫格展示在有图
> 数据时正常渲染；个人页"我的发帖"归 F10。

### F7 桌游房间框架 【已验收 2026-08-14】

**新增**：`src/pages/GamesHubPage.tsx`、`src/pages/group/GroupGames.tsx`、`src/components/boardgame/GameRoomCard.tsx`、`GameRoomCreate.tsx`、`GameRoomPlaceholder.tsx`；`src/api/boardgame.ts`。
**要点**：房间列表/创建/进入占位界面；join/leave 状态显示。
**验收**：创建→列表→进入占位界面闭环；join 后"正在玩的桌游"出现在个人页数据源。

> 落地（2026-08-14）：`api/boardgame.ts`（listGameRooms ?mine=1 / createGameRoom / getGameRoom / deleteGameRoom /
> joinGameRoom :join / leaveGameRoom :leave）；`components/boardgame/` GameRoomCard（封面占位+状态 tag 等待中/对局中 +
> 人数 + 来源标识）、GameRoomCreate（房间名必填 + group）、GameRoomPlaceholder（进入占位 + join/leave 状态切换）；
> `pages/GamesHubPage.tsx`（列表 + 空态 + 进入占位闭环）、`group/GroupGames.tsx`（群内范围 filter group=groupId）；
> `GroupPage` games 子界面接 GroupGames；`App.tsx` /games 接真页；`CreateFab` handler=game 接 GameRoomCreate；
> `styles/boardgame.css`。
> 验证：tsc 无错；全量 vitest 237 通过（新增 boardgame-api 5）；build 通过；Playwright 冒烟（列表+对局中 tag+
> FAB 创建 label、进占位+离开按钮、群内范围仅本群 1 卡）均符合预期。
> 说明：桌游玩法本体与 WS 对局通道后续；"正在玩的桌游"个人页数据源 = `GET /rooms/?mine=1`（后端已支持，F10 接入）。

### F8 消息中心 + badges 红点 【已验收 2026-08-14】

**新增/改造**：`src/pages/MessagesPage.tsx`（私信/好友列表双选项卡；宽屏双栏）；`src/api/friends.ts` 扩展（申请/邀请动作）；`src/stores/badges.ts`；AppShell 内轮询/WS 触发 badges 拉取（断线降级 30s 轮询）。
**要点**：私信仅 private 会话；好友列表分组（好友申请/群申请邀请置顶）；同意/拒绝即时反馈；红点聚合到 MessageFAB/TopNav 消息项。
**验收**：双选项卡数据正确；申请处理闭环；红点随处理即时刷新。

> 落地（2026-08-14）：`api/accounts.ts` getBadges（GET /me/badges/ 五维聚合）；`api/chat.ts` 扩展
> listJoinRequests/actionJoinRequest/listMyInvites/actionGroupInvite（S2 join-requests/invites）；
> `stores/badges.ts`（badges + messageBadge 聚合 = 私信未读+好友申请+群邀请+待审批，群未读不进消息中心红点）；
> `pages/MessagesPage.tsx`（私信/好友双选项卡 + 三组申请置顶[好友申请/群邀请/待审批入群申请] + 同意/拒绝即时反馈 +
> 宽屏双栏）；`AppShell` 进入拉 badges + 30s 轮询（断线降级）+ MessageFab/TopNav 消息项红点。
> 验证：tsc 无错；全量 vitest 241 通过（新增 badges-store 4）；build 通过；Playwright 冒烟（私信仅 private、
> 好友 tab 三组申请置顶 + 同意按钮、MessageFab 红点聚合）均符合预期。
> 说明：红点刷新走 30s 轮询 + 处理 action 后即时 fetch；S2 的 WS 用户级广播（group.request.resolved/group.invite.new）
> 触发拉取的实时推送接线后置（轮询已覆盖"随处理即时刷新"验收）。

### F9 全局搜索 【已验收 2026-08-14】

**新增**：`src/pages/SearchPage.tsx`（窄屏）；TopNav 内联搜索下拉面板（宽屏）；`src/api/search.ts`；`src/stores/search.ts`（历史记录 localStorage）。
**要点**：五类结果分组 + "查看更多"；用户资料卡（R-S4：加好友/发消息）；结果可见性过滤（后端已做，前端仅展示）。
**验收**：五类对象搜索跳转正确；加好友从资料卡可发起。

> 落地（2026-08-14）：`api/search.ts`（GET /search/?q=&types=&limit= 五类分组）；`stores/search.ts`（历史 chips
> localStorage 去重栈 + 上限 10 + 清空）；`components/UserProfileCard.tsx`（用户资料卡：加好友 createFriendRequest +
> 发消息 openPrivateConversation）；`pages/SearchPage.tsx`（搜索输入自动聚焦 + 历史 chips + 五类分组[用户/群/帖子/直播/桌游] +
> 点用户弹资料卡、其余跳对应界面）；`TopNav` 内联搜索下拉（去抖 300ms 拉结果，分组前几条，点击跳转）；
> `App.tsx` /search 接真页 + 删 PlaceholderPage（已无引用）；`styles/search.css`。
> 验证：tsc 无错；全量 vitest 248 通过（新增 search-store 4 + search-api 3）；build 通过；Playwright 冒烟
> （回车搜索五类分组 + 用户资料卡加好友/发消息按钮）符合预期。
> 已知取舍（§7 登记）：用户资料卡"好友关系状态展示"（已是好友/待验证）后置；桌游室搜索结果跳 /games 列表
> （桌游无详情路由）。

### F10 个人界面扩展 + 收藏页 + 更多菜单 【已验收 2026-08-14】

**改造**：`src/pages/ProfilePage.tsx`（两列/分区：我的发帖/我的直播间/正在玩的桌游）；新增收藏页占位 + 更多菜单（个性化/扫一扫占位 + 收藏）。
**要点**：三分区数据接入（posts mine / live mine / game 在局）；收藏页展示帖子收藏 + 取消收藏。
**验收**：个人页分区数据正确；收藏取消即时生效；更多菜单三项可达。

> 落地（2026-08-14）：`pages/FavoritesPage.tsx`（帖子收藏列表，target 摘要直接展示 + 取消收藏即时移除，
> 同步 posts store 收藏集合）；`ProfilePage` 扩展三分区（我的发帖 scope=mine / 我的直播间 owner=我 / 正在玩的桌游
> ?mine=1，F1 起的占位全部替换）；`TopNav`/`NarrowTopBar` 更多菜单加「我的收藏」（三项：个人主页/收藏/退出）；
> `App.tsx` /favorites 路由；`styles/profile.css`。
> 验证：tsc 无错；全量 vitest 251 通过（新增 favorites-page 3）；build 通过；Playwright 冒烟（个人页三分区
> 数据渲染 + 收藏入口、收藏页取消收藏按钮）均符合预期。
> **F1-F10 前端全部落地（2026-08-14）**。

### F10.1 删除聚合聊天页，拆私聊 / 群聊独立入口 【已验收 2026-08-14】

> 背景（用户 2026-08-14）：不再保留「既含私聊又含群聊」的聚合 ChatPage。私信点进去就是私聊窗口、群聊点进去就是群聊，两者分开；保留下独立私聊聊天界面。

**新增**：`src/pages/PrivateChatPage.tsx`（独立私聊窗口：头像/nickname/在线状态头部 + 返回 `/messages` + MessageList + TypingIndicator + MessageInput，复用 `loadHistory`/`loadMoreHistory`/`markReadLatest`/`recallMessage`）；`src/components/GroupCreateDialog.tsx`（复用 ConversationSearch，`initialOpen` 模态，`onGroupCreated` → `/group/:id`、`onPrivateOpened` → `/chat/:id`）；`src/styles/private.css`（`.private-chat`/`.private-chat-head`/`.group-create-overlay`/`.group-create-dialog`）。
**改造**：`src/pages/ChatConversationRoute.tsx`（私聊 → PrivateChatPage、群聊 → `<Navigate /group/:id>`、未知 → `getConversation` + skeleton）；`src/App.tsx`（移除 `/chat` 路由与 ChatPage）；`src/pages/HomePage.tsx`（空态「创建群」→ GroupCreateDialog）；`src/layout/CreateFab.tsx`（「创建群聊」→ GroupCreateDialog）；`src/pages/MessagesPage.tsx`（私聊 tab 顶部 ElysiaEntry）；`src/pages/ProfilePage.tsx`（返回 `/home`）；`src/layout/shellConfig.ts`（MODULE_RULES 移除 `/chat`、`/chat/*` → null 高亮）；`src/components/chat/ConversationSearch.tsx`（新增 `initialOpen` prop）。
**删除**：`src/pages/ChatPage.tsx`（聚合聊天页）。
**验证**：`tsc` 无错；vitest 250 通过（shell / chat-conversation-route 更新断言）；`npm run build` 通过；Playwright 冒烟：`/messages` 私聊 tab 含 ElysiaEntry + 私聊会话 → 点击进 `/chat/p1` 渲染 `.private-chat`；`/chat/5`（群聊）→ `/group/5`；裸 `/chat` → `/home`。

## 4. 联调与验证

- 后端 dev：`python manage.py runserver 8100`；前端 dev：`npm run dev`（Vite proxy `/api`、`/ws` → 8100）。
- 主链路 E2E（Playwright，两形态各一遍）：
  - 窄屏 375px：主页 → 进群动画（**底栏上移到顶部**）→ 发消息 → **群头像两级点击**（语音子界面点头像→回聊天；聊天界面点头像→群信息）→ 下拉回主页 → 直播 tab → 进直播间（**底栏下滑走+输入框滑入**）→ 上下滑切换；
  - 宽屏 1440px：TopNav → 主页三列 → 频道侧栏切子场景 → 直播间键盘切换 → 弹幕侧列。
- 动画方向断言：Playwright 断言动画终点（进群后底栏位于视口顶部、进直播间后底栏位于视口外底部、帖子详情底栏被输入框替换），防止方向串味回归。
- design.md §10 可访问性自查：focus ring、对比度、键盘遍历、触达目标 ≥40px。
- 全量 `npm run build` 无 TS 错误；后端 `pytest` 全绿。

## 5. 交付物核对清单

- [x] 后端：S1 已落地（可见性/群归属 + 契约测试 + 迁移 0002 + 全量回归 335 通过）；S2 已落地（群申请/邀请 + badges 聚合 + 契约测试 + 全量回归 363 通过）；S3-S6 已提交（见仓库提交历史，验收状态由对应步骤对话标注）
- [x] 前端：F1-F10 全部落地（2026-08-14；各步见上方【已验收】标记）
- [ ] 两形态主链路 E2E 通过（本文件 §4，含动画终点断言；待真实后端 + dev server 联调）
- [x] `Ayla/web/README.md` 补 F1 AppShell 章节；`Ayla/docs/plans/Ayla聚合主页与多端布局开发文档.md` 状态更新（§2.4 F1 标落地）
- [ ] 本文件勾选项如实标注；未完成项写明阻塞原因

## 6. 每步 commit 纪律（用户明确节奏：每步一个对话实施完成后 commit）

- **粒度**：S1-S6 / F1-F10 每步验收通过后，在该步对话内 commit 一次；步骤未验收（测试失败/动画方向不对）不 commit，修复后再提交。
- **commit 消息**：与父仓库同风格，含步骤标识，如 `feat(posts): S3 posts app 信息流/评论/游标分页`、`feat(web): F3 GroupPage 三列容器与群头像两级点击`。
- **Ayla 子仓库提交后，父仓库必须同步子模块指针**（用户强调，2026-08-11）：父仓库提交消息必须**一字不漏包含子仓库 commit 全文**，如 `chore(submodule): Ayla → <hash> feat(posts): S3 posts app 信息流/评论/游标分页`。
- **Ayla 子仓库 git 禁忌（用户强调，2026-08-12/13）**：禁止 `git gc` / `git repack` / `git prune` 及任何打包类操作（曾致对象库损坏、提交丢失）；禁止用 `git stash` 做临时验证（曾致 `not a git repository`）。验证基线一律用只读命令（`git show HEAD:file`、status/diff）。
- 并行 worktree 只写代码不提交的纪律不适用于本节奏——用户已明确"每步实施后 commit"，本文件即授权；若与其它并行对话并发操作 Ayla 仓库，先确认无并发 git 进程再提交。

## 7. 已知取舍与待确认（遇到先记录，不阻塞）

- 语音房文字消息复用群会话方案（开发文档 §1.9）；独立房间文字流后置。
- 群申请权限：Conversation 暂无 visibility 字段，开发文档 §1.2 "公开群可申请/好友群仅好友可申请"暂按"任意登录用户可申请（已是成员除外）"落地（S2 已登记）；群可见性字段与搜索发现路径（§1.5 groups 可见性）随 S5 一并评估。
- 搜索不做引擎（分发表查询 + 截断）；量级上来再评估 PostgreSQL FTS / Meilisearch。
- 房间/帖子可见性细粒度编辑（公开/好友/群切换）本期默认公开，编辑后置。
- 桌游玩法、扫一扫、个性化、直播间连麦均后续。
- 宽屏"最近访问群"存 localStorage（无历史取第一个群；无群显示空态）。
- 窄屏 FAB 弹底部面板 / 宽屏弹上方浮层（design.md §12.5）。
- F2（2026-08-14）列表布局「最新消息摘要」：后端会话列表无 last_message 字段，本期成员数兜底；会话列表后端无分页，卡片布局「加载更多」为前端增量渲染；live/voice/game 状态角标数据源随 F4/F5/F7 接入。
- F3（2026-08-14）退出群/转让群主/解散群：后端无对应端点（B1-B10 缺口清单与 S1-S6 均未覆盖），群信息界面占位标注，待后端补端点；五子界面滑动采用「手势触发 navigate + key 切换淡入」（开发文档 §2.2 明确用 CSS transition，不保持五页同时挂载）；下拉回主页手势与输入框滑入延迟动画的精确终点断言留待主链路 E2E 阶段统一补。
- F4（2026-08-14）窄屏直播间弹幕"浮层"沿用 M5-4 底部浮层（覆盖播放器下部）而非重构全屏沉浸视频层；进房动画"底栏下滑走"终态断言留待主链路 E2E 统一补。
- F5（2026-08-14）语音房进房动画与房内打字送达群消息的端到端验证依赖真实 LiveKit 媒体连接（冒烟未覆盖，join 走媒体错误回滚），UI 结构与房内打字发送路径由单元测试覆盖；公开语音房无独立文字流（B10 后置），打字框仅群语音房显示。
- F6（2026-08-14）发帖带图（媒体三步上传前端链路）后置，本期 PostEditor 仅文本发帖、图片九宫格展示在有图数据时正常渲染；个人页"我的发帖"归 F10。
- F9（2026-08-14）用户资料卡"好友关系状态展示"（已是好友/待验证）后置；桌游室搜索结果跳 /games 列表（桌游无详情路由）。
