# Ayla web —— 排序与「热更新排序」完整归纳（2026-10-01 通读）

> 事实源：`Ayla/web/src/**`。本文是**排序链路的完整地图**，供 Flutter 侧逐条对账。
> 每节都给出 web 的 `文件:行`；Flutter 对账结论写在 §6。

---

## 1. 结论先行：web 的排序不是「一个函数」，而是**三条链路叠加**

任何一个列表的顺序都由三个东西共同决定：

| 层 | 职责 | 谁负责 |
|---|---|---|
| **① 排序函数** | 决定「谁前谁后」 | `sortGroupsByActivity` / `sortPrivateByActivity` / `sortSubgroupsByActivity` / `sortVoiceChannels` / `sortLiveChannels` / `sortConversations` |
| **② 活跃度源** | 提供排序键 | `useGroupActivityMap`（订阅 4 个全局 store + `groupActivityAt`） |
| **③ 数据回流** | 让列表**拿到新数据** | `loadSocial` 的**双写**（`social.ts:172/179`）+ `ensureSocialTracking` / `ensureDirectoryTracking` 的订阅回流 |

**关键认知**：只修 ① 或 ②，列表照样不动 —— ③ 没接上时，「排序键变了」这件事**根本传不到组件**。
用户本轮实报的「发条消息完全不排上去」正是 **③ 断了**。

---

## 2. 群列表 / 群头像列（同一套排序，两处渲染）

### 2.1 排序函数 —— `components/home/groupActivity.ts`

```ts
// :159–169  活跃度源：订阅四个全局 store + chatState.groupActivityAt
export function useGroupActivityMap() {
  const liveChannels  = useLiveStore((s) => s.channels);
  const voiceChannels = useVoiceStore((s) => s.channels);
  const gameRooms     = useBoardgameStore((s) => s.rooms);
  const posts         = usePostsStore((s) => s.posts);
  const groupActivityAt = useChatStore((s) => s.groupActivityAt);
  return (groupId, lastMessage) => { /* :171–226 五源取 at 最大者 */ };
}

// :238–259  排序：置顶优先 → 新内容时间降序 → 保持传入顺序（稳定）
export function sortGroupsByActivity(list, keyOf) {
  return list.map((item, index) => ({ item, index, pinned: item.is_pinned ?? false, ts: keyOf(item).lastNewAt }))
    .sort((a, b) => (Number(b.pinned) - Number(a.pinned)) || (b.ts - a.ts) || (a.index - b.index))
    .map((x) => x.item);
}
```

**五源事件**（`:171–226`）：

| 源 | 判据 | 文案 |
|---|---|---|
| 最后一条消息 | `isRecent(created_at)`（24h 窗口，`:23`） | `{sender_name}：{preview / content / 类型占位}` |
| 直播 | `status === "live"` + `visibleInGroup` + `started_at` 在窗口 | `{owner_nickname} 开播了 {title}` |
| 语音 | `visibleInGroup` + `created_at` 在窗口 | `{owner_nickname} 创建了语音房 {name}` |
| 桌游 | `visibleInGroup` + `created_at` 在窗口 | `{displayName} 创建了桌游房 {name}` |
| 帖子 | `visibleInGroup` + `created_at` 在窗口 | `{displayName} 发了新帖 {title}` |

最后与 `groupActivityAt[groupId]`（单调 bump）取 `max`（`:224–225`）。

### 2.2 两处渲染

| 处 | 文件:行 | 数据源 |
|---|---|---|
| **窄屏群列表** | `pages/HomePage.tsx:73–80` → `:154 visibleGroups = sortedGroups` | `groups` = `useSocialPage("conversations",{type:"group"}).items`（`:64–72`） |
| **宽屏群头像列** | `pages/GroupPage.tsx:205–209` → `:410 <ServerRail groups={sortedGroups}>` | `groups` = `groupPage.items` + 「补当前群」（`:196–203`） |

### 2.3 ⚠️ 排序键的真正来源：`groupActivityAt` 的 bump 点

```ts
// ws/chat.ts:487–507  message.new 到达
if (conv) {
  chat.setLastMessage(conv.id, { ... });        // :490  列表预览
  if (conv.type === "group") {
    chat.bumpGroupActivity(conv.id);            // :505  ★排序键在这里前进
  }
}
```

**⚠️ 整个块以 `conv` 存在为前提** —— 见 §3.3 的致命闭环。

---

## 3. 数据回流（③）—— 本轮真正的断点

### 3.1 `loadSocial` 的**双写**（`stores/social.ts:144–195`）

```ts
const promise = requestPage(kind, options, cursor).then((page) => {
  // …过滤 / 去重…
  merging = true;                                    // :170  回环护栏
  try {
    if (kind === "conversations")
      for (const item of results)
        useChatStore.getState().upsertConversation(item);   // :172 ★写回 chatState
    if (kind === "subgroups") {
      const defaultGroup = page.default;                    // :174 ★默认组是独立字段
      if (defaultGroup && !deleted.has(defaultGroup.id)) {
        useSubGroupStore.getState().upsertSubgroup(options.groupId!, defaultGroup); // :176
        items.set(defaultGroup.id, defaultGroup);           // :177 ★并入列表
      }
      for (const item of results)
        useSubGroupStore.getState().upsertSubgroup(options.groupId!, item); // :179 ★写回 subgroupState
    }
  } finally { merging = false; }                            // :181
  // …patch record…
});
```

**这是整条链的枢纽**：`loadSocial` 既写 social record，**也写回 `chatState` / `subgroupState`**。
⇒ `chatState.conversations` 与服务端目录**恒等** ⇒ `ws/chat.ts:487` 的 `if (conv)` 必然命中。

### 3.2 `ensureSocialTracking`（`stores/social.ts:108–120`）—— 反向回流

```ts
useChatStore.subscribe((next, old) => {
  if (next.conversations !== old.conversations)
    reconcileCached("conversations", next.conversations, old.conversations);   // :114–116
});
useSubGroupStore.subscribe((next, old) => {
  if (next.byGroup !== old.byGroup)
    reconcileCached("subgroups", Object.values(next.byGroup).flat(), …);       // :117–119
});
```

`reconcileCached`（`:87–106`）把新值**就地合并进已加载的 social record**（removed 写 tombstone → 就地替换 → added 前插）。
⇒ **双向闭环**：`loadSocial` 向下写（§3.1），`Tracking` 向上回写（§3.2）。

### 3.3 🔴 致命闭环（本轮根因）

```
chat_ws 收到 message.new
  └─ conv = chatState.byId(convId)
     └─ if (conv != null) {   ← ★ 全部排序更新都在这个门控内
          setLastMessage(…)    // 列表预览
          bumpGroupActivity(…) // ★排序键前进
        }
```

Flutter 侧 `loadSocial` **只写 social record、不写回 chatState**（§3.1 的 `:172/179` 整段缺失）
⇒ 一旦 social 的群集合与 chatState 不等（`loadSocial` 拉到第 2 页 / 新群 / 别处刷新），
`conv == null` ⇒ **`setLastMessage` 与 `bumpGroupActivity` 都不执行** ⇒ **排序永久不动**。

**Lead 探针实测**：
```
WIRE social=g1,g2          WIRE chatState=g2,g1
WIRE after social refresh: social=g1,g2,g3   chatState=g2,g1   ← chatState 缺 g3
```

---

## 4. 子群（用户本轮新报「接到主群去了」）

### 4.1 排序函数（`stores/subgroup.ts:19–23`）

```ts
/** 宽屏侧栏投影：默认组固定第一，其余按最近消息降序，并列保持列表原序。 */
export function sortSubgroupsByActivity(list) {
  return [...list].sort((a, b) =>
    Number(b.is_default) - Number(a.is_default)
    || (b.last_message_seq ?? 0) - (a.last_message_seq ?? 0));
}
```

### 4.2 活跃度推进（`stores/message.ts:97/136/177/326`）

每次消息**落库**都调 `recordMessageActivity(convId, msg.subgroup_id, msg.seq)`（`subgroup.ts:145–161`，单调）。
⚠️ `subgroupId == null` 时**直接 return**（`:148`：无归属的旧消息属固定首位的默认组，不参与排序）。

### 4.3 归属投影（`ws/chat.ts:416–423`）

```ts
const subgroupId = d.subgroup_id ?? null;
const projectionId = subgroupId
  ?? subgroupState.byGroup[d.conversation_id]?.find((sg) => sg.is_default)?.id;   // ← 回落默认组
```

**关键**：`projectionId` 能回落到「默认组」的前提是 **`byGroup[convId]` 已加载**。
未加载 ⇒ `projectionId == null` ⇒ `bumpSubgroupUnread` 跳过（`:471–473`）⇒ **未读/排序挂到主群**。

### 4.4 默认组的双重身份

`page.default`（`social.ts:174`）是**独立字段**，**不在 `results` 里**。
web 显式 `items.set(defaultGroup.id, defaultGroup)`（`:177`）把它并进列表 ⇒ 否则默认组在侧栏**缺席**。

---

## 5. 其他排序（完整性）

| 列表 | 函数 | 文件:行 | 判据 |
|---|---|---|---|
| 私信列表 | `sortPrivateByActivity` | `stores/chat.ts:275–288` | 置顶 → `conversationActivityAt` 降序 → 稳定 |
| 会话数组自身 | `sortConversations` | `stores/chat.ts:30–34` | 只有置顶分组，组内**保持传入顺序** |
| 语音房 | `sortVoiceChannels` | `utils/sortChannels.ts:32–46` | 有人区置顶（`last_occupied_at` 降序）→ 无人有历史（`last_vacant_at` 降序）→ 从未有人（`created_at` 降序） |
| 直播间 | `sortLiveChannels` | `utils/sortChannels.ts:48–61` | 在播（`started_at` 降序）→ 曾播（`ended_at` 降序）→ 从未（`created_at` 降序） |
| 目录 record | `sortItems` | `stores/directory.ts:137–141` | 按 kind 分发到上面两个；game 按 `created_at` 降序 |
| 子群（social record 内） | 内联 | `stores/social.ts:182–184` | 默认组优先 → `last_message_seq` 降序 |

### 5.1 目录的 tracking（第三、四条回流）

`stores/directory.ts:205–219` 的 `ensureDirectoryTracking()`：
订阅 `useLiveStore` / `useVoiceStore` / `useBoardgameStore` / `useAuthStore` / `chatWS.onFrame`，
任一变化 ⇒ `updateCachedItems(kind, next, previous)`（`:148–196`）**就地重排已加载的目录 record**。

⚠️ **web 的排序事实源全是后端持久字段**（`sortChannels.ts:1–22` 文件头原话）：
「无任何前端计数器/本地时间戳 bump —— 刷新不丢、多端一致」。

---

## 6. Flutter 对账结论（本轮 Lead 通读后）

| # | web | Flutter 现状 | 结论 |
|---|---|---|---|
| 1 | **`loadSocial` 双写**（`social.ts:172/179`） | `social_store.dart` 的 `load()` **只写 record**，`upsertConversation`/`upsertSubgroup` **0 命中** | 🔴 **缺失 ⇒ 根因 A**（发消息不排序的直接原因） |
| 2 | `ensureSocialTracking`（`social.ts:108–120`） | `AylaSocialTracking` 已实现并装配（上一轮） | ✅ 已接 |
| 3 | `ws/chat.ts:487 if (conv)` | `chat_ws.dart:656 if (conv != null)` 同形 | ✅ 同形（但被 #1 拖死） |
| 4 | `sortGroupsByActivity` | `aylaSortGroupsByActivity` | ✅ 探针实测正确 |
| 5 | rail 数据源 = `useSocialPage.items` + 补当前群 | `AylaGroupDirectory` 读 social | ✅ 同源 |
| 6 | 子群默认组并入列表（`social.ts:177`） | **`AylaSubgroupPage.defaultSubgroup` 已解析**（`core/models/subgroup.dart:137`），但 `group_page.dart:262–267` 建分页时**投影掉了它** | 🔴 **真缺口**（web `GroupPage.tsx:265–270` 用它确立首个 active） |
| 7 | `ensureDirectoryTracking` | 部分（`itemUpsertHooks` 只接 game） | ⚠️ 已知局限（上一轮登记） |
| 8 | **发送链带 `subgroup_id`**（`GroupChat.tsx:317/416` → `MessageInput.tsx:253/287` → `useChat.ts:427/448`） | `AylaMessageInputSubmission` **无 `subgroupId` 字段**、`_submit()` 不传、`chat_support.dart` **全文件 0 命中** | 🔴 **根因 C 的真身**（见 §7） |
| 9 | 子群排序传参顺序（`ChannelSidebar.tsx:135–137`：store 先排） | `aylaSortSubgroupsByActivity`（`subgroup_state.dart:28`）**全库零调用**；页面把**未排序**的 `subgroupsOf()` 直接喂组件 | 🔴 **缺口**（顺序靠 upsert 追尾的结构巧合） |

**修复优先级**：**#1（根因 A）** 与 **#8（根因 C）** 是两条独立的**断链**，都必须修：
- #1 断了「群列表/群头像列」的排序推进（发消息不排上去）；
- #8 断了「子群归属」（消息全落主群 ⇒ 子群排序永不推进）。

---

## 7. 🔴 根因 C 的真身：发送链丢了 `subgroup_id`（2026-10-01 wirefix-dev 更正，Lead 已复核采纳）

> ⚠️ **本节更正 Lead 先前的错误判断**：Lead 原以为 C 是「默认组没并入列表 / key 撞车 / `projectionId` 回落」——
> 经 wirefix-dev 回读原文并独立复现，**原判断作废**。真根因在上游**发送链**。

### 7.1 证据链

**web（完整）**：
```
GroupChat.tsx:317 / :416        subgroupId={activeSubgroupId}
  └─ MessageInput.tsx:253 / :287  sendOptimistic(convId, {...}, subgroupId)
       └─ useChat.ts:427          乐观：subgroup_id: subgroupId
       └─ useChat.ts:448          POST：subgroup_id: subgroupId != null ? Number(subgroupId) : undefined
```

**Flutter（断的）**：
```
widgets/chat/message_input.dart
  :106  this.subgroupId,          ← 构造参数（有）
  :135  final String? subgroupId; ← 字段声明（有）
  :401  void _submit() { ... AylaMessageInputSubmission(blocks:, picked:, replyToId:) }  ← ★从未传 subgroupId
       （且 AylaMessageInputSubmission 类本身 :79–88 就没有 subgroupId 字段）

pages/chat_support.dart          ← grep subgroupId / subgroup_id = 0 命中
```

**后端支持并校验**（所以不是后端问题）：
`apps/chat/serializers.py:587` `subgroup_id = IntegerField(required=False, allow_null=True)`；
`:643–652` 校验「子群不存在或不属于该群」。

### 7.2 后果链（正好复现用户的两条症状）

```
所有群消息 POST 都不带 subgroup_id
  ⇒ 后端落库 subgroup_id = NULL（归默认组/主群）
  ⇒ WS message.new 的 d.subgroup_id == null
  ⇒ chat_ws.dart:576 projectionId = subgroupId ?? _defaultSubgroupId(convId)
  ⇒ 未读/活跃永远记在默认组
  ⇒ message_state._recordActivity(:94) 在 seq 前的 null 判断直接 return
  ⇒ ★子群排序永不推进
```

**两条症状同源**：「群子群接线错误、接到主群去了」+「发消息排序不排上去（子群侧）」。

### 7.3 附带缺口（同源）

`MessageInput.tsx:91` 的 `draftKey = isGroup ? `${convId}:${subgroupId ?? ""}` : convId`
与 `:98` 的 `voiceScopeKey` 都把 subgroupId 编进 key ⇒ **草稿/录音按子群隔离**。
Flutter 的 `draftKey` 由**调用方传**（`message_input.dart:110`）⇒ 群聊调用点若不编入 subgroupId，**草稿会跨子群串**。

### 7.4 另两处已核实的缺口

1. `runMerging`（`social_store.dart:732` 注释提到的回环护栏）**只存在于注释**，实际不存在 ⇒ 回环护栏要真做（web `social.ts:170/181` 的 `try/finally`）；
2. `group_page.dart:262–267` 建 `AylaPagedList<AylaSubGroup>` 时把 `AylaSubgroupPage` **投影成通用游标页**，`defaultSubgroup` 被丢掉；
   web `GroupPage.tsx:265–270` 用默认组确立首个 active（后端 `views.py:238–247`：`rows` 分页**不含**默认组）⇒ 必须并入，否则默认组可能整个缺失。
