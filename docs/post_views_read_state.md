# 帖子浏览量与已读未读（同源）设计说明

> 状态：已实现（2026-08-26）。范围：`backend/apps/posts/`、`backend/apps/chat/serializers.py`、`web/src/`。

## 语义

- **浏览与已读同源**：`PostView`（`post_views` 表，`unique(post, user)`）既是浏览去重记录，也是已读记录。
  存在记录 = 该用户浏览过（已读）；不存在 = 未读（仅群内场景展示）。
- **每人每帖最多 1 次**：`unique` 约束 + `get_or_create` 兜底；`Post.view_count` 为冗余计数，事务内 `F()` 递增。
- **作者自己不计浏览、天然已读**：`record_post_views` 跳过 `owner=user`；`is_viewed` 对作者恒 `true`；
  群未读计数排除自己发的帖子。
- **窗口内看到即浏览**：前端 `usePostViewTracking` 用 IntersectionObserver 观察 `[data-post-id]` 元素，
  进入视口即批量上报（300ms 去抖），无需点击进入详情。

## 接口

- `POST /api/v1/posts/views/`：批量上报浏览。入参 `{post_ids: [..]}`（≤100），
  返回 `{updated: {post_id: 最新 view_count}}`（仅本次实际新增浏览的帖子，幂等）。
- `PostSerializer` 新增输出：`view_count`、`is_viewed`（列表已 annotate `_viewed` 避免 N+1）。
- `ConversationSerializer`（会话列表/详情）新增输出：`post_unread_count`（群内未读帖子数，私聊恒 0）。

## 群内未读红点（已读未读不显示在群外）

- 未读帖子 = 该群可见（`allowed_groups` 白名单）且我无 `PostView` 记录的帖子（排除自己发的）。
- 宽屏 `ChannelSidebar` 帖子场景项：有未读帖子时显示粉色圆点。
- 宽屏 `ServerRail` 群头像徽标 = 消息未读 + 帖子未读（数字，99+ 截断）。
- 窄屏主页群卡片/列表徽标 = 消息未读 + 帖子未读（数字）。
- 窄屏群内顶部「帖子」tab：有未读帖子时显示粉色圆点。
- 群卡片轮播帖子卡「有新帖」徽标：仅当该群有未读帖子时显示（不再按 24h 窗口近似）。

## 群内帖子列表未读跳转标签

- 进入群内帖子列表时连续拉页直到覆盖全部未读（上限 10 页，防极端数据）。
- 未读帖子 = 列表数据中 `is_viewed=false` 的；滚动容器上方/下方有未读时显示
  「↑/↓ N 条未读帖子」胶囊标签（复用聊天界面 `message-jump-tags` 语言与样式），点击滚动到最近的未读帖子。
- 每看到一条（进入视口）即上报已读，标签与红点实时减少；视口内全部看完后标签消失。

## 数据流

- 初始：会话列表 `post_unread_count`（权威）→ chat store → 各红点。
- 浏览上报成功：posts store 标记 `is_viewed`/更新 `view_count`；按帖子白名单群递减 `post_unread_count`
  （GroupPosts 本地 `groupPosts` 同步已读态，标签实时更新）。
- WS `post.created`：非作者本人时对应群 `post_unread_count +1`（作者自己发的天然已读不计）。
- WS `post.viewed`（浏览/已读实时广播，跨端热更新）：
  - 发往帖子可见范围（allowed_groups 群组频道 + public 全局信息流组）：所有用户刷新 `view_count`
    （浏览量数字实时变化，列表/详情订阅 store 或本地 state 自动更新）；
  - 发往浏览者本人频道 `chat_user_<id>`：同账号多端同步已读态（`is_viewed` + 群未读红点递减 +
    群内未读跳转标签减少），已读是私有状态不广播给他人。
  - 事件：`{type: "post.viewed", data: {post_id, view_count, viewer_id, allowed_group_ids}}`。
- 群侧栏（宽屏 ChannelSidebar 帖子项）红点显示**未读帖子数量**（数字徽标，99+ 截断）。

## WS 事件契约（重要：consumer 必须注册 handler）

`channels` 的 `group_send` 事件到达消费者后按 `event["type"]` 分发到对应方法
（点号转下划线）。**新增任何 `post.*` 事件类型必须在 `apps/chat/consumers.py`
注册同名 handler**（`async def post_viewed(self, event): await self.send_json(event)`）——
否则 Channels 抛 `No handler for message type xxx` 导致整个消费者崩溃 → WS 断连 →
前端自动重连触发 resume 补发历史消息 → 已读消息红点风暴（线上 Bug，2026-09-02 已修）。

## 已修复 Bug（2026-09-02）

1. **发 1 帖出现 2 个红点**：`PostListView.post` 曾对归属群 + 白名单各广播一次
   `post.created`（归属群也在白名单里）→ 同群收到两次事件 → 未读 +2。
   修复：广播目标合并去重；前端 `markPostCreatedHandled` 30s 幂等窗口兜底。
2. **浏览后左侧栏红点风暴**：`post.viewed` 无 consumer handler → 消费者崩溃 → WS 断连重连
   → resume 补发已读消息 → 红点疯狂跳动。修复：注册 `post_viewed` handler。
3. **同一浏览未读被减 3 次**（REST 响应 + 群组频道事件 + 本人频道事件）→ 批量浏览时数字跳变。
   修复：红点递减只走 WS 一条路径（`usePostViewTracking`/`PostDetailPage` 不再本地减红点），
   本人已读按 postId 去重（`markPostViewedHandled`）。
4. **`CreatePostSerializer.allowed_group_ids default=list` 破坏归属群兜底**：未传时变成空列表
   覆盖 `services.create_post` 的「group 归属 → 白名单=[group.id]」→ 群帖对群员不可见。
   修复：去掉 default（未传保持 None 走兜底）；`create_post` 对 group 可见但白名单为空直接报错。

## 迁移

`posts.0005_post_view_count_postview`：`Post.view_count`（PositiveIntegerField, default 0）+ `PostView` 表。
