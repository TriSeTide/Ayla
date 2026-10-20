# 审计 A：chat WS 消息链路一比一复刻（只读审计）

> 范围：`Ayla/flutter/lib/core/ws/chat_ws.dart`(925 行)、`state/chat_state.dart`(540)、`state/message_state.dart`(419)、
> `state/social_store.dart`、`state/auth_bootstrap.dart`(449)、`state/chat_providers.dart`(226)、`core/ws/ws_manager.dart`(335)。
> 对照事实源：`Ayla/web/src/ws/chat.ts`(1000 行) + `stores/chat.ts` + `stores/message.ts` + `stores/social.ts`。
>
> **纪律**：本文只读审计，**未改任何代码**。每条结论带两侧 `文件:行`；无证据者显式标 **「待实测」**。
> 实测边界（Lead 已确认，本文不重复验证）：后端 8100 的 chat WS 全链路正常（ping/pong、subscribe、chat.subscribed、跨账号 message.new 均实测收到）；
> 既有 84 个热更新单元测试全绿。故本文只定位**Flutter 客户端真实运行链路上的断点**。

---

## 0. 结论摘要

| # | 判定 | 一句话 |
|---|---|---|
| **D1** | 🔴 **代码缺陷（最高置信）** | **私信会话列表 / 宽屏消息左列读的是「页面私有 `AylaPagedList`」快照，不是 social store**（web 读 `useSocialPage`）。WS `message.new` 写进 `chatState` 后，经 `AylaSocialTracking` 只回写进 **social record**，而页面渲染的是**另一个对象** ⇒ 列表永不刷新（不显示新消息、不显示预览、不涨未读、不重排）。 |
| **D2** | 🔴 **代码缺陷（高置信）** | **chat 通道 owner `connect()` 无幂等**：登录链先 `wsManager.connectAll()` 再 `client.connect()` ⇒ `WsChannel.connectWithToken` 被调两次、开**两条 socket**，旧 `_sub` 未取消。presence 的同名方法有幂等（`presence_ws.dart:69-74`），chat **没有**。 |
| **D3** | 🔴 **代码缺陷（高置信，独立）** | **注册路径完全不接 chat owner**：`register_page.dart:161` 只 `wsManager?.connectAll()`，**从未** attach ⇒ `onEvent/onOpen` 恒 null ⇒ 注册后进应用**收不到任何 chat 帧**，直到下次登录/冷启动。 |
| **D4** | 🟠 **代码缺陷（中置信）** | **预加载门「全成功才灌 chatState」**：`_seedChatStateFromSocial()` 在 `await Future.wait(20+ 请求)` **之后、try 之内** ⇒ 任一请求抛错即跳 catch ⇒ chatState 空 ⇒ `chat_ws.dart:688` 的 `if (conv != null)` 全部落空。 |
| — | ✅ **完好** | 帧解包（`frame['data']` 嵌套）、41 条 case 分发骨架、`registerAuthorizedGroups` 退避重试、首连/重连分档、`resume` 基线计算、`message.new` 的未读/已读/子群判定、`bumpUnread`/`markReadSeqs`/`adjustPostUnread`、`favorite.changed`、两条帧桥挂载、voice/live/boardgame/bootstrap 帧形状取值。 |

### 对 Lead 四点的直接答复

1. **帧解包正确**。`chat_ws.dart:442-444` 取 `frame['data']`（嵌套对象），与后端 `consumers.py:255-275` 的 `{type, data:{...}}` 一致。
   `voice/live` 帧是 `{type, data:{channel_id,...}}`（`consumers.py:515-536 / 570-620`），Flutter `_channelId`（`room_frames.dart:491-496`）读 `data.channel_id` ✓。
   `boardgame.*` 是**例外形状**：后端 `_boardgame_event`（`boardgame/services.py:113-127`）发的是 **顶层** `{"type", "room_id", "room":{...}}`，**没有 `data` 包装**；
   Flutter `_roomId`（`room_frames.dart:498-508`）先读 `frame['room']['id']`、再读 `frame['data']['room_id']` ⇒ **对 created/updated 正确**；
   `deleted` 走 `frame['room_id']`（顶层，`services.py:195`）—— 但 `_roomId` 的**第二分支只读 `data.room_id`**：
   ```
   room_frames.dart:498  static String _roomId(Map frame) {
   :499    final raw = frame['room'];
   :500    if (raw is Map) return raw['id']...;          // created/updated ✓
   :503    final data = frame['data'];
   :504    if (data is Map) return data['room_id']...;   // ← deleted 的 room_id 在**顶层**，这里读不到
   :507    return '';
   :508  }
   ```
   ⇒ **🔴 D5：`boardgame.room.deleted` 的 `roomId` 恒为空 ⇒ 直接 return ⇒ 删除帧被静默丢弃**（全局表不摘、目录不摘）。
   同一函数注释（`:502-503`）明确写了「顶层只有 room_id」，但代码没实现顶层分支 —— **注释与实现不符**（已确证，非推测）。
   **这条不在你的四点清单里，但它是真实的形状差异缺陷**（web `chat.ts:854` 读 `frame.room_id` 顶层）。
2. **失败重试完整**。`chat_ws.dart:314-330`（catch → `_registrationRetry ??= Timer`）+ `_registrationBackoffMs`（`:338-344`，`5000*2^n` 上限 60s），
   与 web `chat.ts:310-317` 逐条等价；`_registrationPending` 单飞（`:274-275`）、`whenComplete` 清位（`:331-333`）均在。**不会「失败后永不重试」**。
3. **首连补发 / resume 基线完整**。`_onOpen`（`:400-417`）首连补发 `subscribe`（`:411-416`，一次发全部，等价 web `chat.ts:191-194` 的 100 一组）、
   重连逐条 `resume`（`:401-408`）；`resume` 的 `lastSeq = max(head, bucket, arg)`（`:242-246`）+「无基线只发 subscribe」（`:247-253`）
   与 web `chat.ts:271-280` 等价。**不会跳过消息**。（唯一差异：Flutter 首连补发**不分批**，>100 个会话时一帧发完；web 是 100 一组。
   后端 `_handle_subscribe` 遍历全部 `conversation_ids`，不分批也能处理 ⇒ 协议上无害，但 **待实测**大群量场景下的帧大小。）
4. **`if (conv == null) reconcileConversation` 与 web 同形**（`chat_ws.dart:653-656` ↔ `chat.ts:451-452`）。
   但两侧 `conv` 的**可靠性不同**：web 的列表就在同一个 store 里（`loadSocial` 双写 `useChatStore`，`social.ts:172`）⇒ `conv` 几乎必然存在；
   Flutter 依赖预加载灌入（D4）+ 页面 upsert ⇒ 更脆弱。**这是第二层放大因素，不是第一因**（第一因是 D1：即使 conv 存在，列表也不读 chatState）。

---

## 1. 逐帧表：web case → Flutter 等价实现 → 差异

**图例**：✅ 等价｜🔁 机制不同但净效果等价｜⚠️ 有可观测差异｜❌ 缺失

| # | web case (`ws/chat.ts`) | web 行 | Flutter 实现 | Flutter 行 | 判定 | 差异 |
|---|---|---|---|---|---|---|
| 1 | `message.new` | 409-509 | `_onMessageNew` | chat_ws.dart:598-705 | ✅ | 逐条对齐（heads→media→projectionId→confirmedRead→组装→isSelf 幂等键收敛→mention/reply→conv==null 对账→atBottom/子群→私聊即时已读→未读/徽标→setLastMessage→群 bump）。Flutter 的两处**更强**：媒体用强类型 `AylaMediaDescriptor.fromJson`；`AylaChatMessage` 显式带 `subgroupId/seq`。 |
| 2 | `message.recall` | 510-514 | `setRecalled` | :448-449 | ✅ | 直译。 |
| 3 | `subgroup.created/updated` | 515-531 | 构造 `AylaSubGroup` 后 upsert | :454-474 | 🔁 | web 用 `existing?.created_at ?? now`；Flutter 读帧 `created_at`（帧不带→null）并由 `upsertSubgroup` 保留本地值（subgroup_state.dart:160）。净效果同。 |
| 4 | `subgroup.deleted` | 532-545 | `removeSubgroup` + 回退默认组 | :475-484 | ✅ | `_defaultSubgroupId`（:734-739）对应 web `find(is_default)?.id ?? null`。 |
| 5 | `subgroup.read` | 546-557 | `aylaApplySubgroupReadReceipt` | :485-511 | ✅ | 均只在 `marked_seqs` 存在时精确移除；旧帧不清空未读。 |
| 6 | `message.poke` | 558-598 | `_onMessagePoke` | :742-781 | ⚠️ | web 直接拼 `d.sender_name/d.target_name`（可能 undefined）；Flutter `_strOr(...,'有人'/'对方')`（:761-762）兜底。**属改进，非缺陷**。 |
| 7 | `message.read` | 599-607 | `_onMessageRead` | :717-731 | ✅ | ①任何 user_id 都 `markReadByMessage`；②本人 + `unread_seqs_complete===false` 才 reconcile。 |
| 8 | `typing` | 608-611 | `break` | :512-513 | ✅ | 均由页面 `onFrame` 消费（chat_support.dart:741-751）。 |
| 9 | `history.sync` | 612-616 | `setLastSeq` | :514-515 | ✅ | 只推进基线（message_state.dart:347-353）。 |
| 10 | `chat.subscribed` | 937-940 | `_subscriptionHeads` max | :516-521 | ✅ | 单调。 |
| 11 | `elysia.reply` | 885-936 | `_onElysiaReply` | :784-830 | ✅ | 入库/预览/群 bump/贴底已读/未读+徽标全同。 |
| 12 | `group.created`/`group.joined` | 654-666 | 读**顶层** `frame['conversation']` | :568-577 | ✅ | 后端正是顶层（services.py:1260-1268 / 1333-1342）✓。 |
| 13-17 | 四/五类认证通知 | 617-648 | notices.push + badges.fetch | :522-560 | ✅ | 文案逐字同（含 `?? "有人"/"群聊"` 兜底）。 |
| 18 | `group.member.left` | 649-653 | notices.push | :561-567 | ✅ | 不拉 badges（web 同）。 |
| 19 | `favorite.changed` | 866-884 | `aylaFavoriteApplyChanged` | :849-858 | 🔁 | web 分两档（post 走 `favoriteByPostId`，其余走模块缓存）；Flutter 只走收藏状态机（posts_store 已登记不做第二份缓存）。对外行为一致。 |
| 20 | `post.created` | 766-792 | 帧桥 `AylaPostsFramesBridge` | posts_frames.dart:113-118,138-173 | 🔁 | chat 客户端内 no-op（:585-590 default），由 `main.dart:262` 挂的桥二次消费；帧照样流经 `onFrame`（:592-594）✓。 |
| 21 | `post.deleted` | 793-798 | posts_frames.dart:119-124 | 同上 | 🔁 | 读顶层 `frame['post_id']`（`_postIdOf`:285-292），后端正是顶层（posts/services.py:389-390）✓。 |
| 22 | `post.updated` | 799-813 | posts_frames.dart:113-118 | 同上 | 🔁 | 同 created 但不 +1 未读 ✓。 |
| 23 | `post.viewed` | 814-840 | posts_frames.dart:125-126,181-203 | 同上 | 🔁 | 本人→markViewedBatch+去重 -1；他人→updatePostViewCount；30s 去重窗口（:230-256）与 web :41-83 同。 |
| 24 | `comment.created/deleted` | 841-844 | `kAylaChatWsOutOfBatchFrames` | :79-82 | ✅ | web 本身 no-op（详情页消费）；Flutter 详情页同样订阅（post_detail_page.dart:218）。 |
| 25 | `voice.channel.created` | 667-678 | 拉详情 + bump 可见群 | room_frames.dart:254-261 | 🔁 | 同形（REST 权威 + bumpGroups）。 |
| 26 | `voice.channel.deleted` | 679-684 | removeChannel + 目录摘除 | room_frames.dart:262-268 | ✅ | 不回退排序 ✓。 |
| 27 | `voice.channel.member_count_changed` | 685-719 | `_applyVoiceMemberCount` | room_frames.dart:373-410 | ✅ | 帧带排序投影则 patch，否则 REST 对账（:392-401）；人数增加才 bump（:405-409）。**顺序与 web :691-717 等价**。 |
| 28 | `voice.channel.updated` | 720-727 | 拉详情（不 bump） | room_frames.dart:262-266 | ✅ | — |
| 29 | `live.channel.created` | 728-731 | reconcile（不 bump） | room_frames.dart:269-272 | ✅ | — |
| 30 | `live.channel.status.changed` | 732-744 | reconcile + 开播 bump | room_frames.dart:274-281 | ✅ | `_liveFrameStatusIsLive`（:485-489）✓ |
| 31 | `live.channel.deleted` | 745-750 | removeChannel + 摘除 | :282-286 | ✅ | — |
| 32 | `live.channel.updated` | 751-755 | reconcile（不 bump） | :273-276 | ✅ | — |
| 33 | `live.viewers.changed` | 756-765 | `_applyViewerCount` | :447-455 | ⚠️ | Flutter 要求 `viewer_count` 非 null 才 patch（:452-453）；web 会写 undefined（通常 no-op）。**待实测（低风险）**。 |
| 34 | `boardgame.room.created` | 845-852 | `_noteCreated` + 拉房间 | :287-292,465-479 | ⚠️ | 形状：后端**顶层** `room`（boardgame/services.py:113-127）✓ Flutter `_roomId` 读 `frame['room']['id']` ✓。 |
| 35 | `boardgame.room.deleted` | 853-856 | removeRoom + 摘除 | :313-320 | ❌ | **D5（已确认，非推测）**：`_roomId`（:498-508）只读 `frame['room']['id']` 或 `frame['data']['room_id']`；真实 deleted 帧是**顶层** `{"type","room_id"}`（后端 `_boardgame_event(room_id, "boardgame.room.deleted")` **不传 room** ⇒ 既无 `room` 键也无 `data` 键，boardgame/services.py:113-127,195）⇒ `_roomId` 返回空 ⇒ `:314 if (id.isEmpty) return;` **整帧静默丢弃**。web `chat.ts:854` 读 `frame.room_id` 顶层 ⇒ web 正确。**单测被帧形状掩盖**：`room_live_test.dart:267-270` 构造的是 `{'type':..., 'room':{'id':'9'}}`（**带 room 键**）⇒ 单测绿、真机坏。 |
| 36 | `boardgame.room.updated` | 857-865 | reconcile | :293-297 | ⚠️ | 同 34（顶层 room）✓。 |
| 37 | `elysia.voice.call.status/projected` | （web 同无分支） | default → 透传 `onFrame` | :585-594 | ✅ | 两侧都只流经 handlers。 |
| 38 | `pong`/`error` | 941-943 | `break` | :582-584 | ✅ | `pong` 更早被 `WsChannel._onMessage` 静默吞掉（ws_manager.dart:160），**不进 dispatch** —— 比 web 更早一层，无副作用。 |
| 39 | **群 presence 失效信号** | 946-948 | `_queueGroupPresenceFor` | room_frames.dart:227-233 | ✅ | 三条前缀判据逐字同（`live.viewers.changed` 不在其中，两侧一致）。 |

### 分发骨架的其他核对（chat_ws.dart:438-595）
- 顶层 `type` 非 String ⇒ 静默丢弃（:439-440）；`data` 非 Map ⇒ 空 Map（:442-444，web 会 undefined 访问）—— Flutter **更健壮**；
- 每条 case **无 break**（Dart 3 switch statement 语义，不穿透）⇒ 无 fall-through 风险 ✓；
- case 结束后**统一**把原始 `frame` 广播给 `_handlers`（:592-594），与 web `chat.ts:949` 同位置 ⇒ 两条帧桥能收到全部帧 ✓；
- 唯一结构性差异：web 在 `chat.ts:403-405` 每次 dispatch 取三个 store 快照；Flutter 构造时注入实例（:139-147）⇒ 引用恒定，等价且更安全。

---

## 2. 用户实报「别人发的消息不自动出现」——根因链逐步核查

链路：`connect()` → `registerAuthorizedGroups()` → `subscribe` 帧 → 服务端 `group_add` → `message.new` → `chatState`/`messageState` → **UI 重建**。

### 2.1 `connect()` —— 🔴 断点（D2；注册路径 D3）

生产入口唯一：`auth_bootstrap.dart:116-119`
```
:117  wsManager?.connectAll();      // ① 先开 socket（chat + presence）
:118  _startChatWs(container);      // ② → :135-140 attach(manager.chat) + client.connect()
```
- `_startChatWs`（`auth_bootstrap.dart:135-140`）：`if (manager != null) client.attach(manager.chat);` 然后 `client.connect();`
- `attach`（`chat_ws.dart:183-188`）是**唯一**设置 `onEvent/onOpen/onStatus` 的地方。

**🔴 D2**：`manager.chat` 已在 ① 里 `connect()` 过（`ws_manager.dart:110-115` → `connectWithToken` :118-137）；
② 又调 `WsChannel.connect()` → 再次 `_connectFactory(uri)`，**覆盖 `_channel`/`_sub`，旧 `_sub` 未 cancel**。
`WsChannel` 无「已 connecting/online 就跳过」判断；对照 presence 的同名方法有幂等（`presence_ws.dart:69-74`）。
⇒ 每次登录开 **2 条 chat socket**；旧 socket 的 `onDone` 仍绑 `_onClosed`（`ws_manager.dart:128-132`），
一旦旧连接关闭就把**共享的** `_status` 写成 `connecting`（:166）并起重连（:167）⇒ **状态抖动 + 无谓重连**。
帧重复投递本身不致命（`upsertMessage` 按 seq 去重 message_state.dart:410-418；`bumpUnread` 有 `!unread.contains(seq)` 保护 chat_state.dart:196），
但**抖动期间 owner 会重发 subscribe/resume**，与 `registerAuthorizedGroups` 的退避可能叠加。
**判定：D2 导致「热更新时好时坏」，不直接导致「一条都收不到」。**

**🔴 D3（独立缺陷）**：`register_page.dart:155-169` 只做
`auth.setTokens → auth.setUser → wsManager?.connectAll() → AppInit.instance.run → context.go('/group')`，
**从未调用 `_startChatWs` / `aylaApplyLoginSession`** ⇒ `AylaChatWsClient` 从未 attach ⇒ `_channel == null`
⇒ `connect()` 首行 `if (channel == null) return;`（`chat_ws.dart:191-193`）直接返回 ⇒ **chat 整条链路静默失效**。
对照 web：`useAuth.ts:18-36` 的 `login` 与 `register` **都**调 `chatWS.connect()`（同一单例，天然已挂载）。
**若用户是「注册后进入」场景，D3 就是唯一根因。**

### 2.2 `registerAuthorizedGroups()` —— ✅ 完好

`chat_ws.dart:273-336`：`_registrationPending` 单飞（:274-275）｜分页游标 + 无效游标抛错（:296-300）｜
`putIfAbsent` 基线（:289 ↔ web :297 的 `if (!has) set`）｜每页 `subscribe`（:291-295）｜
失败 `setStatus(failed, '群消息订阅未完成，正在重试')` + `Timer(backoff)`（:314-330）｜退避 `min(5000*2^n,60000)`（:338-344）。
与 web `chat.ts:283-320` 逐条等价。**不会「失败后永不重试」**。

⚠️ 一处**比 web 更安全**：web 的 `sendJson` 在 socket 未 OPEN 时直接丢弃帧（`chat.ts:380-384`）；
Flutter 的 `WsChannel.send`（`ws_manager.dart:216` → `:204-210`）调 `sink.add`，而
`web_socket_channel 3.0.3` 的 `AdapterWebSocketChannel` 用 `StreamChannelController(sync:true)`
（pub 缓存 `web_socket_channel-3.0.3/lib/adapter_web_socket_channel.dart:54-56`）⇒ sink 在 ready 前**缓冲**、ready 后发出。
因此 `registerAuthorizedGroups` 在未 OPEN 时发的 `subscribe` 仍能送达。`_onOpen` 补发仍需要（token 过期重连等场景）。

### 2.3 `subscribe` 帧形状 —— ✅ 完好

`chat_ws.dart:229-232`：`{'type':'subscribe','conversation_ids': batch}`，每 100 个一组（:222-233 + 常量 :85）；
后端 `consumers.py:203-222` 读 `content.get("conversation_ids")` ✓。与 web `chat.ts:256` 逐字一致。

### 2.4 服务端 `group_add` → `message.new` —— ✅ 完好（Lead 已实测）

`consumers.py:203-222`（订阅校验成员后 `group_add` → 回 `chat.subscribed`）｜
`services.py:468-496`（`group_send` → `chat_conv_{id}`）｜`consumers.py:255-275`（`chat_message_new` 组装 `{type:'message.new', data:{...}}`）。

### 2.5 `message.new` → `chatState`/`messageState` —— ✅ 逻辑完好（受 D4 放大）

`_onMessageNew`（`chat_ws.dart:598-705`）逐步对照：

| 步骤 | web | Flutter | 判定 |
|---|---|---|---|
| heads 前推 | :411 | :601-604 | ✅ |
| 子群归属兜底默认组 | :416-423 | :607-608 | ✅ |
| 已读确认（跨子群） | :419 | :609-610 | ✅ |
| 消息入库（幂等键收敛 pending） | :439-445 | :641-647 | ✅ |
| mention / reply 判定 | :446-450 | :648-652 | ✅ |
| conv==null ⇒ REST 对账 | :451-452 | :653-656 | ✅ 同形 |
| atBottom（`viewerAtBottom` 默认 true） | :453-455 | :657-659 | ✅ |
| 子群「正在看」判据 | :456-463 | :660-676 | ✅ |
| 私聊+贴底 ⇒ 即时已读 + 精确 POST | :461-468 | :666-676 | ✅ |
| 未读序号 + 子群未读 + 徽标 | :469-486 | :677-687 | ✅ |
| setLastMessage（含 segments 摘要） | :487-502 | :688-702 | ✅ |
| 群 bumpGroupActivity | :504-506 | :703 | ✅ |

**⇒ 「消息进不进 messageState」只取决于帧是否到达（2.1/2.4）。**
若「在窗口里也看不见」，只可能是 WS 未连/未订阅（D2/D3）或**子群视图过滤**：
`group_chat_page.dart:71-79` 的 `aylaMessageInSubgroup` + `:804-811` 的过滤；默认组视图含 `subgroup_id==null` 的旧消息 ✓
与 web `useChat.ts:69-78` 一致。**若发送端不带 `subgroup_id` 而接收端停在非默认子群，消息会「合理地」不显示 —— 待实测（T5）。**

### 2.6 UI 重建 —— 🔴 **D1：会话列表的确定断点**

**会话内消息列表（群聊/私聊窗口）—— ✅ 完好**
- 群聊：`group_chat_page.dart:786-787` `ref.watch(messageStateProvider)` + `:797-802` `messagesOf(groupId)` ⇒ `upsertMessage` 的 notify（message_state.dart:138）触发重建 ✓
- 私聊：`chat_support.dart:904-905` `ref.watch(messageStateProvider)` + `ref.watch(chatStateProvider)` ✓

**会话列表（`/messages` 私信列表）—— 🔴 断**
```
web:
  MessagesPage.tsx:50-51   const privatePage = useSocialPage("conversations", { type: "private" });
                            const conversations = privatePage.items;      // ← 读 social store
  stores/social.ts:112-116  useChatStore.subscribe((next, old) => {
                              if (next.conversations !== old.conversations)
                                reconcileCached("conversations", next.conversations, old.conversations); });
                            // chatState 一变 ⇒ 就地合并进 social record ⇒ 组件重渲染

Flutter:
  messages_page.dart:111    AylaPagedList<AylaConversationSummary>? _conversations;   // ← 页面私有快照
  messages_page.dart:131-137  _conversations = _pager((cursor) => listConversationsPage(type:'private'), ...)
  messages_page.dart:174-177  pager.load() 后**再无写入**
  messages_page.dart:393-399  _sortedPrivate() => aylaSortPrivateByActivity(_conversations!.items, ...)
  messages_page.dart:529-531  AylaConversationList(conversations: _sortedPrivate(), ...)   // ← 渲染 pager
```
WS 帧写的是 `chatState`（`chat_ws.dart:682` bumpUnread / `:688-702` setLastMessage）；
`AylaSocialTracking`（social_store.dart:960-1006）确实把 `chatState` 变化 `reconcileCached` 进 **social record**（:972/:995），
但页面渲染的是 **pager**，不是 record ⇒ **帧到了、store 也更新了、屏幕上什么都不变**。
唯一的桥 `_onPagerChanged`（messages_page.dart:180-191）方向相反（pager → chatState），救不了。

**决定性证据（本轮新查，grep 实测）**：
- `messages_page.dart` **全文件 0 命中** `aylaSocialStore` / `AylaSocialController` ⇒ 私信列表确实不读 store;
- `messages_page.dart:140-144` 的 `onFrame` **只处理认证帧**（`aylaIsAuthRefreshFrame`：好友/群申请/邀请五类），**完全不理会 `message.new`**;
- `chat_support.dart`（宽屏左列宿主）**全文件 0 命中** `aylaSocialStore` / `AylaSocialController<AylaConversationSummary>`，其 `onFrame`（`:1033-1041`）同样**只处理认证帧**。
⇒ 私信列表在收到 `message.new` 时**没有任何刷新动作**：既不读被 tracking 更新的 social record，也不在 onFrame 里主动重取 ⇒ **D1 成立且无需实测即可确认**。

**宽屏消息左列 —— 🔴 同一缺陷**
`chat_support.dart:1003` `AylaPagedList<AylaConversationSummary>? _conversations`（:1021-1028 建 pager），
`:1244-1249` `conversations: aylaSortPrivateByActivity(_conversations!.items, ...)`，渲染点 `wide_messages_sidebar.dart:209-210`。

**对照组（证明不是「所有列表都坏」）**
- 主页群列表：`home_page.dart:98` `AylaSocialController<AylaConversationSummary>? _pager`（:312-321 用 `aylaSocialStore` + `{type:'group'}`）⇒ 读 store ⇒ ✓
- 群页 rail：`group_page.dart:262` `AylaGroupDirectory(chatState: ...)`（内部 `group_support.dart:361-366` 用 `AylaSocialController`）⇒ ✓
- `group_pages_test.dart:824-886` 的端到端锁**正是锁这一档**（social.load → message.new → rail 顺序变化）⇒ 84 例全绿**不覆盖 D1**。

**⇒ D1 是「别人发的消息不出现在列表」的第一因**，与 Lead 的实测结论（后端正常、单元测试全绿）完全自洽：
现有测试锁的是 store/rail/单帧逻辑，**没有任何一条测试锁「私信列表页 ← social store」这条数据源**。

### 2.7 放大因素：chatState 是否真被填充（D4）

`chat_ws.dart:688` 的 `if (conv != null)` 与 web `chat.ts:487` 同形，但两侧 `conv` 的可靠性不同：
- web：列表页 `loadSocial` **双写** `useChatStore.upsertConversation`（`social.ts:172`）⇒ chatState 与社交目录恒等；
- Flutter：`social_store.dart:433-441` 有同样回流（`onConversationLoaded?.call(item)`），由 `chat_providers.dart:90-93` 的 `bindRehydration`
  接到 `chatState.upsertConversation`；另有 `app_preload.dart:64-79` 的 `_seedChatStateFromSocial()` 兜预取。

**🔴 D4**：`app_preload.dart:86-183` 结构：
```
:87   try {
:88-176    await Future.wait(<Future<void>>[ ...20+ 个预取请求... ]);
:177-179  _seedChatStateFromSocial();          // ← 在 try 内、wait 之后
:180  } catch (error) { debugPrint('[预加载] 核心数据加载失败 $error'); }
```
⇒ **任一预取请求抛错 ⇒ seed 永不执行** ⇒ chatState 只剩页面自己 upsert 的部分。
`_onMessageNew` 的 `reconcileConversation` 兜底（:653-656）会补一次 REST 摘要 ⇒ **能自愈，但慢一拍**
（当前这条消息的 setLastMessage/bumpUnread/bumpGroupActivity 已丢）。
**判定：D4 是真实缺陷，属「放大/延迟」而非「彻底不更新」。标 待实测（T4）。**

---

## 3. 会话列表排序 / 未读 / 红点：与 web 的差异清单

| # | 维度 | web | Flutter | 判定 |
|---|---|---|---|---|
| 1 | `bumpGroupActivity` 单调 | chat.ts:85-91 | chat_state.dart:77-82 | ✅ |
| 2 | `bumpConversationActivity` 单调 | chat.ts:93-99 | chat_state.dart:85-90 | ✅ |
| 3 | `bumpUnread`（seq 投影 + `unread_seqs_complete===false` 不累加 + mention/reply） | chat.ts:182-216 | chat_state.dart:172-223 | ✅ |
| 4 | `clearUnread` 只清计数 | chat.ts:218-223 | chat_state.dart:226-232 | ✅ |
| 5 | `decrementUnread`（下限 0 + 移除 seqs） | chat.ts:225-237 | chat_state.dart:235-252 | ✅ |
| 6 | `markReadSeqs` 两档（完整/不完整） | chat.ts:239-258 | chat_state.dart:258-283 | ✅ |
| 7 | `adjustPostUnread`（仅群、下限 0） | chat.ts:260-267 | chat_state.dart:302-324（消费方 posts_frames.dart:165-167/197-199） | ✅ |
| 8 | `setLastMessage` | chat.ts:175-180 | chat_state.dart:159-165 | ✅ |
| 9 | `setConversations` 同数据不重渲染 | chat.ts:101-123（9 字段 + 写 lastFetched） | chat_state.dart:67-74 + `_sameVisible`:369-388 | ⚠️ Flutter **不写 `lastFetched`**（:16-19 已登记「未实现」）；Flutter 无 `isChatStale` 消费方 ⇒ **无影响**。 |
| 10 | `upsertConversation` peer/成员不从 null 覆盖 | chat.ts:124-151 | chat_state.dart:93-135 | ✅（另有 `members_complete` 保护） |
| 11 | `directory_activity_at` → 活跃时间单调 | chat.ts:145-150 | chat_state.dart:121-133 | ✅ |
| 12 | 私信排序（置顶→活跃→稳定） | chat.ts:275-288 | chat_state.dart:419-440（Dart 无稳定排序 ⇒ 原索引做末位键，等价） | ✅ |
| 13 | **私信列表数据源** | MessagesPage.tsx:50-51（social store） | messages_page.dart:111/393-399/529-531（**页面私有 pager**） | 🔴 **D1** |
| 14 | **宽屏左列数据源** | WideMessagesSidebar.tsx:53-54,70-73,221-223 | chat_support.dart:1003/1021-1028/1244-1249（**页面私有 pager**） | 🔴 **D1** |
| 15 | 群列表/rail 数据源 | HomePage.tsx:53-54；GroupPage.tsx:92 | home_page.dart:312-321；group_page.dart:262 | ✅ |
| 16 | 群活跃度五源 | groupActivity.ts:159-226（消息/直播/语音/桌游/帖子） | home_page.dart:169-180 + `_catalogsFromStores`:196-…；判据封装在 `AylaHomeActivityMap` | ⚠️ **待核（T6）**：本轮**未逐条比对** 24h 窗口 / `status==="live"` / `visibleInGroup` 等判据。不影响「消息」根因。 |
| 17 | 全局红点（`/me/badges/`）触发条件 | chat.ts:467/484/926/932 | chat_ws.dart:674/685/821/827 | ✅（私聊/未打开/@我/爱莉回复） |
| 18 | 子群未读兜底默认组（列表未加载 ⇒ null，不猜） | chat.ts:418 | chat_ws.dart:608 + `_defaultSubgroupId`:734-739 | ✅ |
| 19 | 私信活跃 bump 触发点 | 仅 poke（chat.ts:594） | 仅 poke（chat_ws.dart:779） | ✅（两侧都不在 message.new 里 bump 私信） |

---

## 4. 明确区分：代码缺陷 vs 需实测

### 4.1 已确证的代码缺陷

| ID | 缺陷 | 证据（web / Flutter） | 影响 |
|---|---|---|---|
| **D1** | 私信列表 + 宽屏左列读**页面私有 pager**，不读 social store ⇒ WS 的 `setLastMessage`/`bumpUnread` 不反映到列表。**且两页的 `onFrame` 只处理认证帧、不理会 `message.new`** ⇒ 无任何兜底刷新 | web `MessagesPage.tsx:50-51,154-157,260-266` + `WideMessagesSidebar.tsx:53-54,70-73,221-223` + `stores/social.ts:112-120`；Flutter `messages_page.dart:111,131-137,140-144,393-399,529-531` + `chat_support.dart:1003,1021-1028,1033-1041,1244-1249`（两文件均 0 命中 `aylaSocialStore`） | **「别人发的消息不出现在列表」第一因**（已确证，无需实测）；也不显示预览、不涨未读、不重排 |
| **D2** | chat owner `connect()` 无幂等 ⇒ 登录链开两条 socket | `auth_bootstrap.dart:117-118` + `ws_manager.dart:110-137` + `chat_ws.dart:191-199`；对照 `presence_ws.dart:69-74` | 状态抖动/无谓重连 ⇒ 热更新**间歇性**失效 |
| **D3** | 注册路径不接 chat owner | `register_page.dart:155-169` vs `auth_bootstrap.dart:135-140`；web `useAuth.ts:18-36` 两入口都 connect | 注册后进入 ⇒ chat **全链路静默失效** |
| **D4** | 预加载任一失败 ⇒ `_seedChatStateFromSocial()` 不执行 ⇒ chatState 空 | `app_preload.dart:86-183`（seed 在 :177-179，位于 `Future.wait` 之后、try 之内） | `if (conv != null)` 全落空（预览/未读/排序丢一拍，REST 对账可自愈） |
| **D5** | `boardgame.room.deleted` 取不到 `room_id`（顶层 vs `data`/`room`）⇒ 帧被静默丢弃 | `room_frames.dart:498-508`（`_roomId`）+ `:313-320`（deleted 分支）vs 后端 `boardgame/services.py:113-127,195`（deleted 只发顶层 `room_id`，**无 room、无 data**）与 web `chat.ts:854`（读 `frame.room_id`） | 桌游列表/全局表**不摘除已删除房间**（单向陈旧）；`room_live_test.dart:267-270` 的帧带 `room` 键 ⇒ **单测掩盖** |
| **D6** | `message.poke` 名字兜底不同 | `chat_ws.dart:761-762` vs `chat.ts:585-588` | 仅文案（Flutter 更好）——**非缺陷** |
| **D7** | 首连补发 `subscribe` 不分批 | `chat_ws.dart:411-416` vs `chat.ts:191-194`（100 一组） | 协议上无害（后端遍历全部 id）；>100 会话时的单帧大小 **待实测** |

### 4.2 必须实测才能确认

| ID | 假设 | 需要的实测 |
|---|---|---|
| **T1** | 真机上 chat WS 到底连没连、有没有发 subscribe、`chat.subscribed` 有没有回 | 在 `chat_ws.dart:191`（connect 入口）、`:400`（onOpen）、`:419`（send）、`:516`（chat.subscribed）打点；或看现有 `[CHAT-SUBSCRIBE]` 类日志。**这是区分 D2/D3 谁在起作用的唯一办法**（D1 不需实测：代码层已确证列表不读 store、onFrame 不管 message.new）。 |
| **T2** | D2 的两条 socket 是否真发生 | 在 `ws_manager.dart:118`（connectWithToken）计次；观察登录后 5s 内连接数与 `onClosed` 触发次数。 |
| **T3** | 用户场景走**登录**还是**注册**入口 | 若确认「注册后首次进入」，D3 即唯一根因，其余只是叠加。 |
| **T4** | D4 是否实际发生 | 搜日志 `[预加载] 核心数据加载失败`。 |
| **T5** | 「群里看不到别人消息」是否只是子群视图过滤 | 另一账号往**非默认子群**发消息、接收端停在默认组：应不显示；切到该子群应显示。判据 `group_chat_page.dart:71-79`。 |
| **T6** | 群活跃度五源判据是否与 `groupActivity.ts:171-226` 逐条一致 | 逐条比对 `AylaHomeActivityMap`（`home_support.dart`）的窗口/状态判据。 |
| **T7** | D5 在真机上是否表现为「桌游列表残留已删房间」 | 代码层已确证（见 4.1 D5）；实测只用于确认**用户可见症状**：建桌游房 → 删除 → 观察列表是否仍显示。另：`room_live_test.dart:267-270` **确认**构造帧带 `room` 键 ⇒ 单测掩盖，修 D5 时必须同时改这条测试的帧形状为 `{'type':..., 'room_id':'9'}`。 |

---

## 5. 修复规格（给后续修复的人，按优先级；本文不改代码）

### P0-1（D1）—— 私信列表改用 social store
1. `messages_page.dart:111` 的 `AylaPagedList<AylaConversationSummary>? _conversations` 换成
   `AylaSocialController<AylaConversationSummary>`，options = `const AylaSocialOptions(type: 'private')`
   （**必须与预加载/其它页同 key**：web `MessagesPage.tsx:50` 就是 `{type:"private"}`）。
2. 删除 `:131-137` 的私有请求；`:180-191` 的 `_onPagerChanged`（pager→chatState）可删（`bindRehydration` 已承担该向，避免双写）。
3. `:393-399` `_sortedPrivate()` 改读 `_conversations.items`；`:529-531` 渲染点不变。
4. footer 的 `AylaDirectoryLoadMore`（`:543-552`）改接 controller 的 `loadMore/refresh`。
5. **同上** `chat_support.dart:1003/1021-1028/1244-1249`。
6. **回归锁**：照 `group_pages_test.dart:824-886` 的形制新增端到端锁 ——
   `aylaStartSocialTracking` 装配 → `loadSocial(conversations,{type:'private'})` → 投喂 `message.new` →
   断言 `MessagesPage` 渲染出的首行预览/未读数**发生变化**。

### P0-2（D2）—— chat `connect()` 加幂等
`chat_ws.dart:191-199`，在 `channel.connect()` 前加与 presence 同款判断：
```dart
if (channel.status == WsChannelStatus.connecting ||
    channel.status == WsChannelStatus.online) {
  _onStatus(channel.status);
  unawaited(registerAuthorizedGroups());
  return;
}
```
并修 `ws_manager.dart:118-137`：`connectWithToken` 开头 `_sub?.cancel(); _sub = null;` + 关旧 `_channel`（防泄漏与误触发 `_onClosed`）。

### P0-3（D3）—— 注册路径复用登录副作用
`register_page.dart:155-169` 的 `wsManager?.connectAll(); AppInit.instance.run(...)` 换成
`aylaApplyLoginSession(container, TokenPair(access:..., refresh:...), user: result.user)`（与 `login_route.dart:161` 同链），
确保 `_startChatWs/_startPresenceWs/badges.fetch/room+posts 帧桥` 都被执行。

### P1（D4）—— 预加载拆门
`app_preload.dart:177-179` 的 `_seedChatStateFromSocial()` 移出 `try/catch`；或
`Future.wait([...].map((f) => f.catchError((_) {})))` 让单请求失败不短路整批。

### P1（D5）—— `_roomId` 补顶层分支
`room_frames.dart:498-508` 在 `data['room_id']` 之后**再读** `frame['room_id']`（deleted 帧形状）。

### P2 —— 补端到端锁
- 「列表页 ← WS」（P0-1 内补）；
- 「登录只开 1 条 chat socket」「注册后 chat 已 attach」（P0-2/P0-3 内补）。

---

## 6. 证据索引

**Flutter**
- `core/ws/chat_ws.dart`：79-89 域外登记/常量｜183-188 attach｜191-199 connect｜219-234 subscribe｜240-259 resume｜
  273-336 register｜372-397 状态｜400-417 onOpen｜419-426 send｜438-595 dispatch｜598-705 message.new｜717-731 read｜
  742-781 poke｜784-830 elysia.reply｜849-858 favorite.changed
- `core/ws/ws_manager.dart`：110-137 connect/connectWithToken｜139-146 onOpen｜160 pong｜164-168 onClosed｜173-185 退避｜204-216 send
- `core/ws/presence_ws.dart`：65-76 幂等 connect（对照）
- `core/ws/room_frames.dart`：227-233 前缀｜241-249 handleFrame｜252-321 分支｜373-410 voice 人数｜447-455 viewers｜
  465-479 game reconcile｜485-508 取值（`_roomId` 缺陷在 498-508）
- `core/ws/posts_frames.dart`：109-130｜138-173｜181-203｜230-256｜285-292
- `state/chat_state.dart`：67-74｜77-90｜93-135｜159-165｜172-223｜226-283｜302-324｜369-388｜419-440
- `state/message_state.dart`：128-139｜158-232｜267-291｜301-330｜347-353｜410-418（去重）
- `state/social_store.dart`：348-503（load 双写 433-461）｜567-629 reconcileCached｜960-1006 tracking.onChat｜1030 bindRehydration
- `state/auth_bootstrap.dart`：95-129 applyLoginSession｜116-119 连接顺序｜135-148 _startChatWs/_startPresenceWs｜158-202 logout
- `state/chat_providers.dart`：34-35｜45-58｜74-96｜139-193（**watch→read 根因修复注释**）｜198-204｜209-226
- `state/app_preload.dart`：64-79 seed｜86-184 loadCoreData（seed 位置 177-179）
- `main.dart`：215｜223｜255｜259｜262｜285
- `pages/messages_page.dart`：111｜131-137｜174-191｜393-399｜529-552
- `pages/chat_support.dart`：186 subscribe｜1003｜1021-1028｜1244-1249
- `pages/register_page.dart`：155-169
- `pages/group_chat_page.dart`：71-79｜786-802｜804-811
- `pages/home_page.dart`：98｜169-180｜196-…｜312-321
- `pages/group_page.dart`：262｜442-471

**Web**
- `ws/chat.ts`：148-158｜171-196｜254-280｜283-320｜322-333｜380-384｜402-408｜409-509｜510-557｜558-598｜599-616｜
  617-666｜667-765｜766-844｜845-865｜866-884｜885-936｜937-943｜946-950｜952-955｜958-983
- `stores/chat.ts`：30-34｜85-99｜101-123｜124-151｜175-216｜218-267｜275-288
- `stores/message.ts`：71-88｜95-111｜113-211｜276-330｜379-397
- `stores/social.ts`：108-125｜144-195（双写 172/176/179）｜87-106
- `pages/MessagesPage.tsx`：50-51｜154-157｜260-266
- `components/chat/WideMessagesSidebar.tsx`：53-54｜70-73｜221-223
- `pages/GroupPage.tsx`：92｜196-209
- `pages/HomePage.tsx`：53-54｜65-66｜78｜154
- `hooks/useChat.ts`：46-60｜69-78
- `hooks/useAuth.ts`：18-46（login/register/logout 都 connect）

**后端（契约核对，不重复验证）**
- `apps/chat/consumers.py`：126-180｜194-201｜203-222｜223-251｜255-275｜329-373｜374-…｜537-660｜673-675
- `apps/chat/services.py`：468-496｜498-536｜588-590｜1246-1268｜1320-1342
- `apps/boardgame/services.py`：113-127（**顶层 room/room_id**）｜195
- `apps/posts/services.py`：288-300｜389-391
- `apps/chat/views.py`：140-154
- `apps/chat/pagination.py`：30-…

---

## 7. 一句话交底

> **最可能真因（按置信度）**：
> **D1（私信/宽屏列表读私有 pager，不读 social store）** = 「别人发的消息不出现在列表」的**确定第一因**；
> **D2（chat connect 无幂等，双 socket）** = 「热更新时好时坏」的**确定可疑源**；
> **D3（注册路径不接 chat owner）** = 若用户场景是「注册后进入」则为**唯一根因**；
> **D4（预加载失败短路）** = 放大因素；
> **D5（boardgame.deleted 取不到 room_id）** = 独立的桌游帧静默丢弃缺陷。
>
> **帧解包、41 条 case 分发、subscribe/resume 协议、未读/已读/排序算法本身 —— 全部与 web 等价，不是缺陷。**
