# 24 · WS 热更新审计 B —— 群内/群外 语音·直播·桌游 三条目录链路

> 只读审计（2026-10-19）。**未改动任何 lib/ 代码，未启动 Flutter**。
> 事实源：web `Ayla/web/src`（React+TS+Zustand）· Flutter `Ayla/flutter/lib` · 后端 `Ayla/backend`。
> 每条结论都带 `文件:行`；无法从代码证明的一律标 **「待实测」**。

---

## 0. 结论摘要（先看这段）

| # | 判定 | 一句话 |
|---|---|---|
| **R1** | **代码缺陷（头号根因）** | `aylaStartRoomFrames` / `aylaStartDirectoryTracking` **只在 `main.dart:259` 调一次**（App 启动期），而**登出/401 过期会把两条通路全部拆掉**（`room_providers.dart:421/426/438/443`），**没有任何重新装配的调用点** ⇒ 一旦经历「登出→再登录」或「401 过期→再登录」，语音/直播/桌游的**全部目录帧从此不再被处理**，且**取页结果也不再落回域 store**，直到重启 App。 |
| **R2** | **代码缺陷** | 群内三页（`GroupVoicePage` / `GroupLivePage` / `GroupGamesPage`）用的是**页面私有 `AylaPagedList`**，**完全不读** `AylaDirectoryStore`；而 web 这三页是 `useDirectoryPage("voice"/"live"/"game", {groupId})`（`GroupVoice.tsx:40` · `GroupLive.tsx:27` · `GroupGames.tsx:20`）⇒ **群内三列表结构性没有热更新**（与 WS 是否到达无关）。 |
| **R3** | **代码缺陷** | `boardgame.room.deleted` 的帧是**顶层** `{type, room_id}`（后端 `boardgame/services.py:113–127` + `195`），web 读 `frame.room_id`（`chat.ts:854`）；Flutter `_roomId()`（`room_frames.dart:498–508`）只读 `frame.room.id` 或 `frame.data.room_id`，**读不到顶层 `room_id`** ⇒ 删除帧被静默丢弃（`room_frames.dart:312–313` 的 `id.isEmpty ⇒ return`）。 |
| **R4** | **代码缺陷** | 自己建桌游房后**本地零写入**：`create_sheet_forms.dart:745–752` `await widget.createRoom(...)` **丢弃返回的 `AylaGameRoom`**，无 `upsertRoom` / 无 `noteCreated`；web 的等价物是 `api/boardgame.ts:61–62` 的 `window.dispatchEvent("boardgame:room-created")` + `GroupGames.tsx:49–56` 监听 → 重取。Flutter 侧既没接该事件也没本地落库。 |
| **R5** | **代码缺陷（较轻）** | `live.channel.*` 的 REST 对账**缺少 web 的 in-flight 合并**（web `chat.ts:388/394` 的 `liveReconciliations`），且 web 的 catch 分支是 `removeChannel`（`chat.ts:397`），Flutter 是**静默**（`room_frames.dart:438–442`）⇒ 频道被下架后本地条目可能残留。 |
| **R6** | **待实测** | 前三项之外，「全新登录（无登出）」的会话里，帧桥 + 订阅通路确实在 `main.dart:255–262` 装配完成，理论上应工作 ⇒ 需要确认用户复现路径是否经过**登出/401**，这是 R1 是否命中的唯一分水岭。 |

**给修复者的最短判据**：先看 R1（重装缺失，一行级修复）与 R2（群内三页换 `AylaDirectoryController`），这两条能解释「群内群外全都没有热更新」；R3/R4 解释「桌游单点不更新」。

---

## 1. 逐帧等价性表（14 条：12 条目录帧 + 2 条相关帧）

web 事实源：`Ayla/web/src/ws/chat.ts`（switch 分支）+ `Ayla/web/src/stores/directory.ts`（帧直连通路 220–259）。
Flutter 事实源：`Ayla/flutter/lib/core/ws/room_frames.dart`（`AylaRoomDirectoryBridge`）+ `lib/state/directory_tracking.dart`（订阅通路）+ `lib/state/directory_store.dart`（`updateCachedItems` / `noteCreated` / `noteDeleted`）。

| # | 帧 | web 行为（文件:行） | Flutter 行为（文件:行） | 等价? | 差异 |
|---|---|---|---|---|---|
| 1 | `voice.channel.created` | 登记 `createdIds`（`directory.ts:228–234`）+ `GET /voice/channels/<id>/` → `upsertChannel` → `bumpGroups`（`chat.ts:667–678`） | `noteCreated`（`room_frames.dart:259`）+ REST → `upsertChannel` + `_bumpGroups`（`:345–371`） | ✅ | Flutter 多了「账号守卫」（`:354`），web 用 `currentOwner.current` 同法，语义等价 |
| 2 | `voice.channel.updated` | REST 对账，**不 bump**（`chat.ts:720–727`） | `_reconcileVoiceChannel`（无 bump，`room_frames.dart:262–265`） | ✅ | — |
| 3 | `voice.channel.deleted` | `removeChannel`（`chat.ts:679–683`）+ 缓存摘除（`directory.ts:237–258`） | `removeChannel` + `noteDeleted`（`room_frames.dart:266–272`） | ✅ | — |
| 4 | `voice.channel.member_count_changed` | 有排序投影则 patch，否则 REST 对账；人数增加 bump（`chat.ts:685–719`） | 同构（`room_frames.dart:273–274 / 378–409`） | ✅ | — |
| 5 | `live.channel.created` | `reconcileLiveChannel`（`chat.ts:728–731`）→ `live.ts` upsert | `noteCreated` + REST → `upsertChannel`（`room_frames.dart:275–279`） | ✅ | — |
| 6 | `live.channel.status.changed` | reconcile +（帧 status==live 时）详情确认后 bump（`chat.ts:732–744`） | 同构（`room_frames.dart:283–291 / 418–443 / 485–489`） | ✅ | — |
| 7 | `live.channel.updated` | reconcile，不 bump（`chat.ts:751–755`） | 同构（`room_frames.dart:280–282`） | ✅ | — |
| 8 | `live.channel.deleted` | `removeChannel`（`chat.ts:745–750`） | `removeChannel` + `noteDeleted`（`room_frames.dart:292–296`） | ✅ | — |
| 9 | `live.viewers.changed` | 只 patch 已加载条目（`chat.ts:756–765`；**不属于 `live.channel.*`**） | `patchViewerCount`（`room_frames.dart:297–298 / 447–455`） | ✅ | 两侧都只 patch 已在域表中的条目（`live_state.dart:157–169`） |
| 10 | `boardgame.room.created` | `frame.room` → REST → `upsertRoom`（`chat.ts:845–851`）+ `createdIds`（`directory.ts:229` 读 `frame.room.id`） | `_roomId` 读 `frame.room.id` ✅（`room_frames.dart:499–502`）→ `noteCreated` + REST upsert | ✅ | — |
| 11 | `boardgame.room.updated` | `frame.room` → REST（`chat.ts:857–865`） | 同构（`room_frames.dart:306–310`） | ✅ | — |
| 12 | **`boardgame.room.deleted`** | `removeRoom(Number(frame.room_id))`（`chat.ts:854`）+ 摘缓存（`directory.ts:225–226`） | `_roomId` **读不到顶层 `room_id`**（`room_frames.dart:498–508`）⇒ `id.isEmpty` **静默 return**（`:312–313`） | ❌ **缺陷** | 见 R3 |
| 13 | `post.*` / `comment.*` | 帖子域（`chat.ts:766–843`） | `posts_frames.dart` 承接 | ✅（本审计范围外） | — |
| 14 | `live.channel.*` 的**对账合并** | `liveReconciliations` in-flight 去重 + catch ⇒ `removeChannel`（`chat.ts:388–400`） | **无合并**；catch ⇒ 静默（`room_frames.dart:438–442`） | ⚠️ **偏差** | 见 R5 |

**帧形状核对（后端 → 客户端契约）**：后端 `apps/chat/consumers.py` 把 voice/live 事件包成 `{type, data:{...}}`（`:510–545 / 549–635`），Flutter `_channelId()` 读 `frame.data.channel_id`（`room_frames.dart:492–496`）✅；**桌游事件是顶层平铺**（`boardgame/services.py:113–127`，`consumers.py:669–679` 直接 `send_json(event)`），删除帧**没有 `room` 也没有 `data`** ⇒ R3 成立。
另：`Ayla/flutter/test/room_live_test.dart:267–270` 的用例喂的是 `'room': {'id': '9'}`（不是真实的顶层 `room_id`）⇒ **单元测试掩盖了该缺陷**。

---

## 2. 「自己新建房间后列表不立刻出现」根因链

逐段给出「应有的链」与「实际断点」。

```
① 客户端 POST（建房）
② 服务端 group_send 到目录组
③ WS 帧到达 chat 通道
④ chat_ws._dispatch → onFrame 监听者
⑤ AylaRoomDirectoryBridge.handleFrame
⑥ 域 store 写入（voice/live/boardgame）
⑦ directory_tracking 订阅回调 → store.updateCachedItems
⑧ 页面 controller 监听 store → setState
```

### 2.1 逐段证据

**① REST 调用（Flutter）**
- 语音：`create_sheet_forms.dart:595–600` → `AylaVoiceApi.createVoiceChannel`（`voice_api.dart:376–392`）
- 直播：`create_sheet_forms.dart:372–376`（CreateFab 路径）· `group_live_page.dart:265–269`（群内开播）· `live_studio_page.dart:361–362`（控制台新建）
- 桌游：`create_sheet_forms.dart:745–752`

**② 服务端是否 group_send 到目录组 → 是**
- 语音：`voice/views.py:178–179` → `voice/services.py:369–371` → `_broadcast_channel_catalog_event`（`:346–361`）→ `group_send("voice_catalog", {type:"voice.channel.created", channel_id})`
- 直播：`live/views.py:208` → `live/services.py:382–384` → `_broadcast_to_users(... chat_user_<id>)`（`:364–374`，按可见性精确投递）
- 桌游：`boardgame/views.py:148–159` → `boardgame/services.py:151–161 / 130–148 / 164–182`（public / group / user 三档）
- 会话订阅：`chat/consumers.py:139–159` 已 `group_add` 到 `voice_catalog` / `live_catalog` / `boardgame_public`

> Lead 已实测：B 账号建三类房，A 端均收到帧 ⇒ **②③ 无问题，不是根因。**

**③④ 帧到达与分发**：`chat_ws.dart:438 _dispatch` → 尾部 `for (handler in _handlers) handler(frame)`（`:592–594`）。帧桥通过 `attach()` 注册在 `_handlers`（`room_frames.dart:185–189`）。

**⑤ 帧桥处理**：`room_frames.dart:241–249 → 252–323`。

**⑥ 域 store 写入**
- voice：`room_frames.dart:357 _voice.upsertChannel(channel)` — **依赖 ⑥ 之前的 REST 对账成功**（`:352–354`）
- live：`:429 _live.upsertChannel(channel)`（同样依赖 REST，`:425–427`）
- game：`:473 _boardgame.upsertRoom(room)`（`:471`）

**⑦ 订阅通路 diff**：`directory_tracking.dart:122–162`（`_onVoiceChanged/_onLiveChanged/_onGameChanged`）→ `directory_store.dart:476 updateCachedItems`。
**⑧ 页面重建**：`voice_hub_page.dart:217 pager.addListener(_onPagerChanged)` → `:179–193`（postFrame setState）。

### 2.2 断点（按严重度）

#### 🔴 断点 A（R1）：两条通路只在启动期装配一次，登出后被永久拆除

- 装配点**唯一**：`main.dart:255–262`（`aylaStartSocialTracking` / `aylaStartRoomFrames` / `aylaStartPostsFrames`）。
- 拆除点：`room_providers.dart:412–429 aylaStopRooms` → `:421 bridge.detach()` + `:426 aylaStopDirectoryTracking()`；容器版 `:432–446`（`:438/443` 同）。其中 `aylaStopPostsFrames` 还 **`itemUpsertHooks.clear()`**（`:472` / `:488`）。
- `aylaStopDirectoryTracking() => directoryTracking.stop()`（`room_providers.dart:190`）→ `directory_tracking.dart:103–115`：`removeListener` 三个域 store，并把 `_store` 置 null ⇒ `_onVoiceChanged` 等回调即使被调用也会在 `if (store == null) return`（`:124/138/152`）提前返回。
- **重新装配的入口存在但没有调用点**：`aylaStartRoomFramesForRef`（`room_providers.dart:366–373`）、`aylaStartPostsFramesForRef`（`:456–458`）、`aylaStartSocialTrackingForRef`（`chat_providers.dart:104–106`）、`aylaStartChatWs`（`:198–204`）—— 全仓 grep **零调用**（仅定义处命中）。
- 登出/401 路径：`auth_bootstrap.dart:158–183`（容器版）与 `:186–202`（WidgetRef 版）→ `aylaStopRooms*`。登录路径 `aylaApplyLoginSession`（`:95–129`）**只**做：写令牌、拉 `/me/`、`wsManager.connectAll()`、`_startChatWs`、`_startPresenceWs`、badges、`AppInit.run` —— **没有重新 attach 帧桥、没有重新 start 目录订阅、没有重新注册 itemUpsertHooks**。

⇒ **后果链**：登出后再登录 ⇒ ⑤ 帧桥已 detach（帧根本不到 ⑥）；⑦ 订阅通路已 stop（即使 ⑥ 有写入也不会 patch 缓存）；取页结果也不再落回域 store（hooks 被 clear）。**表现就是「WS 帧静默丢失 + 列表必须手动刷新/重进页面」**，且重启 App 才恢复。

> 这条同时解释：为什么 84 个单测全绿（每个用例自己 `tracking.start()`、自己 `bridge.attach()`，从不经过登出），而真实运行链路不热更新。

#### 🟠 断点 B（R2）：群内三页根本没读目录缓存

- `group_voice_page.dart:74/83` 用私有 `AylaPagedList`；`group_live_page.dart:112/140` 同；`group_games_page.dart:58/71` 同。
- 三页**都不 import `directory_store.dart`**（grep 已确认：只 import `paged_list.dart`），也**不订阅** `AylaDirectoryEvents`（`group_games_page.dart:17` 只在注释里提到，实际零订阅）。
- web 对照：`GroupVoice.tsx:40` `useDirectoryPage("voice", {groupId})` · `GroupLive.tsx:27` `useDirectoryPage("live", {groupId})` · `GroupGames.tsx:20` `useDirectoryPage("game", {groupId})` ⇒ 三页读的是**同一条目录 record**，帧落 store 即自动 patch。
- 侧栏（宽屏第 2 列）**已修好**并读 store：`group_page.dart:232–233 / 317–357`（`AylaDirectoryController`），与 web `ChannelSidebar.tsx:124–125` 对齐 ✅ —— 即「侧栏有热更新、点进群内场景页没有」的观感差异有明确代码依据。

#### 🟡 断点 C（R4）：自建房间的本地写入，三条各不相同

| 域 | web 本地写入 | Flutter 本地写入 | 结论 |
|---|---|---|---|
| 语音 | `VoiceChannelCreate.tsx:44–45` `setChannels([{...ch, mine:false}, ...channels])`（**立即**，域 store） | `create_sheet_forms.dart:607–609` `upsertChannel(channel.patch(mine:false))` | ✅ 有；但只有域 store → 依赖 ⑦ 通路才进目录缓存 |
| 直播 | CreateFab `CreateFab.tsx:44–50` **不写 store**（靠 WS + 目标页自取）；控制台 `LiveStudioPage.tsx:105–110` `applyOrdered([created, ...])` **写本地分页** | CreateFab 路径 `create_sheet_forms.dart:372–379` **不写**；控制台 `live_studio_page.dart:364–370` `upsertChannel` + `_applyOrdered` | ✅ 与 web 同构（CreateFab 两侧都不写） |
| 桌游 | `api/boardgame.ts:60–63` `window.dispatchEvent("boardgame:room-created", room)` → `GroupGames.tsx:49–56` 监听 ⇒ `load()` 重取；域 store 由 WS 填 | `create_sheet_forms.dart:745–752` **丢弃返回值**，无 upsert、无 noteCreated、无重取 | ❌ **缺一件**（R4） |

#### 🟡 断点 D（R3）：`boardgame.room.deleted` 帧形状不匹配（见 §1 #12）

#### 🟢 断点 E：REST 对账失败即丢弃（与 web 基本等价，非根因）

- `voice.channel.created` 的 `_reconcileVoiceChannel`：`room_frames.dart:366–370`（403/404 与网络错误均静默，**不 upsert**）⇒ ⑥ 不写、⑦ 无 diff、列表不动。
- web 同：`chat.ts:676` `.catch(() => {})`。**两侧同级**，不构成 Flutter 独有缺陷。
- ⚠️ 但注意：Flutter 的 `noteCreated` 已被消费（`directory_store.dart:583–585` 在每轮 diff 后清 hint），若 REST 失败则 hint 白登记 —— 与 web `directory.ts:195` 同款，等价。

---

## 3. 页面侧是否真的订阅 store

| 页面 | 数据源 | 订阅方式 | 热更新? |
|---|---|---|---|
| `voice_hub_page.dart` | `AylaDirectoryController`（`:205–216`） | `pager.addListener(_onPagerChanged)`（`:217`）→ postFrame `setState`（`:179–193`） | ✅ 会重建（**前提：⑦ 通路活着**） |
| `live_hub_page.dart` | `AylaDirectoryController`（`:192–203`） | `addListener` `:204` → `:170–184` postFrame setState | ✅ 同上 |
| `games_hub_page.dart` | `AylaDirectoryController`（`:209–220`） | `addListener` `:221` → `:188–201` | ✅ 同上 |
| `home_page.dart` | `aylaDirectoryStore` + 三域 store | `addListener` ×6（`:140–148`）→ `_rebuildActivity`（`:169–180`） | ✅ |
| `group_page.dart`（宽屏侧栏 voice/live） | `AylaDirectoryController`（`:321–332`） | `addListener(_onChanged)`（`:326/332`）→ `setState`（`:421–423`） | ✅ |
| **`group_voice_page.dart`** | **`AylaPagedList`（`:83`）** | 只 `addListener(_onChanged)`（`:89`），**无 store 订阅** | ❌ **R2** |
| **`group_live_page.dart`** | **`AylaPagedList`（`:140`）** | `:149` 同上 | ❌ **R2** |
| **`group_games_page.dart`** | **`AylaPagedList`（`:71`）** | `:77` 同上 | ❌ **R2** |
| `live_studio_page.dart`（开播控制台侧栏） | **`AylaPagedList`（`:124–130`）** | `:130` 本地分页 | ⚠️ 半缺陷：web 用 `useOwnedLiveDirectory` 订阅 `chatWS.onFrame`（`useOwnedLiveDirectory.ts:33–40`）⇒ Flutter 缺该订阅 |
| `create_sheet_forms.dart` 的 `AylaOwnedLivePicker` | `AylaPagedList`（`:226–234`） | 订阅**已退役**的 `directoryEventsProvider`（`:242–267`）—— 生产恒为兜底档，帧桥注入 store 后**不会**再 emit（`room_frames.dart:148–156`） | ❌ 该订阅在真实链路里是死订阅 |

**「只在 initState 取一次」的页面**：群内三页确实「进页面取一次」，但它们的 `_onChanged` 只响应**自己的 PagedList**（分页结果），不响应任何 WS ⇒ 语义上等同「只在 initState 取一次」。
**`_onPagerChanged` 用 postFrame 是否丢帧**：不会丢。`AylaDirectoryController` 每次 store `notifyListeners` 都会回调（`directory_store.dart:1236–1239`），postFrame 只是把 `setState` 推迟一帧（`:183–185` 的既定纪律，规避 build 期 setState）；连续多帧合并成一帧刷新，**不是丢更新**。此项**排除**。

---

## 4. 明确区分：代码缺陷 vs 需实测

### 4.1 已由代码证实的缺陷（可直接改）

| 编号 | 缺陷 | 证据 | 修复方向（不改，仅建议） |
|---|---|---|---|
| **R1** | 登出/401 后帧桥与目录订阅**永不重装** | 装配唯一在 `main.dart:255–262`；拆除在 `room_providers.dart:421/426/438/443`；`*ForRef` 重装函数**零调用点**（`:366/456`、`chat_providers.dart:104`）；登录链 `auth_bootstrap.dart:95–129` 不含重装 | 在 `aylaApplyLoginSession` 末尾补 `aylaStartRoomFramesForRef/container` 等价调用（或把 `aylaStopRooms` 改成「只停会话、不停目录装配」） |
| **R2** | 群内三场景页不读目录缓存 | `group_voice_page.dart:74/83`、`group_live_page.dart:112/140`、`group_games_page.dart:58/71` vs web `GroupVoice.tsx:40`/`GroupLive.tsx:27`/`GroupGames.tsx:20` | 三页换 `AylaDirectoryController`（与 `group_page.dart:317–357` 同模板） |
| **R3** | `boardgame.room.deleted` 顶层 `room_id` 读不到 | `room_frames.dart:498–508` vs 后端 `boardgame/services.py:113–127,195` vs web `chat.ts:854` | `_roomId` 增加顶层 `frame['room_id']` 分支（**优先**，web 就是读它） |
| **R4** | 建桌游房后本地零写入 | `create_sheet_forms.dart:745–752` 丢弃 `AylaGameRoom`；web `boardgame.ts:61–62` + `GroupGames.tsx:49–56` | 提交成功后 `aylaBoardgameStore.upsertRoom(room)` + `aylaDirectoryStore.noteCreated(game, id)`（或等价重取） |
| **R5** | `live.channel.*` 对账缺 in-flight 合并；catch 不摘条目 | `room_frames.dart:418–443` vs web `chat.ts:388–400` | 加 `Map<String, Future>` 合并；catch 分支补 `removeChannel\` 语义（与 web 对齐需谨慎：web 的 catch 覆盖 403 与网络错） |
| **R6** | `AylaOwnedLivePicker` 订阅已退役总线（死订阅） | `create_sheet_forms.dart:242–267` vs `room_frames.dart:148–156`（注入 store 时不再 emit） | 改读 `aylaDirectoryStore` 或直接删该订阅 |

### 4.2 需要实测确认（不做代码推论）

1. **「待实测」用户复现路径是否含登出/401**：这是 R1 是否命中的唯一分水岭。若用户是「全新启动 App、自动登录」，则 R1 不触发，主因转向 R2/R4。
2. **「待实测」REST 详情对账的 403 比例**：`voice.channel.created` 后 `GET /voice/channels/<id>/` 若因可见性（`visibility=group` 白名单）返回 403，则会静默丢弃（`room_frames.dart:366–370`）——需在真实账号下抓包确认。
3. **「待实测」`live_catalog` 与 `chat_user_*` 双投递是否重复**：`live/services.py:364–374` 只投 `chat_user_*`；`live/consumers.py` 另有 `LIVE_CATALOG_GROUP`（`:42`）仅用于 `live.viewers.changed`（`:512`）——两条投递是否叠加需观测。
4. **「待实测」群内开播（`group_live_page.dart:265–272`）后回到群内直播列表**：因 R2，列表依赖 `didUpdateWidget`/`_onChanged` 才刷新，需确认是否表现为「不重启不出现」。

---

## 5. 装配时序核对（回答 Lead 的「初始化时序」问题）

启动顺序（`main.dart`）：

1. `:203` `ProviderContainer()` 建立（唯一容器，`:282–285` 交给 `UncontrolledProviderScope`）
2. `:215` `initWsManager(tokens: auth)`
3. `:218` `aylaRegisterCoreDataLoader()` · `:223` `aylaRegisterChatStateResolver()`
4. `:235–245` auth 监听（收藏作用域）
5. `:255` `aylaStartSocialTracking`
6. **`:259` `aylaStartRoomFrames(container)`** → `room_providers.dart:244–253`：`bridge.attach(chatWsProvider)` + `_wireDirectoryTracking`（`:257–273`：注册 `itemUpsertHooks` ×3 + `aylaStartDirectoryTracking`）
7. `:262` `aylaStartPostsFrames`
8. `:279` `aylaBootstrapSession`（异步，不阻塞首帧）

**结论**：在**首次启动**这条路径上，装配是完整的（帧桥已挂、订阅已 start、hooks 已注册），且发生在登录之前 —— 比 web 的懒装配（`directory.ts:270` 首次 `loadDirectory` 才 `ensureDirectoryTracking`）更早，不存在「帧先到、通路未装配」的漏帧窗口。**时序本身没问题**（排除 Lead 的假设 3 的一部分）。
真正的问题是**拆了不装**（R1）：拆卸路径有 4 处调用，重装路径 0 处调用。

另需注意：`directory_tracking.start()` 会捕获当时的 `voiceState/liveState/boardgameStore` 实例（`directory_tracking.dart:81–84`）；这些 provider 是非 autoDispose 全局单例（`room_providers.dart:49–54`），容器存活期内引用不变 ⇒ 不存在「捕获了旧实例」的问题。

---

## 6. 建议的修复优先级（供后续执行者）

1. **R1**（最高，改动最小、影响最大）：补登录后重装 + 让 `aylaStopRooms` 不拆目录装配。
2. **R2**（高）：群内三页换 `AylaDirectoryController`，模板照抄 `group_page.dart:317–357`。
3. **R3**（中）：`_roomId` 增顶层 `room_id`；补一条**用真实帧形状**的回归测试（当前 `room_live_test.dart:267–270` 喂的是 `room{id}`，掩盖了缺陷）。
4. **R4**（中）：桌游创建成功后本地落库 + noteCreated。
5. **R5/R6**（低）：对齐 web 的合并与死订阅清理。

---

## 7. 审计边界声明

- 本报告**未修改任何 `lib/` 文件**，仅新增本文档。
- **未运行** `flutter run` / `flutter test` / `dart analyze`（审计阶段按纪律不跑）。
- 文中「✅ 等价」仅指**代码结构等价**；运行时表现仍需按 §4.2 实测项确认。
