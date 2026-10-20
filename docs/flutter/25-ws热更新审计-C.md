# 审计 C：帖子域四帧 + 帖子/评论列表热更新

> 只读审计（2026-10-19）。范围：`Ayla/flutter/lib/core/ws/posts_frames.dart`、`lib/state/posts_store.dart`、
> `lib/pages/{posts_hub_page,group_posts_page,post_detail_page,search_page}.dart`。
> 事实源：`Ayla/web/src/ws/chat.ts`、`stores/posts.ts`、`pages/PostsHubPage.tsx`、`pages/group/GroupPosts.tsx`、
> `pages/PostDetailPage.tsx`、`hooks/usePostComments.ts`、后端 `apps/posts/{services,views}.py` + `apps/chat/consumers.py`。
>
> **结论提要（TL;DR）**
> 1. `post.created / post.deleted / post.updated / post.viewed` 四条分支的**逐行语义与 web 等价**（含 REST 对账、
>    30s 去重、`allowed_group_ids` 口径、403/404 静默）——**这四条不是缺陷**。
> 2. `comment.created / comment.deleted` 在 Flutter 的 `kAylaChatWsOutOfBatchFrames` 里「显式忽略」**不是缺陷**：
>    web 的 `chat.ts:841–844` 本身就是 `break` 空实现，真正的消费方是**帖子详情页自己的 onFrame**
>    （`usePostComments.ts:129–133`）；Flutter 在 `post_detail_page.dart:218 / 268–324` **已有等价实现**。
> 3. **头号根因候选（代码缺陷，可静态确认）**：帖子帧桥只在 `main.dart:262` **进程启动期 attach 一次**；
>    而登出链会 `detach()`（`room_providers.dart:469/484`），**再登录时没有任何代码重新 attach**
>    （`aylaStartPostsFramesForRef` 全仓 **0 个调用点**）。⇒ **登录过一次 → 登出 → 再登录之后，帖子域四帧永久失效**，
>    直到杀进程重启。同一缺陷同样作用于 `room_frames.dart` 的目录帧桥（`aylaStartRoomFramesForRef` 同样 0 调用）。
> 4. 「发帖后列表不自动刷新」有第二条独立缺陷链：发帖走 `context.go(...)` **卸载**列表页 ⇒ 页面级 `_onFrame`
>    收不到 `post.created`；全局桥只写 `aylaPostsStore`（列表页**不读**它）；返回时
>    `AylaPostTabCache.shouldLoad` 的 **60s 新鲜窗口**又阻止重拉 ⇒ 最长 60 秒看不到新帖。

---

## 1. 四帧等价性表（web `ws/chat.ts` ↔ Flutter `core/ws/posts_frames.dart`）

后端已确认**四条帧都会下发且消费者已注册**：`apps/chat/consumers.py:639–665`（post_created / post_deleted / post_updated / post_viewed / comment_created / comment_deleted 全部 `send_json(event)`）。
`post.created` 的广播范围包含**作者本人**（`apps/posts/services.py:342–373` 的 `broadcast_post_created_to_user` ⇒ `chat_user_{user.id}`），
所以「自己发的帖子也会收到回环帧」这一前提成立。

| 帧 | web（文件:行） | Flutter（文件:行） | 等价 | 差异 |
|---|---|---|---|---|
| `post.created` | `chat.ts:766–791`：帧只当**失效信号**，拉 `GET /posts/<id>/` ⇒ `upsertPost` ⇒ `bumpGroups(visibleGroupIds)` ⇒ 非作者则按 `allowed_group_ids` 每群 `adjustPostUnread(+1)`（`markPostCreatedHandled` 30s 去重，`chat.ts:41–61`）；`.catch` 静默 | `posts_frames.dart:113–118` → `_reconcilePost` `138–173`：REST → `upsertPost`(151) → `_bumpGroups`(152) → 非作者 + `_markPostCreatedHandled` 后 `adjustPostUnread(gid,+1)`(157–167)；ApiException/其他异常静默(168–172) | ✅ **等价** | 无行为差异。web 用 `post.author_id`，Flutter 用 `post.authorId`；web 用 `allowed_group_ids`（`chat.ts:784`）而非 visible 并集，Flutter 同（`posts_frames.dart:165` + 注释 162–164 明确写了这一点） |
| `post.deleted` | `chat.ts:793–797`：`removePost(Number(post_id))`；**不回退排序、不动未读** | `posts_frames.dart:119–124`：`_postIdOf(frame, fromPost:false)`（顶层 `post_id`）→ `_posts.removePost` | ✅ **等价** | 无 |
| `post.updated` | `chat.ts:799–812`：同 created 的 REST 对账 + `bumpGroups`，**不动未读** | `posts_frames.dart:113–118`（`bumpUnread == false`）→ `_reconcilePost`；`upsertPost`+`bumpGroups`，`153` 处早退不碰未读 | ✅ **等价** | 无 |
| `post.viewed` | `chat.ts:814–839`：`viewer_id == 本人` ⇒ `markViewedBatch({postId: view_count})` + `markPostViewedHandled` 去重后按 `allowed_group_ids`（Set 去重）每群 `adjustPostUnread(-1)`；否则只 `updatePostViewCount`（不去重） | `posts_frames.dart:125–126, 181–203`：同分支；`187` `post_id`/`view_count` 缺一即忽略；`190–199` 本人档；`201` 他人档 | ✅ **等价** | 无。注意 web `826` 与 Flutter `195` 都是「先 markViewedBatch，再判去重返回」——顺序一致 |
| `comment.created` | `chat.ts:841–844` → **`break`，dispatch 层空实现**。真正消费者：`usePostComments.ts:129–133` 自己 `chatWS.onFrame`，`frame.data.post_id === postId` ⇒ `upsert(frame.data.comment, frame.data.comment_count)`；另有 `PostDetailPage.tsx:222–225` 覆盖 `comment_count` + 清 `replyTarget` | `chat_ws.dart:79–82` 列进 `kAylaChatWsOutOfBatchFrames`（dispatch 层同样 no-op，`chat_ws.dart:585–590` 的 default 分支）；页面级：`post_detail_page.dart:218` 挂 `onFrame`，`268–286` 分发，`289–304` `_applyCommentCreated`（去重追加 + 覆盖 `commentCount`） | ✅ **等价** | **无落差**。web 也没有第三处消费方（全仓 grep comment.created 只有 `chat.ts:841`（no-op）、`usePostComments.ts:131`、`PostDetailPage.tsx:222`）。两者都**只在详情页挂载时**热更新 |
| `comment.deleted` | `chat.ts:841–844` 同上；`usePostComments.ts:132` `remove(comment_id, comment_count)`；`PostDetailPage.tsx:224` 清 `replyTarget` | `post_detail_page.dart:306–324` `_applyCommentDeleted`（移除 + 覆盖计数 + `323` 清 `_replyTarget`） | ✅ **等价** | 无 |

### 1.1 关于「comment.* 被显式忽略」这一疑点的定性
**不是缺陷，也不构成「别人评论不自动出现」的根因。**

- web `ws/chat.ts:841–844` 原文就是：

`~ts
case "comment.created":
case "comment.deleted":
  // 评论事件由帖子详情页经 onFrame 订阅消费（乐观插入/移除 + 更新计数）。
  break;
`~

  ⇒ dispatch 层**没有任何全局副作用**（不写 store、不动未读、不动列表）。
- 消费点在页面层：`hooks/usePostComments.ts:129–133`（`chatWS.onFrame` 在 `useEffect` 里注册，`:142` 卸载时 `off()`）。
- Flutter 侧 `chat_ws.dart:73–74` 的注释**已经写明这一点**，并在 `post_detail_page.dart:218` 做了同形制的页面级订阅。
- 因此两侧的语义完全一致：**详情页没打开 ⇒ 谁都不热更新评论**；详情页开着 ⇒ 都热更新。
- 已有回归锁：`test/page_ws_scroll_share_test.dart`【C】组（comment.created ⇒ 列表出现 + 计数、comment.deleted ⇒ 移除 + 计数下降）。

> 结论：若用户看到「别人评论不自动出现」，只可能是
> ①**没打开该帖详情页**（两侧都如此，属 web 原样行为，不是 Flutter 独有缺陷）；
> ②或命中了 §2 的 RC-1（帧桥/通道失效）导致**详情页也收不到帧**。

### 1.2 其余页面级订阅的对齐（避免误判）
| 页面 | web | Flutter | 结论 |
|---|---|---|---|
| 一级帖子页 /posts | `PostsHubPage.tsx:232–262`：只处理 `post.deleted`（本账号全部 tab 缓存 + 当前 tab）与 `post.created`（REST → 插到当前 tab 头部） | `posts_hub_page.dart:200–203` 注册、`205–230` 分发、`234–249` `_mergeCreatedPost`、`212` `removeFromAllTabs` | ✅ 等价（web 同样**不处理** `post.updated`） |
| 群内帖子 /group/:id/posts | `GroupPosts.tsx:188–231`：deleted / created+updated / viewed(本人) 三条 + `deletedIds` `detailRevision` 守卫；`239–248` `handleCreated` 本地插入 | `group_posts_page.dart:286–355` 注册与分发、`368–408` `_reconcileFramePost`、`835–853` `_submit` 本地插入 | ✅ 等价（Flutter 连 `mutationRevision`/`mutations` 都搬了：`186–189`） |
| 帖子详情 | `PostDetailPage.tsx:219–245` | `post_detail_page.dart:217–226, 268–348` | ✅ 等价 |
| 搜索页 | `SearchPage.tsx:252–287`：**只有** group.request.resolved / group.joined / group.member.left | `search_page.dart:258, 341–354`：同样只这三条 | ✅ 等价（两边都**不**消费帖子帧） |
| 我的帖子 / 用户帖子 | `MyPostsPage.tsx` / `UserPostsRoute.tsx`：**无 chatWS.onFrame** | `my_posts_page.dart` / `user_profile_page.dart`：同样无 | ✅ 等价（两侧都不热更新，属 web 原样缺口） |

---

## 2. 根因链

### RC-1（最高优先级 · **代码缺陷** · 可静态确认）：登录周期后帧桥永久脱挂

**链路：**

1. 启动期挂一次：
   - `lib/main.dart:260–262` → `aylaStartPostsFrames(container)`
   - `lib/state/room_providers.dart:451–453` → `container.read(postsFramesBridgeProvider).attach(container.read(chatWsProvider))`
   - `core/ws/posts_frames.dart:97–100` `attach()` → `_off = chat.onFrame(handleFrame)`
2. 登出**会解绑**（`detach()`）：
   - `lib/state/room_providers.dart:468–473` `aylaStopPostsFrames` → `postsFramesBridgeProvider.detach()`
   - `lib/state/room_providers.dart:482–489` `aylaStopPostsFramesForContainer` → 同上
   - `core/ws/posts_frames.dart:103–106` `detach()` → `_off?.call(); _off = null;`
3. 这两条登出函数**在两条真实登出链上都被调用**：
   - `lib/state/auth_bootstrap.dart:174` `aylaLogoutForContainer` → `aylaStopRoomsForContainer(container)`（401 过期 / `main.dart:211`）
   - `lib/state/auth_bootstrap.dart:194` `aylaLogout` → `aylaStopRooms(ref)`（`layout/app_shell.dart:115`、`pages/profile_page.dart:192`）
   - `aylaStopRooms`/`aylaStopRoomsForContainer` 内部：`room_providers.dart:422` / `:439` → `aylaStopPostsFrames(ref)` / `aylaStopPostsFramesForContainer(container)`
4. **再登录时没有任何地方重新 attach**：
   - 登录链 `auth_bootstrap.dart:117–119` 只做 `wsManager?.connectAll()` + `_startChatWs(container)` + `_startPresenceWs(container)`；
   - `aylaStartPostsFramesForRef`（`room_providers.dart:456–458`）与 `aylaStartRoomFramesForRef`（`:366–373`）
     **在全仓 lib/ 与 test/ 里 0 个调用点**（`grep -rn "ForRef" lib/ test/` 只命中定义行 `chat_providers.dart:104`、
     `room_providers.dart:366`、`room_providers.dart:456`）。
   - `postsFramesBridgeProvider` 是**非 autoDispose** 的 Provider（`room_providers.dart:224–238`），
     容器存续期内**不会重建** ⇒ 一旦 `detach()`，该实例永远不会自己恢复。

**后果**：同一进程内 **登出 → 再登录** 之后，`post.*` 四帧**全部不再被处理** ⇒
群未读帖子数不增减（`adjustPostUnread`）、`aylaPostsStore` 不 upsert（主页「新内容」排序 / 群活动排序读它：
`pages/group_page.dart:706`、`pages/home_page.dart:237`）、`post.viewed` 的浏览量/已读态不刷新。
这正好匹配用户口径「**几乎全都要手动刷新**」。

同一缺陷的孪生体：`room_frames.dart` 的目录帧桥（`room_providers.dart:421/438` detach，无再 attach）⇒ 语音/直播/桌游目录帧同理会在重登后失效。

**修复方向（供后续修复者，本次不改）**：在登录链（`auth_bootstrap.dart` 的 `_applyLoginSession` 里，
`_startChatWs(container)` 之后）调用 `aylaStartPostsFramesForRef/ForContainer` + `aylaStartRoomFramesForRef/ForContainer`；
或把 `detach` 从登出链移除、改为「桥不随登出解绑，靠 `currentUserId()` 判账号」（`posts_frames.dart:144–147` 已有账号守卫）。
**前者改动面更小且与 web 模块级单例语义一致**（web 的 `chatWS.onFrame` 订阅在模块级，登出只断连接、不摘 handler）。

**验证判据（待实测）**：登录 → 登出 → 再登录 → 用另一账号往群里发帖 / 浏览该帖 →
若 Flutter 端群未读红点与主页排序都不动、而**杀进程重启后同样操作正常** ⇒ 本 RC 成立。

---

### RC-2（**代码缺陷** · 可静态确认）：「发帖后列表不自动刷新」——三条通路同时断

以 **一级帖子页底部 FAB 发帖** 为主链路（/posts 页「发布第一条帖子」同源）：

1. **发帖成功后只导航、不写任何列表数据**
   - `lib/layout/create_sheet_forms.dart:670–684` `_submit`：`createPost` 成功后 `widget.onClose()` 然后
     `context.go('/posts/<id>')`（`679–683`）——**不写** `aylaPostsStore`、**不写** `aylaPostTabCache`。
   - web 对照 `CreateFab.tsx:93–103`：`PostEditor onCreated` 同样只有 `setOpen(false); navigate(...)`，
     `PostEditor.tsx:176–190` 也只 `onCreated(post)`。⇒ **两侧此处等价**，web 同样不写列表。
2. **`context.go` 会卸载列表页**（go 是替换 location，不是 push）⇒ `PostsHubPage.dispose`
   （`posts_hub_page.dart:268–287`）执行 `_unregisterFrameTracking()`（`:270`），
   ⇒ `post.created` 回环帧到达时**页面级 _onFrame 已不在监听者集合里**，
   `_mergeCreatedPost`（`:234–249`）根本不会跑。
3. **全局帧桥写的 store，列表页不读**
   - 全局桥 `posts_frames.dart:151` `_posts.upsertPost(post)` 写的是 `aylaPostsStore`（`posts_store.dart:212`）；
   - 但一级帖子页读的是**页面私有的 `aylaPostTabCache` 分页快照**（`posts_hub_page.dart:319–345` `_start()` →
     `aylaPostTabCache.acquire`，build 的 `loaded` 来自 `pager.items`：`:482–484`），
     **不订阅 `aylaPostsStore`**（全文件无 `aylaPostsStore.addListener`，只有 `markViewedBatch` 写：`:470`）。
     ⇒ 全局桥的结果对一级页**零影响**。web 同构（`PostsHubPage.tsx:77/98–101` 读 `postTabPages`，不读 `usePostsStore`）。
4. **返回列表时被 60s 新鲜窗口拦住**
   - `posts_hub_page.dart:343` `if (!aylaPostTabCache.shouldLoad(key)) return;`
   - `posts_store.dart:321–327` `shouldLoad`：`loaded && now - updatedAt < 60000` ⇒ 返回 true（不拉）
   - ⇒ 从详情返回后**最长 60 秒**列表里都没有那条新帖；除非手动下拉刷新（`_refresh` → `pager.refresh()`）。

**净效应**：`发帖 → 跳详情 → 返回` 的完整链路里，**没有任何一步**能把新帖塞进一级列表；
用户看到的就是「发完帖列表不自动刷新」。

> ⚠️ 与 web 的差别说明（诚实记录）：web 也是同一结构（navigate 卸载 + `postTabPages` 60s 窗口）。
> 但 web 的 `WS post.created` 全局分支把帖子写进 `usePostsStore`，而 web 的
> `HomePage`/`groupActivity.ts` 读 store 做**排序**，用户感知上是「群卡片往前排了」；
> Flutter 侧这两处也读 `aylaPostsStore`（`group_page.dart:706`、`home_page.dart:237`），
> 所以「排序」这半边的热更新等价；**「一级帖子列表出现新卡」这半边在 web 与 Flutter 上都是 60s 窗口缺口**。
> ⇒ 本条应定性为「**与 web 同构的产品级缺口**」而非纯 Flutter 移植缺陷；是否要在 Flutter 侧额外补齐，
> 需用户裁决（补齐即有意偏离 web）。

**群内帖子页（/group/:id/posts）对照**：此路径**没有** RC-2 的问题——
`group_posts_page.dart:835–853` `_submit` 成功后直接 `_posts = <AylaPost>[created, ..._posts]` 本地插入
（= web `GroupPosts.tsx:239–248` `handleCreated` 的 `mergePosts(prev, [post], true)`）。✅ 等价。
> 但若群内发帖时**命中了 RC-1**（重登后帧桥脱挂），则他人发帖的那条帧通路仍不生效——两处要分开看。

---

### RC-3（**需实测** · 初始化时序）：attach 早于 WsManager 建立，是否真的挂到了活通道？

- `main.dart:215` `initWsManager(...)` 先建 `WsManager`；
- `main.dart:262` `aylaStartPostsFrames(container)` → `container.read(chatWsProvider)` 新建 `AylaChatWsClient`（此时 `_channel == null`）
  → `attach` 只登记 `onFrame` handler（`chat_ws.dart:267–270`）——**不涉及通道**，所以顺序本身没问题；
- 真正绑通道的是 `auth_bootstrap.dart:135–140` `_startChatWs` → `client.attach(manager.chat)`（`chat_ws.dart:183–188` 挂
  `channel.onEvent = _dispatch`）→ `client.connect()`。
- 也就是说：**只要 `chatWsProvider` 拿到的是同一个实例**，帧桥就有效；而
  `chat_providers.dart:139–193` 的 `chatWsProvider` 用的是 `ref.read`（非 watch），历史注释 `156–179` 记录了
  「曾经用 `watch` 导致 provider 反复重建 ⇒ 连接被断」的事故。
- ⚠️ **待实测**：当前代码是 `read`，理论正确；但 `main.dart` 的 `ProviderContainer()` 与
  `_AppRoot` 的 `UncontrolledProviderScope(container: container)` 是否真的是**同一个容器**
  （`main.dart:203` 与 `281–286`）—— 这一点静态可读为「是同一实例」，但**运行期 provider 实例是否被重建**
  只能靠真机日志确认。**建议 Lead 实测**：在 `posts_frames.dart:99`（`attach`）与 `:110`（`handleFrame` 入口）
  各打一行 `debugPrint`，跑一次「另账号发帖」看是否打印。

---

### RC-4（**已确认不是缺陷**，排除项）

| 疑点 | 结论 | 证据 |
|---|---|---|
| 「comment.* 被显式忽略 ⇒ 评论不热更新」 | **不成立**。web dispatch 层同样是 no-op；两侧都在详情页页面级消费 | `chat.ts:841–844` vs `chat_ws.dart:79–82 + 585–590`；`usePostComments.ts:129–133` vs `post_detail_page.dart:218, 268–324` |
| 「post.created REST 失败就静默 ⇒ 列表不更新是缺陷」 | **与 web 等价，不是移植缺陷** | web `chat.ts:789–790` `.catch(() => { /* 当前用户不可见或帖子已删除 */ })`；Flutter `posts_frames.dart:168–172` 同语义 |
| 「自己发帖收不到 post.created 回环」 | **不成立**。后端**显式**广播给作者本人 | `apps/posts/views.py:204–205` `broadcast_post_created_to_user(post, request.user)` → `services.py:342–373`（`chat_user_{user.id}`）；消费者 `consumers.py:639–641` |
| 「后端没下发帖子帧」 | **不成立**（静态可确认，且 Lead 已实测 WS 通） | `views.py:194–205 / 275 / 297 / 93 / 350 / 372` 六处广播；`consumers.py:639–665` 六个 handler 全部 `send_json(event)` |
| 「Flutter AylaPost 解析不了帧/详情」 | **不成立** | 后端 `PostSerializer`（`serializers.py:64–85`）字段与 `models/post.dart:216–249` 逐字段对齐；`id` 走 `_postId` 兼容数字/字符串（`post.dart:252–264`，注释记录了收藏投影用字符串的历史修复） |

---

## 3. 「代码缺陷」vs「需实测」清单

### 3.1 代码缺陷（可静态确认，可交后续修复）
| # | 缺陷 | 文件:行 | 影响 |
|---|---|---|---|
| D1 | 帧桥**登出后不重挂**：`aylaStartPostsFramesForRef/ForContainer` **0 调用点**，而登出链必定 `detach()` | 挂：`main.dart:262`、`room_providers.dart:451–458`；摘：`room_providers.dart:469/484`、`posts_frames.dart:103–106`；无重挂：`auth_bootstrap.dart:117–119` | **重登后帖子域四帧全灭**（未读红点、store 排序、浏览量、已读态） |
| D2 | 同 D1 的孪生体：目录帧桥（voice/live/boardgame） | `room_providers.dart:421/438` detach；`aylaStartRoomFramesForRef`(`:366`) 0 调用 | 重登后目录热更新失效（与审计 B 重叠，请 Lead 交叉核对） |
| D3 | 一级帖子页发帖后列表不刷新（三通路断：go 卸载 + store 不被读 + 60s 窗口） | `create_sheet_forms.dart:679–683`；`posts_hub_page.dart:270/343/482–484`；`posts_store.dart:321–327` | 「发帖后列表不自动刷新」。**注意与 web 同构**，是否补齐需裁决 |

### 3.2 需实测（静态不足以定论）
| # | 假设 | 怎么测 | 判据 |
|---|---|---|---|
| M1 | D1 是用户当前症状的主因 | 登录 → 登出 → 再登录 → 另账号发帖/浏览 | 重登后红点/排序不动、**重启进程后正常** ⇒ 成立 |
| M2 | 帧桥是否真的挂到活的 chat 通道（provider 未被重建） | 在 `posts_frames.dart:99` 与 `:110` 加 `debugPrint` | 另账号发帖时 Flutter 日志是否打印 `handleFrame type=post.created` |
| M3 | 详情页评论热更新是否真能收到帧（排除 RC-1 干扰后） | 重启进程 → 打开某帖详情页 → 另账号评论 | 评论立即出现 + 计数变 ⇒ 正常；否则查 `post_detail_page.dart:218` 是否被 go/重建摘掉 |
| M4 | D3 的 60s 窗口是否即用户感知的「不刷新」 | 发帖 → 返回列表 → 记录多久后出现 | <60s 不出现、约 60s 后自动出现 ⇒ D3 成立 |
| M5 | 一级页 post.created 帧在**页面挂载期间**是否生效 | 停留在 /posts 列表页 → 另账号发公开帖 | 新卡立即插到头部 ⇒ 页面级订阅有效（此时 D3 只在「发帖后跳详情」路径暴露） |

---

## 4. 附：本次审计覆盖但判定为「等价」的明细（避免后续重复调查）

1. **去重窗口载体差异（已登记，语义等价）**：web 把 `postCreatedHandledAt` / `postViewedHandledAt` 放**模块级**
   （`chat.ts:43 / 66`，随页面生命周期存活）；Flutter 放在**桥实例**上（`posts_frames.dart:89–92`），
   桥是容器级单例、登录期唯一、登出随 `detach` 保留实例（`room_providers.dart:224–238` 非 autoDispose）。
   ⇒ 同一登录会话内行为一致；**跨登录周期时 Flutter 的去重表不清空**（web 模块级也不清）——一致。
2. **`visibleGroupIds` 的空值过滤差异（已登记）**：web `chat.ts:108–110` 判 `id != null`；
   Flutter `posts_frames.dart:220–228` 判 `isNotEmpty`（因为 `AylaPost.allowedGroupIds` 的 `fromJson`
   已在 `post.dart:362–368` 过滤掉空串）。语义等价。
3. **`markViewedBatch` 空 map 早退**：`stores/posts.ts:115–116` ↔ `posts_store.dart:166` 一致。
4. **`removePost` 不改 total/游标**：`stores/posts.ts:108–111` ↔ `posts_store.dart:148–157`；
   但 `AylaPagedList.setItems`（`paged_list.dart:161–164`）会按条数差**同步 total**，
   与 web 的纯 filter 略有差异 —— 影响仅在页脚「N 条帖子」计数，**不影响列表内容**，登记为微差。
5. **`AylaPostTabCache.removeFromAllTabs`**：`posts_store.dart:351–359` 对应 web `PostsHubPage.tsx:237–241`；
   Flutter 少了 `key.startsWith("posts:" + account + ":")` 的前缀过滤，理由是缓存整体随登出清空
   （`auth_bootstrap.dart:165` `aylaPostTabCache.clear()`）—— 注释已在 `posts_store.dart:347–349` 登记，判等价。

---

## 5. 建议的修复顺序（供 Lead 排期）

1. **D1/D2（P0）**：登录链补 `aylaStartPostsFrames*/aylaStartRoomFrames*` 的再挂；或在 `detach` 之外提供
   「登出只连接断、桥不摘」的语义。改完加一条回归锁：登录 → 登出 → 重登 → 投喂 post.created ⇒ store 必须变化。
2. **D3（P1，需用户裁决是否偏离 web）**：一级页发帖返回后主动把 `created` 写入
   `aylaPostTabCache`（等价 web `handleCreated` 的语义搬一份到 FAB 路径），或把
   `shouldLoad` 的 60s 窗口在「有 pending 新帖」时短路。
3. **M2/M3 实测**（P1）：加临时日志确认帧桥与详情页订阅在真实运行期确实在收帧，排除 M1 已成立后仍有残余断点。

---

*审计方式：纯静态阅读 + 行号核对；未运行 Flutter、未改任何代码。所有「等价」判定均给出两侧文件:行；
所有未能静态定论的结论已显式标注「待实测」。*
