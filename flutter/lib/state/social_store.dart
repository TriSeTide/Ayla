/// 社交共享 store —— web `stores/social.ts`（195 行）的 Flutter 等价物。
///
/// ## 为什么需要它（主页骨架的真因，用户实报「主页也没有单独的加载动画」）
/// web 的 `loadSocial` 与 `loadDirectory` 同构：pending 合并（`:149`）+ **60 秒首屏短路**
/// （`:150`）+ 未登录直返（`:148`），并且 `appInit.ts:35·40` 登录后预取
/// `conversations{group}` / `conversations{private}`。主页读 `useSocialPage("conversations",
/// { type: "group" })` ⇒ 命中预取 record ⇒ `loading` 为 false（`useDirectoryPage` 同款
/// 语义：`enabled && (!record || record.loading)`）⇒ **主页不显示自己的骨架**。
/// Flutter 侧原实现是页面私有的 `AylaPagedList` ⇒ 每次进入重新请求、闪骨架。
///
/// ## 逐条对应的 web 语义（`stores/social.ts`）
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `SocialItems` 九种 kind | 11–21 | [AylaSocialKind]（**首批实现 conversations / friends**，其余登记） |
/// | `SocialOptions { groupId, q, type, excludeSelf }` | 24 | [AylaSocialOptions] |
/// | `SocialRecord` 字段 | 25–37 | [AylaSocialRecord] |
/// | `socialKey`（user + kind + groupId + q + type + excludeSelf） | 48–51 | [aylaSocialKey] |
/// | `itemId`（`id` 或好友行的 `user.id`） | 52–54 | [AylaSocialStore.itemKey] |
/// | `empty()` | 58–61 | [AylaSocialRecord.empty] |
/// | `loadSocial`：未登录直返 | 148 | 同 |
/// | 在途合并 | 149 | 同 |
/// | **60 秒首屏短路** | **150** | 同（[kAylaSocialFreshWindowMs]） |
/// | `more` 前置（`!hasMore \|\| !nextCursor`） | 151 | 同 |
/// | revision 守卫 | 152·159 | 同 |
/// | 响应有效性（`results` 非数组 / `total` 非有限 / 游标未推进 ⇒ **抛错**） | 160–161 | 同（写 `error`，与 directory 的静默降级**不同**，逐条照抄） |
/// | items 合并（`more` 保留；否则剔除已消失项 + 覆盖新结果） | 163–169 | 同 |
/// | `fetchedAt: Date.now()` | 187 | 同 |
/// | catch ⇒ `error` + `loading: false` | 188–191 | 同 |
/// | 页大小 `limit: 30` | 129 | [kAylaSocialPageSize] |
///
/// ## 未实现（登记）
/// 1. **七种 kind 的 `requestPage`**（members / subgroups / users / friendRequests / invites /
///    joinRequests / leaveNotices，web `:132–139`）：Flutter 侧对应 API 已存在
///    （`chat_api.listConversationMembersPage` / `listSubgroupsPage` / `listMyInvitesPage` /
///    `listJoinRequestsPage` / `listLeaveNoticesPage`、`users_api.searchUsersPage` /
///    `listFriendRequestsPage`），但消费页（消息中心 / 群页 / 群详情）尚未改造 ⇒ 未接线的
///    kind 调用时**显式抛 `UnsupportedError`**（不静默返回空列表）。
/// 2. **WS 增量与 tombstone**（`reconcileCached` / `updateSocialItems` 的 `deleted` 集合，
///    web 73–126·154·163）—— 与 `state/directory_events.dart` 同口径：帧仍走事件总线，
///    接入时按 web 补齐；`mutationRevision` 字段已预留。
/// 3. **`subgroups` 的默认子群排序**（web 182–184）—— 随 kind 接线一并落地。
library;

import 'package:flutter/foundation.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart';
import '../core/api/users_api.dart';
import '../core/models/conversation.dart' show AylaConversationSummary;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/net/dio_client.dart' show ApiException;

/// 社交条目种类（web `SocialItems` 的九个 key，`stores/social.ts:11–21`）。
enum AylaSocialKind {
  conversations,
  members,
  subgroups,
  users,
  friends,
  friendRequests,
  invites,
  joinRequests,
  leaveNotices,
}

/// 取页模式（与 `AylaDirectoryMode` 同语义）。
enum AylaSocialMode { initial, refresh, more }

/// 首屏缓存窗口（web `60_000`，`stores/social.ts:150`）。
const int kAylaSocialFreshWindowMs = 60000;

/// 页大小（web `limit: 30`，`stores/social.ts:129`）。
const int kAylaSocialPageSize = 30;

/// 社交查询选项（web `SocialOptions`，`stores/social.ts:24`）。
@immutable
class AylaSocialOptions {
  const AylaSocialOptions({
    this.groupId,
    this.q,
    this.type,
    this.excludeSelf = false,
  });

  /// 会话 / 子群 / 成员所属会话 id。
  final String? groupId;

  /// 搜索词（会话按 title/昵称/用户名前端匹配，web `:65–68`）。
  final String? q;

  /// 会话类型过滤（`all` / `group` / `private`）。
  final String? type;

  /// 成员列表排除自己。
  final bool excludeSelf;

  @override
  bool operator ==(Object other) =>
      other is AylaSocialOptions &&
      groupId == other.groupId &&
      q == other.q &&
      type == other.type &&
      excludeSelf == other.excludeSelf;

  @override
  int get hashCode => Object.hash(groupId, q, type, excludeSelf);
}

/// record key（web `socialKey`，`stores/social.ts:48–51`）。
String aylaSocialKey(
  AylaSocialKind kind,
  AylaSocialOptions options, {
  String? userId,
}) =>
    <String>[
      userId ?? 'anon',
      kind.name,
      options.groupId ?? '',
      (options.q ?? '').trim(),
      options.type ?? 'all',
      options.excludeSelf ? '1' : '0',
    ].join('|');

/// 一条社交记录（web `SocialRecord`，`stores/social.ts:25–37`）。
@immutable
class AylaSocialRecord {
  const AylaSocialRecord({
    required this.kind,
    required this.options,
    this.items = const <Object>[],
    this.total = 0,
    this.nextCursor,
    this.hasMore = false,
    this.loading = false,
    this.error,
    this.fetchedAt,
    this.revision = 0,
    this.mutationRevision = 0,
  });

  const AylaSocialRecord.empty(this.kind, this.options)
      : items = const <Object>[],
        total = 0,
        nextCursor = null,
        hasMore = false,
        loading = false,
        error = null,
        fetchedAt = null,
        revision = 0,
        mutationRevision = 0;

  final AylaSocialKind kind;
  final AylaSocialOptions options;
  final List<Object> items;
  final int total;
  final String? nextCursor;
  final bool hasMore;
  final bool loading;
  final String? error;
  final int? fetchedAt;
  final int revision;
  final int mutationRevision;

  AylaSocialRecord copyWith({
    List<Object>? items,
    int? total,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? hasMore,
    bool? loading,
    String? error,
    bool clearError = false,
    int? fetchedAt,
    int? revision,
    int? mutationRevision,
  }) =>
      AylaSocialRecord(
        kind: kind,
        options: options,
        items: items ?? this.items,
        total: total ?? this.total,
        nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
        hasMore: hasMore ?? this.hasMore,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        fetchedAt: fetchedAt ?? this.fetchedAt,
        revision: revision ?? this.revision,
        mutationRevision: mutationRevision ?? this.mutationRevision,
      );
}

/// 社交共享 store（web `useSocialStore` + `loadSocial`，`stores/social.ts:44–195`）。
///
/// 纯 `ChangeNotifier` + 模块级单例（与 `AylaDirectoryStore` 同口径：
/// **不包 Riverpod**，理由见 `state/directory_store.dart` 的单例注释）。
class AylaSocialStore extends ChangeNotifier {
  final Map<String, AylaSocialRecord> _records = <String, AylaSocialRecord>{};

  /// 在途请求（web `pending`，38）。
  final Map<String, Future<void>> _pending = <String, Future<void>>{};

  /// 请求代际（web `attempt`，39）。
  int _attempt = 0;

  String? _userId;

  /// 取页实现覆盖（依赖注入点；生产恒为 null ⇒ 走真实 API 分发）。
  Future<AylaDirectoryPage<Object>> Function(
    AylaSocialKind kind,
    AylaSocialOptions options,
    String? cursor,
  )? requestOverride;

  /// 已登记的记录（调试 / 测试用）。
  Map<String, AylaSocialRecord> get records =>
      Map<String, AylaSocialRecord>.unmodifiable(_records);

  String? get userId => _userId;

  /// 设置当前用户（登录 / 会话恢复后调用；变化 ⇒ 清空旧用户数据）。
  set userId(String? value) {
    if (_userId == value) return;
    _userId = value;
    reset();
  }

  AylaSocialRecord? recordOf(AylaSocialKind kind, AylaSocialOptions options) =>
      _records[aylaSocialKey(kind, options, userId: _userId)];

  /// 读取条目并转成具体类型（web `useSocialPage().items`）。
  List<T> itemsAs<T>(AylaSocialKind kind, AylaSocialOptions options) {
    final AylaSocialRecord? record = recordOf(kind, options);
    if (record == null) return <T>[];
    return record.items.cast<T>().toList(growable: false);
  }

  /// 页面 loading 判定（web `hooks/useSocialPage.ts:23`：`enabled && (!record || record.loading)`）。
  ///
  /// ⚠️ **未登录（无 userId）恒 false**：web 侧这些页面由 `ProtectedRoute` 保证不渲染
  /// （无 token 直接 `<Navigate to="/login">`），因此「`loadSocial` 直返 ⇒ 无 record ⇒
  /// loading 恒 true」这一状态在 web 不会出现；Flutter 侧若照字面表达，会让页面**永远转圈**
  /// （实测：`pumpAndSettle timed out`，且 401 后 userId 刚清空、页面尚未退场的窗口同样会卡）。
  /// ⇒ 未登录时视为「不 loading」（走空态分支），与 web 的实际渲染结果一致。
  bool isLoading(
    AylaSocialKind kind,
    AylaSocialOptions options, {
    bool enabled = true,
  }) {
    if (!enabled) return false;
    if (_userId == null) return false;
    final AylaSocialRecord? record = recordOf(kind, options);
    return record == null || record.loading;
  }

  /// 取页（web `loadSocial`，144–195）—— 命中 60 秒缓存或已有在途请求时不发请求。
  Future<void> load(
    AylaSocialKind kind,
    AylaSocialOptions options, {
    AylaSocialMode mode = AylaSocialMode.initial,
    bool enabled = true,
  }) {
    if (!enabled) return Future<void>.value();
    // web 148：未登录不发请求（key 的 user 段此时是 anon，缓存不可用）。
    if (_userId == null) return Future<void>.value();
    final String key = aylaSocialKey(kind, options, userId: _userId);
    final AylaSocialRecord previous =
        _records[key] ?? AylaSocialRecord.empty(kind, options);
    // web 149：refresh 之外，同 key 在途请求合并。
    if (mode != AylaSocialMode.refresh) {
      final Future<void>? inflight = _pending[key];
      if (inflight != null) return inflight;
    }
    // web 150：60 秒内首屏短路。
    final int now = nowMillis();
    if (mode == AylaSocialMode.initial &&
        previous.fetchedAt != null &&
        now - previous.fetchedAt! < kAylaSocialFreshWindowMs) {
      return Future<void>.value();
    }
    // web 151：追加前置条件。
    if (mode == AylaSocialMode.more &&
        (!previous.hasMore || previous.nextCursor == null)) {
      return Future<void>.value();
    }

    final int revision = ++_attempt;
    final Set<String> deleted = <String>{};
    final Map<String, Object> atStart = <String, Object>{
      for (final Object item in previous.items) itemKey(item): item,
    };
    final String? cursor =
        mode == AylaSocialMode.more ? previous.nextCursor : null;
    _patch(key, previous.copyWith(loading: true, clearError: true, revision: revision));

    late final Future<void> task;
    final Future<AylaDirectoryPage<Object>> Function(
      AylaSocialKind,
      AylaSocialOptions,
      String?,
    ) send = requestOverride ?? _request;
    task = Future<void>.value()
        .then((_) => send(kind, options, cursor))
        .then((AylaDirectoryPage<Object> page) {
      final AylaSocialRecord? current = _records[key];
      if (current == null || current.revision != revision) return;
      // web 160–161：响应有效性 ⇒ **抛错**（与 directory 的静默降级不同，逐条照抄）。
      if (page.hasMore &&
          (page.nextCursor == null || page.nextCursor == cursor)) {
        throw const ApiException(0, '列表分页响应无效，请重试');
      }
      final Map<String, Object> latest = <String, Object>{
        for (final Object item in current.items) itemKey(item): item,
      };
      final List<Object> results = <Object>[
        for (final Object item in page.results)
          if (!deleted.contains(itemKey(item)))
            latest[itemKey(item)] != null &&
                    !identical(latest[itemKey(item)], atStart[itemKey(item)])
                ? latest[itemKey(item)]!
                : item,
      ];
      // web 167–169：`more` 保留全部；`initial`/`refresh` 先剔除请求期间消失的项。
      final Map<String, Object> items = <String, Object>{
        for (final Object item in (mode == AylaSocialMode.more
            ? current.items
            : <Object>[
                for (final Object item in current.items)
                  if (!atStart.containsKey(itemKey(item))) item,
              ]))
          itemKey(item): item,
      };
      for (final Object item in results) {
        items[itemKey(item)] = item;
      }
      _patch(
        key,
        current.copyWith(
          items: items.values.toList(growable: false),
          total: page.total < 0 ? 0 : page.total,
          nextCursor: page.nextCursor,
          clearNextCursor: page.nextCursor == null,
          hasMore: page.hasMore,
          loading: false,
          clearError: true,
          fetchedAt: nowMillis(),
        ),
      );
    }).catchError((Object error) {
      final AylaSocialRecord? current = _records[key];
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

  /// 重取首页（web `refresh`，绕过 60 秒缓存）。
  Future<void> refresh(AylaSocialKind kind, AylaSocialOptions options) =>
      load(kind, options, mode: AylaSocialMode.refresh);

  /// 追加下一页（web `loadMore`）。
  Future<void> loadMore(AylaSocialKind kind, AylaSocialOptions options) =>
      load(kind, options, mode: AylaSocialMode.more);

  /// 本地替换条目（web `updateSocialItems`，74–84 的投影部分）：
  /// `total` 按条目数增减同步，`mutationRevision` 递增。
  void setItems(
    AylaSocialKind kind,
    AylaSocialOptions options,
    List<Object> items,
  ) {
    final String key = aylaSocialKey(kind, options, userId: _userId);
    final AylaSocialRecord? current = _records[key];
    if (current == null) return;
    final int total = current.total + items.length - current.items.length;
    _patch(
      key,
      current.copyWith(
        items: List<Object>.unmodifiable(items),
        total: total < 0 ? 0 : total,
        mutationRevision: current.mutationRevision + 1,
      ),
    );
  }

  /// 登出 / 会话过期清空（web `useSocialStore.reset`，45）。
  void reset() {
    _pending.clear();
    _attempt += 1;
    _records.clear();
    notifyListeners();
  }

  /// 当前时间（毫秒）；**测试注入**以验证 60 秒窗口。
  int Function() nowMillis = aylaSocialNowMillis;

  void _patch(String key, AylaSocialRecord record) {
    _records[key] = record;
    notifyListeners();
  }

  /// 按 kind 分发（web `requestPage`，128–141）；未接线的 kind **显式抛错**。
  Future<AylaDirectoryPage<Object>> _request(
    AylaSocialKind kind,
    AylaSocialOptions options,
    String? cursor,
  ) async {
    switch (kind) {
      case AylaSocialKind.conversations:
        final AylaDirectoryPage<AylaConversationSummary> page =
            await AylaChatApi.listConversationsPage(
          limit: kAylaSocialPageSize,
          cursor: cursor,
          type: options.type,
        );
        return _widen<AylaConversationSummary>(page);
      case AylaSocialKind.friends:
        final AylaDirectoryPage<AylaUserPublic> page =
            await AylaUsersApi.listFriendsPageOf(
          limit: kAylaSocialPageSize,
          cursor: cursor,
        );
        return _widen<AylaUserPublic>(page);
      default:
        throw UnsupportedError(
          'social kind $kind 尚未接线（见 social_store.dart 文件头「未实现 1」）',
        );
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

  /// 条目主键（web `itemId`，52–54）：会话 / 用户行都有 `id`。
  static String itemKey(Object item) => switch (item) {
        AylaConversationSummary(:final String id) => id,
        AylaUserPublic(:final String id) => id,
        _ => item.toString(),
      };
}

/// 默认时钟（毫秒）。
int aylaSocialNowMillis() => DateTime.now().millisecondsSinceEpoch;

/// 模块级单例（web `useSocialStore` 的模块级 store 语义）。
final AylaSocialStore aylaSocialStore = AylaSocialStore();

/// 页面侧适配器 —— web `useSocialPage`（`hooks/useSocialPage.ts`）。
///
/// 与 `AylaDirectoryController` 同构：数据归 store，多个 controller 共享同一条 record，
/// 命中缓存即 `loading == false` ⇒ **页面不闪骨架**。
class AylaSocialController<T> extends ChangeNotifier {
  AylaSocialController({
    required this.store,
    required this.kind,
    required this.options,
    this.enabled = true,
  }) {
    store.addListener(_onStoreChanged);
  }

  final AylaSocialStore store;
  final AylaSocialKind kind;
  final AylaSocialOptions options;
  final bool enabled;

  bool _disposed = false;

  void _onStoreChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> load() => store.load(kind, options, enabled: enabled);

  Future<void> refresh() => store.refresh(kind, options);

  Future<void> loadMore() => store.loadMore(kind, options);

  List<T> get items => store.itemsAs<T>(kind, options);

  bool get loading => store.isLoading(kind, options, enabled: enabled);

  bool get loaded => (store.recordOf(kind, options)?.fetchedAt ?? 0) > 0;

  bool get hasMore => store.recordOf(kind, options)?.hasMore ?? false;

  /// web `useSocialPage` **恒返回 `invalidated: false`**（`hooks/useSocialPage.ts:24`）——
  /// social record 没有该字段（与 directory record 不同），故不是「未接线」。
  bool get invalidated => false;

  String? get error => store.recordOf(kind, options)?.error;

  int get total => store.recordOf(kind, options)?.total ?? 0;

  String? get nextCursor => store.recordOf(kind, options)?.nextCursor;

  /// 本地替换条目（乐观更新；转发 store 的 `setItems` 语义）。
  void setItems(List<T> next) {
    final AylaSocialRecord? current = store.recordOf(kind, options);
    if (current == null) return;
    store.setItems(kind, options, next.cast<Object>().toList(growable: false));
  }

  /// 按判据移除条目（[setItems] 的包装）。
  void removeWhere(bool Function(T item) test) =>
      setItems(<T>[
        for (final T item in items)
          if (!test(item)) item,
      ]);

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
