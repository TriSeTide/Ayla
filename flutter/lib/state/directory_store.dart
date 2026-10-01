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
/// ## 未实现（登记，与 web 的差异）
/// 1. **WS 增量与 mutation hints**（`createdIds` / `recentlyRemoved` / `clearMutationHints` /
///    `requestDeletions` / `cachedItems` 的 descriptor upsert，web 62–79·98–263·302–320）——
///    Flutter 侧的目录帧桥（`state/directory_events.dart` + `core/ws/room_frames.dart`）目前
///    只把帧投给页面、不进 store；接入后 `invalidated` / `mutationRevision` 才需要按 web
///    完整表达。**本轮不接**（与既有登记一致）。
/// 2. 因 1，`total` / `totalMemberCount` 的「mutation 期间保留旧值」分支退化为直接用页值
///    （无 hints 时 web 的 `effectiveResults.length - results.length` 恒为 0 ⇒ 等价）。
/// 3. `useDirectoryPage` 的 `onScroll`（距底 240px 自动 `loadMore`）在 Flutter 由各页
///    既有滚动监听表达（`extentAfter < 240`），不由本件承担。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/boardgame_api.dart';
import '../core/api/directory_page.dart';
import '../core/api/live_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../core/models/post.dart' show AylaPostVisibility;
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import '../core/net/dio_client.dart' show ApiException;
import 'directory_events.dart' show AylaDirectoryKind;

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
        final Map<String, Object> merged = <String, Object>{};
        if (mode == AylaDirectoryMode.more) {
          for (final Object item in current.items) {
            merged[_itemKey(item)] = item;
          }
        }
        for (final Object item in page.results) {
          merged[_itemKey(item)] = item;
          // web `stores/directory.ts:310–320`：取页结果逐条 upsert 回各域 store
          //（`game → useBoardgameStore.upsertRoom` 等）—— 目录页的数据同时是全局
          // store 的数据源；群活跃度/存在性角标因此不必先打开过对应页。
          itemUpsertHooks[kind]?.call(item);
        }
        _patch(
          key,
          current.copyWith(
            items: merged.values.toList(growable: false),
            nextCursor: page.nextCursor,
            clearNextCursor: page.nextCursor == null,
            hasMore: page.hasMore,
            total: page.total,
            totalMemberCount: page.totalMemberCount,
            clearTotalMemberCount: page.totalMemberCount == null,
            loading: false,
            clearError: true,
            fetchedAt: nowMillis(),
            // web 330：`more` 不动 invalidated；`initial` 按 mutationRevision 判定
            // （本轮 mutationRevision 恒 0 ⇒ initial 写 false）。
            invalidated: mode == AylaDirectoryMode.more
                ? current.invalidated
                : false,
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

  /// 登出 / 会话过期清空（web `useDirectoryStore.reset`，86）。
  void reset() {
    _pending.clear();
    _attempt += 1;
    _records.clear();
    notifyListeners();
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
  static String _itemKey(Object item) => switch (item) {
        AylaDirectoryLiveEntry(card: final AylaLiveCardData card) => card.id,
        AylaDirectoryVoiceEntry(card: final AylaVoiceCardData card) => card.id,
        AylaDirectoryGameEntry(room: final AylaGameRoom room) =>
          room.id.toString(),
        _ => item.toString(),
      };
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
