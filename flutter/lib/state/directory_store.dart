/// 目录数据共享 store —— web `stores/directory.ts`（341 行）+ `hooks/useDirectoryPage.ts`
/// （31 行）的 Flutter 等价物。
///
/// ## 为什么需要它（用户 2026-09-30 实报：「每个页面切换都要反复加载」）
/// web 的加载策略是「**登录后全局预加载核心数据 + 页面同步渲染**」（`App.tsx:11–16`）：
/// 目录数据落在**跨页共享的 store** 里，页面进入时经 [AylaDirectoryController] 读同一份
/// record；`loadDirectory` 在 `fetchedAt` 60 秒内**直接短路返回、不发请求**
/// （`stores/directory.ts:274`），因此切 tab / 切页面即秒开、不闪骨架。
/// Flutter 侧原实现只有页面私有的 `AylaPagedList`（每次进入重新取页）——
/// 该缺口曾在 `state/paged_list.dart:18–22` 登记，本次按 web 补齐。
///
/// ## 逐条对应的 web 语义
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `DirectoryRecord` 字段 | 39–56 | [AylaDirectoryRecord]（WS 增量字段见「未实现」） |
/// | `emptyRecord` | 58–61 | [AylaDirectoryRecord.empty] | 
/// | `directoryKey` | 88–92 | [aylaDirectoryKey]（user + kind + 全部选项，顺序固定） |
/// | `if (mode !== "refresh" && pending.has(key)) return pending` | 273 | [AylaDirectoryStore.load] 的 `_pending` 合并 |
/// | `mode === "initial" && fetchedAt != null && now - fetchedAt < 60_000 ⇒ resolve` | **274** | **60 秒缓存短路**（[kAylaDirectoryFreshWindowMs]） |
/// | `mode === "more" && (!hasMore \|\| invalidated \|\| !nextCursor) ⇒ resolve` | 275 | 同（追加前置条件） |
/// | `revision` 守卫（切 tab / 重载后旧响应丢弃） | 276·294 | [AylaDirectoryStore.load] 的 `record.revision != revision` |
/// | `base = { limit: 20, cursor, groupId }` | 284 | [kAylaDirectoryPageSize] |
/// | 按 kind 分发三个分页 API | 285–291 | [AylaDirectoryStore._request] |
/// | `has_more && (!next_cursor \|\| next_cursor === cursor)` ⇒ 静默降级 | 295–299 | 同（不把它当成功页） |
/// | items 合并（`more` 追加去重，否则整体替换） | 321–322 | 同（按条目主键去重） |
/// | `total` / `totalMemberCount` 落地 | 325–328 | 同（无 mutation hints ⇒ 退化为页值，见「未实现」） |
/// | `fetchedAt: Date.now()` | 329 | 同（`DateTime.now().millisecondsSinceEpoch`） |
/// | catch ⇒ `error` + `loading: false`（保留 items） | 331–334 | 同 |
/// | finally ⇒ 清 `pending` | 335–338 | 同（清 `_pending`） |
/// | `useDirectoryPage`：`items` / `loading: enabled && (!record \|\| record.loading)` / refresh / loadMore | hooks:7–31 | [AylaDirectoryController] |
///
/// ## WS 热更新（2026-10-08 按 web 补齐）
/// web 的机制是「**帧 → 域 store → 目录缓存**」，页面**不订阅 WS**：
/// `stores/directory.ts:148–196` 的 `updateCachedItems` 按 kind 把域 store 的
/// `channels` / `rooms` 数组与上一次快照做 diff，直接 patch 全部同 kind 的 record
/// ⇒ 所有从缓存渲染的页面**天然热更新**。
///
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `createdIds` / `recentlyRemoved` / `pruneCreationHints` / `clearMutationHints` | 62–80 | [AylaDirectoryStore._createdIds] 等（同名单例、同生命期） |
/// | `updateCachedItems`（changed / removed / added / complete / invalidated / total / totalMemberCount） | 148–196 | [AylaDirectoryStore.updateCachedItems] |
/// | `ensureDirectoryTracking` 的 store 订阅通路 | 205–219 | `state/room_providers.dart` 的 `aylaStartDirectoryTracking` |
/// | `chatWS.onFrame` 的 created/deleted 帧跟踪 | 220–259 | `core/ws/room_frames.dart` + [AylaDirectoryStore.noteCreated] / [AylaDirectoryStore.noteDeleted] |
/// | `requestDeletions`（REST 往返期间的删除作废） | 63·238·277–278·307 | [AylaDirectoryStore._requestDeletions] |
/// | `mergingPage`（取页 upsert 回 store 时的重入守卫） | 65·166·172·178·311–320 | [AylaDirectoryStore.mergePageItems] |
///
/// `invalidated` / `mutationRevision` 从此**有真实写入面**（不再恒 false / 恒 0）。
///
/// ## 未实现（登记，与 web 的差异）
/// 1. `useDirectoryPage` 的 `onScroll`（距底 240px 自动 `loadMore`）在 Flutter 由各页
///    既有滚动监听表达（`extentAfter < 240`），不由本件承担。
/// 2. `cachedItems(kind)` 在 web 是域 store 的**数组**；Flutter 侧的三个域 store 形态不一
///    （voice/live 是按 id 的 Map，boardgame 是列表）⇒ 由
///    [AylaDirectoryStore.cachedItemsGetter] 注入「取当前快照」的闭包，
///    本件不内建任何域分支（与 `itemUpsertHooks` 同一注入范式）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/boardgame_api.dart';
import '../core/api/directory_page.dart';
import '../core/api/live_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../core/models/post.dart' show AylaPostVisibility;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import '../core/net/dio_client.dart' show ApiException;
import 'directory_events.dart' show AylaDirectoryKind;
// ⚠️ 只借用**纯函数** `aylaSortToMs`（web `utils/sortChannels.ts:26–30` 的 `toMs` 同源）；
// 与 `hub_support.dart` 之间**无环**（hub_support 不 import state/）。
import '../pages/hub_support.dart' show aylaSortToMs;

// 目录种类 [AylaDirectoryKind] **复用** `state/directory_events.dart:24` 的既有枚举
// （与 web `DirectoryKind` / `DirectoryItems` 同集合：voice / live / game）——
// 库内纪律：既有枚举不重名新建（否则调用点 `ambiguous_import`）。

/// 取页模式（web `loadDirectory` 的第三参，`stores/directory.ts:268`）。
enum AylaDirectoryMode { initial, refresh, more }

/// 首屏缓存窗口：`fetchedAt` 在此窗口内时 `initial` 直接短路
/// （web `60_000`，`stores/directory.ts:274`）。
const int kAylaDirectoryFreshWindowMs = 60000;

/// 页大小（web `limit: 20`，`stores/directory.ts:284`）。
const int kAylaDirectoryPageSize = 20;

/// 默认时钟（毫秒）—— [AylaDirectoryStore.nowMillis] 的默认实现。
int aylaDirectoryNowMillis() => DateTime.now().millisecondsSinceEpoch;

/// 目录查询选项（web `DirectoryOptions`，`stores/directory.ts:21–38`）。
///
/// 每个选项组合对应一条独立 record（独立游标 / 独立加载）—— 即「每个分类选项卡
/// 独立 key」（web 注释 24–37）。
@immutable
class AylaDirectoryOptions {
  const AylaDirectoryOptions({
    this.groupId,
    this.onlyLive = false,
    this.filter,
    this.visibility,
    this.friends = false,
    this.occupied = false,
    this.status,
    this.owner,
    this.mine = false,
  });

  /// 群内目录（`group_id`）。
  final String? groupId;

  /// 直播「正在直播」过滤（web `onlyLive`）。
  final bool onlyLive;

  /// 分类选项卡标识（每个 tab 独立 key/游标）。
  final String? filter;

  /// 后端过滤：public / friends / group。
  final AylaPostVisibility? visibility;

  /// 只看好友发布的内容（作者是好友）。
  final bool friends;

  /// 语音「有人」（member_count > 0）。
  final bool occupied;

  /// 直播/桌游状态过滤（live/idle/ended/offline、waiting/playing/ended）。
  final String? status;

  /// 「我的」tab：后端 owner 过滤。
  final String? owner;

  /// 桌游「我在局」过滤。
  final bool mine;

  /// key 段（顺序与 web `directoryKey` 的数组逐项一致，去掉首段 user）。
  List<Object?> get keyParts => <Object?>[
        groupId,
        onlyLive,
        filter,
        visibility?.wire,
        friends,
        occupied,
        status,
        owner,
        mine,
      ];

  @override
  bool operator ==(Object other) =>
      other is AylaDirectoryOptions &&
      groupId == other.groupId &&
      onlyLive == other.onlyLive &&
      filter == other.filter &&
      visibility == other.visibility &&
      friends == other.friends &&
      occupied == other.occupied &&
      status == other.status &&
      owner == other.owner &&
      mine == other.mine;

  @override
  int get hashCode => Object.hash(groupId, onlyLive, filter, visibility, friends,
      occupied, status, owner, mine);
}

/// record key（web `directoryKey`，`stores/directory.ts:88–92`）。
///
/// web 用 `JSON.stringify([userId, kind, ...])`；Flutter 用同一顺序的 `|` 连接
/// （只需稳定且唯一，不要求与 web 逐字节相同 —— key 不跨端）。
String aylaDirectoryKey(
  AylaDirectoryKind kind,
  AylaDirectoryOptions options, {
  String? userId,
}) {
  final List<String> parts = <String>[userId ?? 'anon', kind.name];
  for (final Object? part in options.keyParts) {
    parts.add((part ?? '').toString());
  }
  return parts.join('|');
}

/// 一条目录记录（web `DirectoryRecord`，`stores/directory.ts:39–56`）。
///
/// `items` 是 `List<Object>`（web 的联合类型 `Item[]`）；Dart 的具体化泛型
/// 保证运行时元素仍是 `AylaDirectoryVoiceEntry` 等具体类型，页面经
/// [AylaDirectoryStore.itemsAs] 安全取回。
@immutable
class AylaDirectoryRecord {
  const AylaDirectoryRecord({
    required this.kind,
    required this.options,
    this.items = const <Object>[],
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
    this.totalMemberCount,
    this.loading = false,
    this.error,
    this.fetchedAt,
    this.invalidated = false,
    this.revision = 0,
    this.mutationRevision = 0,
  });

  /// 空记录（web `emptyRecord`，58–61）。
  const AylaDirectoryRecord.empty(this.kind, this.options)
      : items = const <Object>[],
        nextCursor = null,
        hasMore = false,
        total = 0,
        totalMemberCount = null,
        loading = false,
        error = null,
        fetchedAt = null,
        invalidated = false,
        revision = 0,
        mutationRevision = 0;

  final AylaDirectoryKind kind;

  /// 本条记录对应的查询选项（web 在 patch 时把 options 摊进 record）。
  final AylaDirectoryOptions options;

  final List<Object> items;
  final String? nextCursor;
  final bool hasMore;
  final int total;
  final int? totalMemberCount;
  final bool loading;
  final String? error;

  /// 最近一次成功取页的时间（毫秒；null = 从未成功）——60 秒短路的依据。
  final int? fetchedAt;

  /// 数据被并发更新（WS 增量场景；本轮恒 false，见文件头「未实现 1」）。
  final bool invalidated;

  /// 在途请求代际（web `attempt`）：旧响应按它作废。
  final int revision;

  /// mutation 代际（web `mutationRevision`；本轮恒 0，见文件头「未实现 1」）。
  final int mutationRevision;

  AylaDirectoryRecord copyWith({
    List<Object>? items,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? hasMore,
    int? total,
    int? totalMemberCount,
    bool clearTotalMemberCount = false,
    bool? loading,
    String? error,
    bool clearError = false,
    int? fetchedAt,
    bool? invalidated,
    int? revision,
    int? mutationRevision,
  }) =>
      AylaDirectoryRecord(
        kind: kind,
        options: options,
        items: items ?? this.items,
        nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
        hasMore: hasMore ?? this.hasMore,
        total: total ?? this.total,
        totalMemberCount: clearTotalMemberCount
            ? null
            : (totalMemberCount ?? this.totalMemberCount),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        fetchedAt: fetchedAt ?? this.fetchedAt,
        invalidated: invalidated ?? this.invalidated,
        revision: revision ?? this.revision,
        mutationRevision: mutationRevision ?? this.mutationRevision,
      );
}

/// 目录共享 store（web `useDirectoryStore` + `loadDirectory`，`stores/directory.ts:83–341`）。
///
/// 纯 `ChangeNotifier`（不依赖 Riverpod）—— provider 声明见
/// `state/directory_providers.dart`，与库内既有分工一致。
class AylaDirectoryStore extends ChangeNotifier {
  final Map<String, AylaDirectoryRecord> _records =
      <String, AylaDirectoryRecord>{};

  /// 在途请求（web 模块级 `pending`，62）。
  final Map<String, Future<void>> _pending = <String, Future<void>>{};

  /// 请求代际计数（web 模块级 `attempt`，64）。
  int _attempt = 0;

  /// 当前用户 id（进 key；web 读 `useAuthStore.currentUser?.id`，89）。
  String? _userId;

  /// 请求实现覆盖（**测试注入**；null ⇒ 走 [_request] 的真实 API 分发）。
  @visibleForTesting
  Future<AylaDirectoryPage<Object>> Function(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
    String? cursor,
  )? requestOverride;

  /// 条目落地点钩子（kind → upsert 单条）—— web `stores/directory.ts:310–320`
  /// 的等价物，**由 state 层注入**（本件是 kind 无关的通用件，不内建任何域的分支）。
  ///
  /// web 取页成功后把 `results` 逐条 upsert 回各域 store（`live → useLiveStore` /
  /// `voice → useVoiceStore` / `game → useBoardgameStore`，313–317 行）——
  /// 那是「目录页的数据同时是全局 store 的数据源」，群活跃度/存在性角标才能在
  /// 没打开过对应页时也有数据。
  ///
  /// Flutter 侧的对应物 = 本钩子：key = [AylaDirectoryKind]，值 = 单条落地回调。
  /// **缺席即不落**（未注册的 kind 保持既有行为，不伪造）。
  final Map<AylaDirectoryKind, void Function(Object item)> itemUpsertHooks =
      <AylaDirectoryKind, void Function(Object item)>{};

  // =================== WS 增量与 mutation hints（web stores/directory.ts 62–80 · 148–259） ===================

  /// 创建提示的存活窗口（web `stores/directory.ts:232` 的 `60_000`）。
  static const int kAylaCreatedHintTtlMs = 60000;

  /// 创建提示上限（web `:233` 的 `if (size > 256)`）。
  static const int kAylaCreatedHintMax = 256;

  /// `createdIds[kind]`（web 68）：id → 过期时刻（毫秒）。
  final Map<AylaDirectoryKind, Map<String, int>> _createdIds =
      <AylaDirectoryKind, Map<String, int>>{
    for (final AylaDirectoryKind kind in AylaDirectoryKind.values)
      kind: <String, int>{},
  };

  /// `recentlyRemoved[kind]`（web 69）：id → 被删条目的最后已知描述符。
  final Map<AylaDirectoryKind, Map<String, Object>> _recentlyRemoved =
      <AylaDirectoryKind, Map<String, Object>>{
    for (final AylaDirectoryKind kind in AylaDirectoryKind.values)
      kind: <String, Object>{},
  };

  /// `mergingPage`（web 65·166·172·178·311–320）：取页结果 upsert 回域 store 的**重入守卫**。
  ///
  /// 为 true 期间 `updateCachedItems` 不把「新增」计入任何 record —— 取页本身带来的
  /// 条目由 record 自己的落地段合并，不能算成「WS 新增」。
  bool _mergingPage = false;

  /// `requestDeletions`（web 63·238·277–278·307）：第 `revision` 次请求期间收到的删除 id。
  final Map<int, ({AylaDirectoryKind kind, Set<String> ids})> _requestDeletions =
      <int, ({AylaDirectoryKind kind, Set<String> ids})>{};

  /// `cachedItems(kind)`（web 143–146）：取该 kind 的**域 store 当前快照**（数组序）。
  ///
  /// web 是 `useLiveStore.getState().channels` 等三个直接调用（目录缓存条目就是域 store
  /// 的描述符本身）；Flutter 侧的三个域 store 形态不一（voice/live 是按 id 的 Map、
  /// boardgame 是列表）⇒ 由 `state/directory_tracking.dart` 注入取值闭包，
  /// 本件**零域知识**（与 [itemUpsertHooks] 同一范式）。缺席 ⇒ 该 kind 不参与 diff。
  final Map<AylaDirectoryKind, List<Object> Function()> cachedItemsGetter =
      <AylaDirectoryKind, List<Object> Function()>{};

  /// 域 store 描述符 → **目录条目**的投影（web 里这一步是**恒等**：
  /// `stores/directory.ts:143–146` 的目录缓存条目**就是** `useLiveStore.channels`
  /// 里的描述符本身，同一个对象）。
  ///
  /// Flutter 侧目录条目（`AylaDirectory*Entry`，卡投影 + 活动事实）与域 store 的
  /// 描述符（`Ayla*ChannelSnapshot` / `AylaGameRoom`）是两个类型 ⇒ `updateCachedItems`
  /// 的 `updated = record.items.map(item => after.get(id) ?? item)`（web :161）
  /// 必须把描述符**投影回条目**再替换，否则 record 里会混进域类型。
  ///
  /// 缺席 ⇒ 退化为恒等（web 语义；测试注入的类型即条目时也用这一档）。
  final Map<AylaDirectoryKind, Object Function(Object descriptor)>
      descriptorAdapters =
      <AylaDirectoryKind, Object Function(Object descriptor)>{};

  /// `clearMutationHints`（web 70–75）：清空两类 mutation 提示（reset / 账号切换）。
  void clearMutationHints() {
    for (final AylaDirectoryKind kind in AylaDirectoryKind.values) {
      _createdIds[kind]!.clear();
      _recentlyRemoved[kind]!.clear();
    }
  }

  /// `pruneCreationHints`（web 77–80）：惰性清理已过期的创建提示。
  void _pruneCreationHints(AylaDirectoryKind kind) {
    final int now = nowMillis();
    _createdIds[kind]!.removeWhere((String _, int expiresAt) => expiresAt <= now);
  }

  /// web `stores/directory.ts:228–234`：登记一条创建提示（`*.created` 帧）。
  ///
  /// ⚠️ 提示只用来回答「这条新增**属于哪些查询**」（ACL 数据不全 ⇒ 只认提示，
  /// 真正的归属由带权限过滤的 REST 对账确立，见 [updateCachedItems] 的 `added` 注释）。
  void noteCreated(AylaDirectoryKind kind, String id) {
    if (id.isEmpty) return;
    _pruneCreationHints(kind);
    final Map<String, int> hints = _createdIds[kind]!;
    hints[id] = nowMillis() + kAylaCreatedHintTtlMs;
    if (hints.length > kAylaCreatedHintMax) hints.remove(hints.keys.first);
  }

  /// 是否登记过该条目的创建提示（测试与调试用）。
  bool hasCreationHint(AylaDirectoryKind kind, String id) =>
      _createdIds[kind]!.containsKey(id);

  /// web `stores/directory.ts:237–258`：删除帧的**目录缓存**效应。
  ///
  /// 与 [updateCachedItems] 的区别：删除帧**先于**域 store 变化到达（store 的
  /// `removeChannel` 紧随其后），且**不需要**域 store 参与 —— 对「条目不在本页但
  /// 查询可见」的 record 也要摘掉，并 `hasMore` ⇒ 标 `invalidated`。
  void noteDeleted(AylaDirectoryKind kind, String id) {
    if (id.isEmpty) return;
    _createdIds[kind]!.remove(id);
    for (final ({AylaDirectoryKind kind, Set<String> ids}) request
        in _requestDeletions.values) {
      if (request.kind == kind) request.ids.add(id);
    }
    final Map<String, Object> removedHints = _recentlyRemoved[kind]!;
    final Object? descriptor =
        removedHints.remove(id) ?? _findItemOfKind(kind, id);
    if (_records.isEmpty) return;
    final Map<String, AylaDirectoryRecord> updated =
        <String, AylaDirectoryRecord>{};
    for (final MapEntry<String, AylaDirectoryRecord> entry in _records.entries) {
      final AylaDirectoryRecord record = entry.value;
      final Object? included = _firstWhereOrNull(
        record.items,
        (Object item) => _itemKey(item) == id,
      );
      final bool affected = record.kind == kind &&
          (included != null ||
              (record.hasMore &&
                  descriptor != null &&
                  _matchesQueryOf(record, descriptor)));
      if (!affected) {
        updated[entry.key] = record;
        continue;
      }
      final Object? removed = included ?? descriptor;
      final int? memberFloor = record.totalMemberCount;
      updated[entry.key] = record.copyWith(
        invalidated: record.invalidated || record.hasMore,
        mutationRevision: record.mutationRevision + 1,
        total: record.total > 0 ? record.total - 1 : 0,
        totalMemberCount: (kind == AylaDirectoryKind.voice && memberFloor != null)
            ? _floor(
                memberFloor -
                    (removed == null ? 0 : aylaDirectoryRowOf(removed).memberCount))
            : memberFloor,
        items: List<Object>.unmodifiable(<Object>[
          for (final Object item in record.items)
            if (_itemKey(item) != id) item,
        ]),
      );
    }
    _records
      ..clear()
      ..addAll(updated);
    notifyListeners();
  }

  /// web `updateCachedItems`（`stores/directory.ts:148–196`）—— **目录热更新的核心**。
  ///
  /// 由 store 订阅通路（`state/room_providers.dart` 的 `aylaStartDirectoryTracking`）
  /// 在 voice/live/game 三个域 store 变化时调用：把「域 store 的新旧快照」diff 成
  /// 对**全部同 kind 的 record** 的就地 patch。
  ///
  /// 逐条对应：
  /// - `changed`（156–160）：同 id 且**排序身份**变了 ⇒ 需要重排；
  /// - `updated`（161）：同 id 用**新描述符**替换（so 人数/状态/标题即时生效）；
  /// - `items` / `removed`（162–163）：过查询过滤；
  /// - `added`（166–171）：只有「创建提示」或「可见性从 false 变 true」的条目才算新增；
  /// - `complete`（173）⇒ 新增直接并入；否则 `invalidated = membershipChanged`（177）；
  /// - `total` / `totalMemberCount`（179–189）按 membership 增删校正；
  /// - `mutationRevision`（191）每次 membership 变化 +1。
  void updateCachedItems(
    AylaDirectoryKind kind,
    List<Object> next,
    List<Object> previous, {
    String? currentUserId,
  }) {
    _pruneCreationHints(kind);
    // 描述符 → 目录条目（web 里是恒等；Flutter 侧由注入的适配器完成，见 [descriptorAdapters]）。
    Object adapt(Object item) => descriptorAdapters[kind]?.call(item) ?? item;
    final Map<String, Object> before = <String, Object>{
      for (final Object item in previous) _itemKey(item): adapt(item),
    };
    final Map<String, Object> after = <String, Object>{
      for (final Object item in next) _itemKey(item): adapt(item),
    };
    _recentlyRemoved[kind] = <String, Object>{
      for (final MapEntry<String, Object> e in before.entries)
        if (!after.containsKey(e.key)) e.key: e.value,
    };
    if (_records.isNotEmpty) {
      final Map<String, AylaDirectoryRecord> updated =
          <String, AylaDirectoryRecord>{};
      for (final MapEntry<String, AylaDirectoryRecord> entry in _records.entries) {
        final AylaDirectoryRecord record = entry.value;
        if (record.kind != kind) {
          updated[entry.key] = record;
          continue;
        }
        bool changed = false;
        for (final Object item in record.items) {
          final Object? old = before[_itemKey(item)];
          final Object? current = after[_itemKey(item)];
          if (old != null &&
              current != null &&
              _sortIdentityOf(kind, old) != _sortIdentityOf(kind, current)) {
            changed = true;
            break;
          }
        }
        final List<Object> replaced = <Object>[
          for (final Object item in record.items) after[_itemKey(item)] ?? item,
        ];
        final List<Object> filtered = <Object>[
          for (final Object item in replaced)
            if (_matchesQueryOf(record, item)) item,
        ];
        final List<Object> removed = <Object>[
          for (final Object item in record.items)
            if (!filtered.any((Object c) => _itemKey(c) == _itemKey(item))) item,
        ];
        final List<Object> added = _mergingPage
            ? const <Object>[]
            : <Object>[
                for (final Object item in next)
                  if (!record.items
                          .any((Object c) => _itemKey(c) == _itemKey(item)) &&
                      _matchesQueryOf(record, item) &&
                      (_createdIds[kind]!.containsKey(_itemKey(item)) ||
                          (before[_itemKey(item)] != null &&
                              !_matchesQueryOf(record, before[_itemKey(item)]!))))
                    after[_itemKey(item)]!,
              ];
        final bool membershipChanged =
            !_mergingPage && (removed.isNotEmpty || added.isNotEmpty);
        final bool complete = record.fetchedAt != null && !record.hasMore;
        final List<Object> items = complete
            ? <Object>[...filtered, ...added]
            : filtered;
        final bool invalidated = membershipChanged && !complete;
        final List<Object> ordered = (!_mergingPage && (changed || membershipChanged))
            ? _sortItemsOf(kind, items)
            : items;
        int memberDelta = 0;
        if (kind == AylaDirectoryKind.voice && !_mergingPage) {
          for (final Object item in record.items) {
            final Object? replacement = after[_itemKey(item)];
            if (replacement == null) continue;
            memberDelta += (_matchesQueryOf(record, replacement)
                    ? aylaDirectoryRowOf(replacement).memberCount
                    : 0) -
                aylaDirectoryRowOf(item).memberCount;
          }
          for (final Object item in added) {
            memberDelta += aylaDirectoryRowOf(item).memberCount;
          }
        }
        final int addedTotal = <Object>[
          for (final Object item in added)
            if (_matchesFilterOf(record, item, currentUserId)) item,
        ].length;
        final int? memberFloor = record.totalMemberCount;
        updated[entry.key] = record.copyWith(
          items: List<Object>.unmodifiable(ordered),
          total: _floor(
              record.total + (membershipChanged ? addedTotal - removed.length : 0)),
          totalMemberCount:
              memberFloor == null ? null : _floor(memberFloor + memberDelta),
          invalidated: record.invalidated || invalidated,
          mutationRevision:
              record.mutationRevision + (membershipChanged ? 1 : 0),
        );
      }
      _records
        ..clear()
        ..addAll(updated);
      notifyListeners();
    }
    for (final String id in after.keys) {
      _createdIds[kind]!.remove(id);
    }
  }

  static int _floor(int value) => value < 0 ? 0 : value;

  /// 在**全部同 kind 的 record** 里找该 id 的条目（web 240–241 的 `flatMap(...).find(...)`）。
  Object? _findItemOfKind(AylaDirectoryKind kind, String id) {
    for (final AylaDirectoryRecord record in _records.values) {
      if (record.kind != kind) continue;
      final Object? hit = _firstWhereOrNull(
        record.items,
        (Object item) => _itemKey(item) == id,
      );
      if (hit != null) return hit;
    }
    return null;
  }

  static Object? _firstWhereOrNull(
    List<Object> items,
    bool Function(Object item) test,
  ) {
    for (final Object item in items) {
      if (test(item)) return item;
    }
    return null;
  }

  /// 当前时间（毫秒）；**测试注入**以验证 60 秒缓存窗口，默认系统时钟。
  @visibleForTesting
  int Function() nowMillis = aylaDirectoryNowMillis;

  /// 已登记的记录（调试 / 测试用）。
  Map<String, AylaDirectoryRecord> get records =>
      Map<String, AylaDirectoryRecord>.unmodifiable(_records);

  /// 当前用户 id。
  String? get userId => _userId;

  /// 设置当前用户（登录 / 会话恢复后调用；置 null ⇒ 清空并回 anon 命名空间）。
  set userId(String? value) {
    if (_userId == value) return;
    _userId = value;
    reset();
  }

  /// 读取一条记录（不存在返回 null）。
  AylaDirectoryRecord? recordOf(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
  ) =>
      _records[aylaDirectoryKey(kind, options, userId: _userId)];

  /// 读取条目并转成具体类型（web `useDirectoryPage().items`）。
  ///
  /// 类型不符时**显式抛错**（不静默丢条目）——record 的条目类型由 kind 决定。
  List<T> itemsAs<T>(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
  ) {
    final AylaDirectoryRecord? record = recordOf(kind, options);
    if (record == null) return <T>[];
    return record.items.cast<T>().toList(growable: false);
  }

  /// 页面侧的 loading 判定（web `useDirectoryPage`：
  /// `enabled && (!record || record.loading)`，`hooks/useDirectoryPage.ts:23`）。
  ///
  /// **有记录且不在请求中 ⇒ false** —— 骨架只在「从未取到过数据」时出现。
  bool isLoading(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options, {
    bool enabled = true,
  }) {
    if (!enabled) return false;
    final AylaDirectoryRecord? record = recordOf(kind, options);
    return record == null || record.loading;
  }

  /// 取页（web `loadDirectory`，264–341）—— 幂等：命中 60 秒缓存或已有在途请求时
  /// **不发请求**（切页面不重复加载的关键）。
  Future<void> load(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options, {
    AylaDirectoryMode mode = AylaDirectoryMode.initial,
    bool enabled = true,
  }) {
    if (!enabled) return Future<void>.value();
    final String key = aylaDirectoryKey(kind, options, userId: _userId);
    final AylaDirectoryRecord previous =
        _records[key] ?? AylaDirectoryRecord.empty(kind, options);

    // web 273：refresh 之外，同一 key 的在途请求直接复用（请求合并）。
    if (mode != AylaDirectoryMode.refresh) {
      final Future<void>? inflight = _pending[key];
      if (inflight != null) return inflight;
    }
    // web 274：60 秒内首屏短路 —— **切页面不重复加载的关键**。
    final int now = nowMillis();
    if (mode == AylaDirectoryMode.initial &&
        previous.fetchedAt != null &&
        now - previous.fetchedAt! < kAylaDirectoryFreshWindowMs) {
      return Future<void>.value();
    }
    // web 275：追加前置条件（无下一页 / 已失效 / 无游标 ⇒ 不请求）。
    if (mode == AylaDirectoryMode.more &&
        (!previous.hasMore ||
            previous.invalidated ||
            previous.nextCursor == null)) {
      return Future<void>.value();
    }

    final int revision = ++_attempt;
    // web 277–278：登记本次请求的删除集合（REST 往返期间收到的删除帧要作废对应结果）。
    final Set<String> deletedDuringRequest = <String>{};
    _requestDeletions[revision] = (kind: kind, ids: deletedDuringRequest);
    // web 279：请求开始时的域 store 快照（回来后据此判定「描述符是否更新过」）。
    final Map<String, Object> descriptorsAtStart = <String, Object>{
      for (final Object item in cachedItemsGetter[kind]?.call() ?? const <Object>[])
        itemKeyOf(item): item,
    };
    final String? cursor =
        mode == AylaDirectoryMode.more ? previous.nextCursor : null;
    _patch(
      key,
      previous.copyWith(
        loading: true,
        clearError: true,
        revision: revision,
      ),
    );

    late final Future<void> task;
    final Future<AylaDirectoryPage<Object>> Function(
      AylaDirectoryKind,
      AylaDirectoryOptions,
      String?,
    ) send = requestOverride ?? _request;
    task = send(kind, options, cursor).then(
      (AylaDirectoryPage<Object> page) {
        final AylaDirectoryRecord? current = _records[key];
        // web 294：代际守卫（切 tab / 重载后旧响应一律丢弃）。
        if (current == null || current.revision != revision) return;
        // web 295–299：游标无效 ⇒ 静默降级（停止 loading，不当作成功页）。
        if (page.hasMore &&
            (page.nextCursor == null || page.nextCursor == cursor)) {
          _patch(key, current.copyWith(loading: false));
          return;
        }
        // web 302–306：**store 里的最新描述符**胜过本页快照 —— 请求开始之后到达的
        // 任意新对象都比这一页更新（含追加页里的重复 id）。
        final Map<String, Object> latestDescriptors = <String, Object>{
          for (final Object item
              in cachedItemsGetter[kind]?.call() ?? const <Object>[])
            itemKeyOf(item): item,
        };
        final List<Object> effectiveResults = <Object>[
          for (final Object item in page.results)
            _effectiveResult(
              item,
              latestDescriptors[itemKeyOf(item)],
              descriptorsAtStart[itemKeyOf(item)],
            ),
        ];
        // web 307：请求期间被删的、以及不满足本 record 查询条件的条目**不入列**。
        final List<Object> results = <Object>[
          for (final Object item in effectiveResults)
            if (!deletedDuringRequest.contains(itemKeyOf(item)) &&
                _matchesQueryOf(current, item))
              item,
        ];
        // web 308–309：被丢弃的语音房人数要从 total_member_count 里扣掉。
        int discardedMembers = 0;
        if (kind == AylaDirectoryKind.voice) {
          for (final Object item in effectiveResults) {
            if (results.any((Object kept) => identical(kept, item))) continue;
            discardedMembers += aylaDirectoryRowOf(item).memberCount;
          }
        }
        // web 311–320：取页结果逐条 upsert 回各域 store（`game → useBoardgameStore`
        // 等）—— 目录页的数据同时是全局 store 的数据源；群活跃度/存在性角标因此
        // 不必先打开过对应页。`_mergingPage` 期间 `updateCachedItems` 不把这次
        // upsert 算成「WS 新增」（web 的 `mergingPage` 同义，:166/:172/:178）。
        _mergingPage = true;
        try {
          for (final Object item in results) {
            itemUpsertHooks[kind]?.call(item);
          }
        } finally {
          _mergingPage = false;
        }
        final Map<String, Object> merged = <String, Object>{};
        if (mode == AylaDirectoryMode.more) {
          for (final Object item in current.items) {
            merged[_itemKey(item)] = item;
          }
        }
        for (final Object item in results) {
          merged[_itemKey(item)] = item;
        }
        // web 325–330：mutation 期间「保留 mutation 后的统计」，否则用页值扣掉被丢弃项。
        final bool mutated =
            current.mutationRevision != previous.mutationRevision;
        final int pageTotal = page.total - (effectiveResults.length - results.length);
        final int? pageMembers = page.totalMemberCount == null
            ? null
            : page.totalMemberCount! - discardedMembers;
        _patch(
          key,
          current.copyWith(
            items: merged.values.toList(growable: false),
            nextCursor: page.nextCursor,
            clearNextCursor: page.nextCursor == null,
            hasMore: page.hasMore,
            total: previous.fetchedAt != null && mutated
                ? current.total
                : _floor(pageTotal),
            totalMemberCount: current.totalMemberCount != previous.totalMemberCount
                ? current.totalMemberCount
                : (pageMembers == null ? null : _floor(pageMembers)),
            clearTotalMemberCount: !(current.totalMemberCount !=
                    previous.totalMemberCount) &&
                pageMembers == null,
            loading: false,
            clearError: true,
            fetchedAt: nowMillis(),
            // web 330：`more` 不动 invalidated；`initial`/`refresh` 看本页期间是否
            // 发生过 membership 变化（若发生过，页脚据此给「刷新」入口）。
            invalidated: mode == AylaDirectoryMode.more
                ? current.invalidated
                : mutated,
          ),
        );
      },
    ).catchError((Object error) {
      final AylaDirectoryRecord? current = _records[key];
      if (current != null && current.revision == revision) {
        _patch(
          key,
          current.copyWith(
            loading: false,
            error: error is ApiException ? error.message : '加载列表失败',
          ),
        );
      }
    }).whenComplete(() {
      _requestDeletions.remove(revision); // web 336
      if (_pending[key] == task) _pending.remove(key);
    });

    _pending[key] = task;
    return task;
  }

  /// 重取首页（web `refresh`）：**绕过 60 秒缓存**与在途合并。
  Future<void> refresh(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
  ) =>
      load(kind, options, mode: AylaDirectoryMode.refresh);

  /// 追加下一页（web `loadMore`）。
  Future<void> loadMore(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
  ) =>
      load(kind, options, mode: AylaDirectoryMode.more);

  /// 本地替换条目（保留给页面做乐观更新；total 按条目数增减同步）。
  void setItems(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
    List<Object> items,
  ) {
    final String key = aylaDirectoryKey(kind, options, userId: _userId);
    final AylaDirectoryRecord? current = _records[key];
    if (current == null) return;
    final int total = current.total + items.length - current.items.length;
    _patch(
      key,
      current.copyWith(
        items: List<Object>.unmodifiable(items),
        total: total < 0 ? 0 : total,
      ),
    );
  }

  /// 登出 / 会话过期清空（web `useDirectoryStore.reset`，86）——
  /// 同时清在途登记与两类 mutation 提示（web 86 的 `pending.clear()` /
  /// `requestDeletions.clear()` / `clearMutationHints()` 三件）。
  void reset() {
    _pending.clear();
    _requestDeletions.clear();
    clearMutationHints();
    _attempt += 1;
    _records.clear();
    notifyListeners();
  }

  /// web 302–306 的单条替换：store 里出现了比本页快照更新的同 id 描述符 ⇒ 用它。
  static Object _effectiveResult(Object item, Object? latest, Object? atStart) {
    if (latest == null) return item;
    return identical(latest, atStart) ? item : latest;
  }

  /// web `sortIdentity`（`stores/directory.ts:98–108`）：排序**身份** —— 只有它变了
  /// 才需要重排（人数之外的字段变化不触发排序）。
  static String _sortIdentityOf(AylaDirectoryKind kind, Object item) {
    final AylaDirectoryRow row = aylaDirectoryRowOf(item);
    switch (kind) {
      case AylaDirectoryKind.live:
        return '${row.status}\u0000${row.startedAt}\u0000${row.endedAt}';
      case AylaDirectoryKind.voice:
        return '${row.memberCount > 0}\u0000${row.lastOccupiedAt}\u0000'
            '${row.lastVacantAt}';
      case AylaDirectoryKind.game:
        return row.createdAt ?? '';
    }
  }

  /// web `matchesQuery`（`stores/directory.ts:110–113`）：`groupId` 白名单 + `onlyLive`。
  static bool _matchesQueryOf(AylaDirectoryRecord record, Object item) {
    final AylaDirectoryRow row = aylaDirectoryRowOf(item);
    final String? groupId = record.options.groupId;
    if (groupId != null &&
        !row.allowedGroupIds.any((String id) => id == groupId)) {
      return false;
    }
    if (record.options.onlyLive && row.status != 'live') return false;
    return true;
  }

  /// web `matchesFilter`（`stores/directory.ts:121–135`）：分类 tab 维度。
  ///
  /// ⚠️ **只用于 total 调整，不参与 items 过滤**（web 115–120 的原话：WS 新增事件的
  /// 描述符可能带不完整字段，据它过滤 items 有丢数据风险）。好友 tab 需要好友列表，
  /// store 无此数据 ⇒ 放行（页面层过滤兜底）。
  static bool _matchesFilterOf(
    AylaDirectoryRecord record,
    Object item,
    String? currentUserId,
  ) {
    final String? filter = record.options.filter;
    if (filter == null || filter == 'all' || filter == 'friends') return true;
    final AylaDirectoryRow row = aylaDirectoryRowOf(item);
    switch (filter) {
      case 'public':
        return row.visibility == 'public';
      case 'mine':
        return row.isOwner ||
            (currentUserId != null && row.ownerId == currentUserId);
      case 'occupied':
        return row.memberCount > 0;
      case 'live':
        return row.status == 'live';
      case 'offline':
        return row.status != 'live';
      case 'waiting':
        return row.status == 'waiting';
      case 'playing':
        return row.status == 'playing';
      default:
        return true;
    }
  }

  /// web `sortItems`（`stores/directory.ts:137–141`）。
  static List<Object> _sortItemsOf(AylaDirectoryKind kind, List<Object> items) {
    final List<Object> sorted = List<Object>.of(items);
    final Map<Object, int> order = <Object, int>{
      for (int i = 0; i < sorted.length; i++) sorted[i]: i,
    };
    // ⚠️ Dart 的 `List.sort` **不稳定**（web 的 `Array.sort` 稳定）⇒ 显式带原索引
    // 做末位比较，否则并列项顺序漂移（库内既有先例：`sortSubgroupsByActivity`）。
    sorted.sort((Object a, Object b) {
      final int byKind = _compareByIdentity(kind, a, b);
      if (byKind != 0) return byKind;
      return (order[a] ?? 0) - (order[b] ?? 0);
    });
    return sorted;
  }

  static int _compareByIdentity(AylaDirectoryKind kind, Object a, Object b) {
    final AylaDirectoryRow ra = aylaDirectoryRowOf(a);
    final AylaDirectoryRow rb = aylaDirectoryRowOf(b);
    switch (kind) {
      case AylaDirectoryKind.live:
        return _compareLive(ra, rb);
      case AylaDirectoryKind.voice:
        return _compareVoice(ra, rb);
      case AylaDirectoryKind.game:
        final String ac = ra.createdAt ?? '';
        final String bc = rb.createdAt ?? '';
        final int byTime = bc.compareTo(ac); // created_at 降序
        if (byTime != 0) return byTime;
        final int ai = int.tryParse(ra.id) ?? 0;
        final int bi = int.tryParse(rb.id) ?? 0;
        return bi - ai; // 同时间按 id 降序（web 140 的 `Number(b.id) - Number(a.id)`）
    }
  }

  /// web `utils/sortChannels.ts:48–61` 的 `sortLiveChannels`（在播 → 曾播 → 从未）。
  static int _compareLive(AylaDirectoryRow a, AylaDirectoryRow b) {
    final bool aLive = a.status == 'live';
    final bool bLive = b.status == 'live';
    if (aLive != bLive) return aLive ? -1 : 1;
    if (aLive) return (b.startedAt ?? '').compareTo(a.startedAt ?? '');
    final bool everA = a.startedAt != null;
    final bool everB = b.startedAt != null;
    if (everA != everB) return everA ? -1 : 1;
    if (everA) return (b.endedAt ?? '').compareTo(a.endedAt ?? '');
    return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
  }

  /// web `utils/sortChannels.ts:32–46` 的 `sortVoiceChannels`（有人区 → 曾有人 → 从未）。
  static int _compareVoice(AylaDirectoryRow a, AylaDirectoryRow b) {
    final bool aOccupied = a.memberCount > 0;
    final bool bOccupied = b.memberCount > 0;
    if (aOccupied != bOccupied) return aOccupied ? -1 : 1;
    if (aOccupied) {
      return aylaSortToMs(b.lastOccupiedAt) - aylaSortToMs(a.lastOccupiedAt);
    }
    final bool everA = a.lastOccupiedAt != null || a.lastVacantAt != null;
    final bool everB = b.lastOccupiedAt != null || b.lastVacantAt != null;
    if (everA != everB) return everA ? -1 : 1;
    if (everA) {
      return aylaSortToMs(b.lastVacantAt) - aylaSortToMs(a.lastVacantAt);
    }
    return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
  }

  void _patch(String key, AylaDirectoryRecord record) {
    _records[key] = record;
    notifyListeners();
  }

  /// 按 kind 分发三个分页 API（web 285–291；分类过滤参数由后端执行）。
  Future<AylaDirectoryPage<Object>> _request(
    AylaDirectoryKind kind,
    AylaDirectoryOptions options,
    String? cursor,
  ) async {
    switch (kind) {
      case AylaDirectoryKind.live:
        final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
            await AylaLiveApi.listLiveChannelsPage(
          limit: kAylaDirectoryPageSize,
          cursor: cursor,
          groupId: options.groupId,
          owner: options.owner,
          friends: options.friends,
          visibility: options.visibility,
          status: options.status,
          onlyLive: options.onlyLive,
        );
        return _widen<AylaDirectoryLiveEntry>(page);
      case AylaDirectoryKind.voice:
        final AylaDirectoryPage<AylaDirectoryVoiceEntry> page =
            await AylaVoiceApi.listVoiceChannelsPage(
          limit: kAylaDirectoryPageSize,
          cursor: cursor,
          groupId: options.groupId,
          owner: options.owner,
          friends: options.friends,
          occupied: options.occupied,
          visibility: options.visibility,
        );
        return _widen<AylaDirectoryVoiceEntry>(page);
      case AylaDirectoryKind.game:
        final AylaDirectoryPage<AylaDirectoryGameEntry> page =
            await AylaBoardgameApi.listGameRoomsPage(
          limit: kAylaDirectoryPageSize,
          cursor: cursor,
          groupId: options.groupId,
          owner: options.owner,
          friends: options.friends,
          mine: options.mine,
          visibility: options.visibility,
          status: options.status,
        );
        return _widen<AylaDirectoryGameEntry>(page);
    }
  }

  static AylaDirectoryPage<Object> _widen<T extends Object>(
    AylaDirectoryPage<T> page,
  ) =>
      AylaDirectoryPage<Object>(
        results: List<Object>.of(page.results),
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        total: page.total,
        totalMemberCount: page.totalMemberCount,
      );

  /// 条目主键（web 一律 `String(item.id)`；三个 descriptor 都有 `id`）。
  ///
  /// public：帧桥 / 域 store 订阅通路 / 测试都要用它做「同一条目」的判据，
  /// 口径必须唯一（不要在各处各写一遍 switch）。
  static String itemKeyOf(Object item) => switch (item) {
        AylaDirectoryLiveEntry(card: final AylaLiveCardData card) => card.id,
        AylaDirectoryVoiceEntry(card: final AylaVoiceCardData card) => card.id,
        AylaDirectoryGameEntry(room: final AylaGameRoom room) =>
          room.id.toString(),
        AylaVoiceChannelSnapshot(:final String id) => id,
        AylaLiveChannelSnapshot(:final String id) => id,
        AylaGameRoom(:final int id) => id.toString(),
        _ => item.toString(),
      };

  static String _itemKey(Object item) => itemKeyOf(item);
}

// =================== descriptor 适配（web 的 Item 是对象字面量，Dart 侧是多形态类型） ===================

/// 目录条目的**排序/过滤投影**（web 的 `Item` 是 TypeScript 交叉类型，字段直接可读；
/// Dart 侧的条目/快照/房间都是各自独立的类 ⇒ 用本适配器统一取列）。
///
/// 对应 web `stores/directory.ts` 的四处取列：
/// - `sortIdentity`（98–108）：live = [status, started_at, ended_at]、voice =
///   [member_count > 0, last_occupied_at, last_vacant_at]、game = created_at；
/// - `cachedItems`（143–146）+ `sortItems`（137–141）：按 kind 走三个排序；
/// - `matchesQuery`（110–113）：`groupId` / `onlyLive` 两个查询过滤；
/// - `matchesFilter`（121–135）：分类 tab 维度（**只用于 total 调整**）。
@immutable
class AylaDirectoryRow {
  const AylaDirectoryRow({
    required this.id,
    this.memberCount = 0,
    this.isOwner = false,
    this.ownerId = '',
    this.allowedGroupIds = const <String>[],
    this.status,
    this.visibility,
    this.createdAt,
    this.lastOccupiedAt,
    this.lastVacantAt,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final int memberCount;
  final bool isOwner;
  final String ownerId;
  final List<String> allowedGroupIds;
  final String? status;
  final String? visibility;
  final String? createdAt;
  final String? lastOccupiedAt;
  final String? lastVacantAt;
  final String? startedAt;
  final String? endedAt;
}

/// 条目 / 域快照 / 房间 → [AylaDirectoryRow]（**缺席即缺席**，不造默认值；
/// 只有「无」才有默认：无白名单就是空列表）。
AylaDirectoryRow aylaDirectoryRowOf(Object item) {
  switch (item) {
    case AylaDirectoryVoiceEntry entry:
      return AylaDirectoryRow(
        id: entry.card.id,
        memberCount: entry.card.memberCount ?? 0,
        isOwner: entry.isOwner,
        ownerId: entry.ownerId,
        allowedGroupIds: entry.allowedGroupIds,
        visibility: entry.card.visibility?.wire,
        createdAt: entry.createdAt,
        lastOccupiedAt: entry.lastOccupiedAt,
        lastVacantAt: entry.lastVacantAt,
      );
    case AylaVoiceChannelSnapshot channel:
      return AylaDirectoryRow(
        id: channel.id,
        memberCount: channel.memberCount ?? 0,
        isOwner: channel.mine,
        ownerId: channel.ownerId,
        allowedGroupIds: channel.allowedGroupIds,
        visibility: channel.visibility?.wire,
        createdAt: channel.createdAt,
        lastOccupiedAt: channel.lastOccupiedAt,
        lastVacantAt: channel.lastVacantAt,
      );
    case AylaDirectoryLiveEntry entry:
      return AylaDirectoryRow(
        id: entry.card.id,
        memberCount: entry.card.viewerCount ?? 0,
        isOwner: entry.isOwner,
        ownerId: entry.ownerId,
        allowedGroupIds: entry.allowedGroupIds,
        status: entry.card.status?.name,
        visibility: entry.card.visibility?.wire,
        createdAt: entry.createdAt,
        startedAt: entry.startedAt,
        endedAt: entry.endedAt,
      );
    case AylaLiveChannelSnapshot channel:
      return AylaDirectoryRow(
        id: channel.id,
        memberCount: channel.viewerCount ?? 0,
        isOwner: channel.isOwner,
        ownerId: channel.ownerId,
        allowedGroupIds: channel.allowedGroupIds,
        status: channel.status?.name,
        visibility: channel.visibility,
        createdAt: channel.createdAt,
        startedAt: channel.startedAt,
        endedAt: channel.endedAt,
      );
    case AylaDirectoryGameEntry entry:
      return aylaDirectoryRowOf(entry.room);
    case AylaGameRoom room:
      return AylaDirectoryRow(
        id: room.id.toString(),
        memberCount: room.memberCount,
        isOwner: room.isOwner,
        ownerId: room.ownerId,
        allowedGroupIds: room.allowedGroupIds,
        status: room.status?.wire,
        visibility: room.visibility?.wire,
        createdAt: room.createdAt,
      );
    default:
      return AylaDirectoryRow(id: AylaDirectoryStore.itemKeyOf(item));
  }
}

/// 页面侧适配器 —— web `useDirectoryPage`（`hooks/useDirectoryPage.ts:7–31`）。
///
/// 对外暴露与 `AylaPagedList` 相同的读取面（items/loading/error/total/hasMore/
/// loaded/refresh/loadMore），但**数据归 store 所有**：本类只按 key 转发，
/// 多个页面 / 多个 controller 共享同一条 record ⇒ 页面切换不重复请求、不闪骨架。
class AylaDirectoryController<T> extends ChangeNotifier {
  AylaDirectoryController({
    required this.store,
    required this.kind,
    required this.options,
    this.enabled = true,
  }) {
    store.addListener(_onStoreChanged);
  }

  final AylaDirectoryStore store;
  final AylaDirectoryKind kind;
  final AylaDirectoryOptions options;

  /// web `useDirectoryPage(kind, options, enabled)`（enabled=false ⇒ 不取页）。
  final bool enabled;

  bool _disposed = false;

  void _onStoreChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 进入页面时调用（web `useEffect` 里的 `loadDirectory`）——幂等。
  Future<void> load() => store.load(kind, options, enabled: enabled);

  Future<void> refresh() => store.refresh(kind, options);

  Future<void> loadMore() => store.loadMore(kind, options);

  List<T> get items => store.itemsAs<T>(kind, options);

  /// 本地替换条目（web `updateSocialItems` 语义；转发 [AylaDirectoryStore.setItems]，
  /// 只动已加载投影，不改变游标与 `hasMore`）。
  void setItems(List<T> next) =>
      store.setItems(kind, options, next.cast<Object>().toList(growable: false));

  /// 按判据移除条目（[setItems] 的常用包装）。
  void removeWhere(bool Function(T item) test) =>
      setItems(<T>[
        for (final T item in items)
          if (!test(item)) item,
      ]);

  bool get loading => store.isLoading(kind, options, enabled: enabled);

  /// 是否已成功取到过至少一页（决定首屏骨架 vs 空态）。
  bool get loaded => (store.recordOf(kind, options)?.fetchedAt ?? 0) > 0;

  bool get hasMore => store.recordOf(kind, options)?.hasMore ?? false;

  bool get invalidated => store.recordOf(kind, options)?.invalidated ?? false;

  String? get error => store.recordOf(kind, options)?.error;

  int get total => store.recordOf(kind, options)?.total ?? 0;

  int? get totalMemberCount => store.recordOf(kind, options)?.totalMemberCount;

  String? get nextCursor => store.recordOf(kind, options)?.nextCursor;

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_onStoreChanged);
    super.dispose();
  }
}

/// 模块级单例 —— web `useDirectoryStore`（`stores/directory.ts:83`）的模块级 store 语义：
/// `appInit` 预加载与所有页面共用同一实例。
///
/// ⚠️ **不包 `ChangeNotifierProvider`**（2026-09-30 实测）：Riverpod 会把 store 的通知
/// 转成 provider 的 setState，而页面在 `initState` 里 `load()` 时 store 会**同步**发一次
/// `loading: true` 通知 ⇒ 触发 Riverpod 的「Tried to modify a provider while the widget
/// tree was building」断言（zustand 无此限制）。页面直接持有本单例即可 ——
/// 语义与 web 的模块级 store 一致，也让 controller 的 `setState` 路径保持
/// `AylaPagedList` 原有的合法形态（详见本文件 [AylaDirectoryController]）。
final AylaDirectoryStore aylaDirectoryStore = AylaDirectoryStore();
