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
/// 2. **WS 增量与 tombstone** —— **2026-10-01 已接**（用户实报「窄屏群列表和宽屏左侧群头像
///    依然没有热更新排序 ws 接线」）：`reconcileCached`（web `stores/social.ts:87–106`）+
///    `AylaSocialTracking` 装配（web `ensureSocialTracking`，`:108–120`）+
///    tombstone 集合（web `pending.get(key)?.deleted`，`:81/94/154/163`）。
/// 3. **`subgroups` 的默认子群排序**（web 182–184）—— 随 kind 接线一并落地。
library;

import 'package:flutter/foundation.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart';
import '../core/api/users_api.dart';
import '../core/models/conversation.dart' show AylaConversationSummary;
import '../core/models/subgroup.dart' show AylaSubGroup, AylaSubgroupPage;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/net/dio_client.dart' show ApiException;
import 'chat_state.dart' show AylaChatState;
import 'subgroup_state.dart'
    show AylaSubGroupState, aylaSortSubgroupsByActivity;

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

/// 一条在途社交分页请求 —— web `pending` 的条目形状
/// （`stores/social.ts:38`：`{ promise, revision, deleted }`）。
class _AylaSocialPending {
  _AylaSocialPending({required this.revision, required this.deleted});

  /// 本次请求的代际（web 的 `revision`）。
  final int revision;

  /// 本 key 的 tombstone 集合（web 的 `deleted: Set<string>`）。
  final Set<String> deleted;

  /// 在途 Promise（web 的 `promise`；回灌给同 key 的并发调用方）。
  Future<void>? promise;
}

/// 取页实现（web `requestPage` 的返回类型，`stores/social.ts:128–141`）。
///
/// 返回 [AylaSubgroupPage]（而非裸 `AylaDirectoryPage<Object>`）是为了**保住
/// `default` 字段** —— web 在落地段读 `(page as SocialPage<SubGroup>).default`
/// （`:174`），丢了它默认组就整个缺失。非子群 kind 的 `defaultSubgroup` 为 null。
typedef AylaSocialRequest = Future<AylaSocialPage> Function(
  AylaSocialKind kind,
  AylaSocialOptions options,
  String? cursor,
);

/// 通用游标页形态的取页实现 —— [AylaSocialStore.requestOverride] 的既有签名
/// （**不含** `default`，保持与仓内既有测试兼容）。
typedef AylaDirectoryPageFunction = Future<AylaDirectoryPage<Object>> Function(
  AylaSocialKind kind,
  AylaSocialOptions options,
  String? cursor,
);

/// 一次取页的落地载体：通用游标页 + 子群页独有的 `default`。
///
/// 为什么不直接把 [AylaSubgroupPage] 当返回类型：`conversations` / `friends` 的条目
/// 不是 [AylaSubGroup]，塞不进它的强类型 `results`（会让会话页**整个变空**）。
/// 两类 kind 的条目都由端到端回归锁 `social_store_test.dart` 的「取页回流」组覆盖。
class AylaSocialPage {
  const AylaSocialPage({required this.page, this.defaultSubgroup});

  final AylaDirectoryPage<Object> page;

  /// 子群页独有的默认组（其他 kind 恒 null；web `stores/social.ts:174` 同）。
  final AylaSubGroup? defaultSubgroup;
}

/// 社交共享 store（web `useSocialStore` + `loadSocial`，`stores/social.ts:44–195`）。
///
/// 纯 `ChangeNotifier` + 模块级单例（与 `AylaDirectoryStore` 同口径：
/// **不包 Riverpod**，理由见 `state/directory_store.dart` 的单例注释）。
class AylaSocialStore extends ChangeNotifier {
  final Map<String, AylaSocialRecord> _records = <String, AylaSocialRecord>{};

  /// 在途请求（web `pending`，38：`{ promise, revision, deleted }`）。
  ///
  /// `deleted` = **本 key 的 tombstone 集合**（web :153 的 `const deleted = new Set<string>()`）：
  /// 本地显式删除（[setItems] / [reconcileCached]）与请求期间到达的删除都记在这里，
  /// 分页响应回来时据此剔除（web :163）。请求结束时随条目一起移除（web :192）。
  final Map<String, _AylaSocialPending> _pending =
      <String, _AylaSocialPending>{};

  /// 请求代际（web `attempt`，39）。
  int _attempt = 0;

  /// **回灌护栏**（web 模块级 `merging`，`stores/social.ts:40 / 88 / 170 / 181`）。
  ///
  /// 语义：`load()` 把结果回流进 chatState / subgroupState 期间置真 ⇒ 回流引发的
  /// `notifyListeners` 走到 [reconcileCached] 时**直接返回**（web `reconcileCached`
  /// 首行的 `if (merging) return; :88`）。没有它就会 social → chatState → social 死循环。
  bool _merging = false;

  /// 回流护栏当前是否生效（测试用；web 的同名字段是模块级私有变量）。
  @visibleForTesting
  bool get isMerging => _merging;

  String? _userId;

  /// 取页实现覆盖（依赖注入点；生产恒为 null ⇒ 走真实 API 分发）。
  ///
  /// ⚠️ 形态**保持**为通用游标页：仓内既有测试都按这个签名注入
  /// （`test/home_page_test.dart` / `test/social_store_test.dart` / `test/tmp_preload_probe_test.dart`），
  /// 改签名会把**范围外**的测试一起打断。子群 kind 需要构造 `default` 字段时
  /// 用 [subgroupRequestOverride]。
  AylaDirectoryPageFunction? requestOverride;

  /// 子群 kind 专用取页覆盖（端到端回归锁用它构造带 `default` 的响应）。
  ///
  /// web 的 subgroups 取页响应**额外带 `default` 字段**（`stores/social.ts:174`
  /// 读 `page.default`），通用游标页类型装不下它 —— 这正是「默认组整个缺失」的成因。
  AylaSocialRequest? subgroupRequestOverride;

  /// **取页回流**（web `stores/social.ts:170–181` 的落地段）——
  /// 逐条照 web：`conversations` 的每条结果 `upsertConversation`；
  /// `subgroups` 先单独落 `default`、再逐条 `upsertSubgroup`。
  ///
  /// 本 store 是**纯 `ChangeNotifier`**（见类注释：不依赖 Riverpod、不反向依赖
  /// chatState/subgroupState）⇒ 用**可注入回调**表达这两个跨域写入，
  /// 装配点 = [AylaSocialTracking.bindRehydration]（由 `chat_providers.dart` 注入真实实现）。
  /// 范式与 [AylaDirectoryStore.itemUpsertHooks] 同款（库内已有先例）。
  void Function(AylaConversationSummary conv)? onConversationLoaded;

  /// 见 [onConversationLoaded]；`isDefault` 用于对齐 web `items.set(defaultGroup.id, …)`
  /// 的**并入**语义（默认组不在 `results` 里，必须显式并入本次落盘集合）。
  void Function(String groupId, AylaSubGroup sg, {required bool isDefault})?
      onSubgroupLoaded;

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
      final _AylaSocialPending? inflight = _pending[key];
      final Future<void>? promise = inflight?.promise;
      if (promise != null) return promise;
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
    // web :153–154：本次请求自己的 tombstone 集合（与既有 `_pending` 条目**同一个引用**
    // —— 这样 `updateSocialItems` / `reconcileCached` 在请求期间写进的 id 都可见）。
    final _AylaSocialPending pending = _AylaSocialPending(
      revision: revision,
      deleted: _pending[key]?.deleted ?? <String>{},
    );
    final Set<String> deleted = pending.deleted;
    final Map<String, Object> atStart = <String, Object>{
      for (final Object item in previous.items) itemKey(item): item,
    };
    final String? cursor =
        mode == AylaSocialMode.more ? previous.nextCursor : null;
    _patch(key, previous.copyWith(loading: true, clearError: true, revision: revision));

    late Future<void> task;
    final AylaSocialRequest send = _resolveSend(kind);
    task = Future<void>.value()
        .then((_) => send(kind, options, cursor))
        .then((AylaSocialPage page) {
      final AylaSocialRecord? current = _records[key];
      if (current == null || current.revision != revision) return;
      // web 160–161：响应有效性 ⇒ **抛错**（与 directory 的静默降级不同，逐条照抄）。
      if (page.page.hasMore &&
          (page.page.nextCursor == null || page.page.nextCursor == cursor)) {
        throw const ApiException(0, '列表分页响应无效，请重试');
      }
      final Map<String, Object> latest = <String, Object>{
        for (final Object item in current.items) itemKey(item): item,
      };
      final List<Object> results = <Object>[
        for (final Object item in page.page.results)
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
      // web 170–181：**取页结果回流**进 chatState / subgroupState（`merging` 真护栏
      // 包住整段；`finally` 复位 ⇒ 回流触发的 notifyListeners 不会反过来再进
      // `reconcileCached`，否则 social ↔ chatState 无限回环）。
      _merging = true;
      try {
        if (kind == AylaSocialKind.conversations) {
          for (final Object item in results) {
            if (item is AylaConversationSummary) {
              onConversationLoaded?.call(item);
            }
          }
        }
        if (kind == AylaSocialKind.subgroups) {
          // web 174–178：`default` 是**独立字段**（不在 results 里）⇒ 必须显式并入，
          // 否则默认组整个缺失（后端子群列表的游标页用 SUBGROUP_ORDER 排序、
          // `views.py:238–247` 另给 `default`；默认组不保证落在本页 rows 内）。
          final AylaSubGroup? defaultGroup = page.defaultSubgroup;
          final String groupId = options.groupId ?? '';
          if (defaultGroup != null &&
              !deleted.contains(defaultGroup.id) &&
              groupId.isNotEmpty) {
            onSubgroupLoaded?.call(groupId, defaultGroup, isDefault: true);
            items[defaultGroup.id] = defaultGroup;
          }
          for (final Object item in results) {
            if (item is AylaSubGroup && groupId.isNotEmpty) {
              onSubgroupLoaded?.call(groupId, item, isDefault: false);
            }
          }
        }
      } finally {
        _merging = false;
      }
      // web 182–184：子群列表落地投影按「默认组优先 → last_message_seq 降序」排序
      //（store 先排、组件收有序数据；与 `ChannelSidebar.tsx:137` 的展示层排序同判据）。
      final List<Object> effectiveItems = kind == AylaSocialKind.subgroups
          ? aylaSortSubgroupsByActivity(<AylaSubGroup>[
              for (final Object item in items.values)
                if (item is AylaSubGroup) item,
            ]).cast<Object>()
          : items.values.toList(growable: false);
      _patch(
        key,
        current.copyWith(
          items: effectiveItems,
          total: page.page.total < 0 ? 0 : page.page.total,
          nextCursor: page.page.nextCursor,
          clearNextCursor: page.page.nextCursor == null,
          hasMore: page.page.hasMore,
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
      // web :192：`pending.get(key)?.revision === revision` ⇒ 才移除（代际守卫）。
      if (_pending[key]?.revision == pending.revision) _pending.remove(key);
    });

    pending.promise = task;
    _pending[key] = pending;
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
  ///
  /// ⚠️ 与 web :79–81 **逐条对齐**：被移除的条目要写进该 key 的 tombstone 集合
  /// （`for (const id of deleted) pending.get(key)?.deleted.add(id)`）——
  /// 这样「本地刚删掉的条目」不会被**随后返回的在途分页响应**重新灌回来
  /// （[load] 的 results 过滤读的就是同一集合，web :154/163）。
  void setItems(
    AylaSocialKind kind,
    AylaSocialOptions options,
    List<Object> items,
  ) {
    final String key = aylaSocialKey(kind, options, userId: _userId);
    final AylaSocialRecord? current = _records[key];
    if (current == null) return;
    final Set<String> retained = <String>{
      for (final Object item in items) itemKey(item),
    };
    final Set<String>? tombstones = _pending[key]?.deleted;
    if (tombstones != null) {
      for (final Object item in current.items) {
        final String id = itemKey(item);
        if (!retained.contains(id)) tombstones.add(id);
      }
    }
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

  /// 已加载社交投影的**就地对账** —— web `reconcileCached`（`stores/social.ts:87–106`）。
  ///
  /// 语义（逐条照 web，无一处自由发挥）：
  /// - `before`/`after` 都是 `Map<itemId, item>`（web :89–90）；
  /// - 只处理**同 kind** 的 record（`:92`）；
  /// - `removed` = 旧表里有、新表里没有、**且仍能被该 record 匹配**的项 ⇒ 写 tombstone（`:93–95`）；
  /// - `items` = 现有项去掉 removed、用新表里的同 id 实例**替换**、再按 `matches` 过滤（`:96–97`）；
  /// - `added` = 新表里**新增**（不在 before）且**不在已保留集合**里且匹配的项 ⇒ **前插**（`:99`）；
  /// - `changed` 三重判据（有新增 / 长度变化 / 逐项**身份**比较）（`:100–101`），
  ///   未变化时 **continue**（不 patch、不递增 revision、不通知）；
  /// - patch 时 `total` 按新增/移除数同步（floor 0），`mutationRevision + 1`（`:103–104`）。
  ///
  /// ⚠️ 与 web 的两处**机制差异**（Flutter 侧的表达差异，不是语义差异）：
  /// 1. web 用模块级 `merging` 布尔标志防止 `upsertConversation` 回灌时再次触发
  ///    （`:88` 的 `if (merging) return`）；Flutter 侧由 [AylaSocialTracking] 用一个
  ///    **实例级**重入标志承担同一职责（store 是类实例，不该有跨实例的模块级状态）。
  /// 2. web 的 `pending.get(key)?.deleted` 里 `pending` 只在**分页请求在途**时有该 key
  ///    ⇒ Flutter 侧同样只在 `_pending` 里有该 key 时写 tombstone（缺席即不写，与 web 同）。
  void reconcileCached(
    AylaSocialKind kind,
    List<Object> next,
    List<Object> old,
  ) {
    // web :88 的首行护栏：回灌期间不再触发对账（否则 social ↔ chatState 无限回环）。
    if (_merging) return;
    if (kind != AylaSocialKind.conversations && kind != AylaSocialKind.subgroups) {
      // web 的入参类型就是 `"conversations" | "subgroups"`（`:87`）——
      // 其余 kind 的条目 id 语义不同（friendship 走 `user.id`），不在此处兜底。
      return;
    }
    final Map<String, Object> before = <String, Object>{
      for (final Object item in old) itemKey(item): item,
    };
    final Map<String, Object> after = <String, Object>{
      for (final Object item in next) itemKey(item): item,
    };
    for (final MapEntry<String, AylaSocialRecord> entry in _records.entries) {
      final String key = entry.key;
      final AylaSocialRecord record = entry.value;
      if (record.kind != kind) continue;
      final List<Object> removed = <Object>[
        for (final Object item in old)
          if (!after.containsKey(itemKey(item)) && _matches(record, item)) item,
      ];
      final Set<String> removedIds = <String>{
        for (final Object item in removed) itemKey(item),
      };
      final Set<String>? tombstones = _pending[key]?.deleted;
      if (tombstones != null) tombstones.addAll(removedIds);
      final List<Object> mapped = <Object>[
        for (final Object item in record.items)
          if (!removedIds.contains(itemKey(item)))
            after[itemKey(item)] ?? item,
      ];
      final List<Object> items = <Object>[
        for (final Object item in mapped)
          if (_matches(record, item)) item,
      ];
      final Set<String> ids = <String>{for (final Object item in items) itemKey(item)};
      final List<Object> added = <Object>[
        for (final Object item in next)
          if (!before.containsKey(itemKey(item)) &&
              !ids.contains(itemKey(item)) &&
              _matches(record, item))
            item,
      ];
      final bool changed = added.isNotEmpty ||
          items.length != record.items.length ||
          _itemsDiffer(items, record.items);
      if (!changed) continue;
      final int total = record.total + added.length - removed.length;
      _patch(
        key,
        record.copyWith(
          items: List<Object>.unmodifiable(<Object>[...added, ...items]),
          total: total < 0 ? 0 : total,
          mutationRevision: record.mutationRevision + 1,
        ),
      );
    }
  }

  /// web `items.some((item, index) => item !== record.items[index])`（`:101`）——
  /// **身份**比较（不是值比较）：web 的这一句就是同一对象引用相等。
  static bool _itemsDiffer(List<Object> a, List<Object> b) {
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return true;
    }
    return false;
  }

  /// web `matches(record, item)`（`stores/social.ts:62–71`）。
  ///
  /// - `conversations`：`type` 档 + 搜索词对 title / peer.nickname / peer.username 的
  ///   小写包含判定（web 用的 `toLocaleLowerCase`，Dart 用 `toLowerCase`）；
  /// - `subgroups`：`conversation_id === options.groupId`；
  /// - **其余 kind 恒 true**（web `:70` 的 `record.kind !== "subgroups" || …` 取反后即是）。
  bool _matches(AylaSocialRecord record, Object item) {
    if (record.kind == AylaSocialKind.conversations) {
      if (item is! AylaConversationSummary) return false;
      final String? type = record.options.type;
      if (type != null && type != 'all' && type != item.type?.wire) return false;
      final String query = (record.options.q ?? '').trim().toLowerCase();
      if (query.isEmpty) return true;
      for (final String? value in <String?>[
        item.title,
        item.peer?.nickname,
        item.peer?.username,
      ]) {
        if (value != null && value.toLowerCase().contains(query)) return true;
      }
      return false;
    }
    // web :70：`record.kind !== "subgroups" || (item as SubGroup).conversation_id === record.options.groupId`
    // 取反后 ⇒ 非 subgroups 的 kind 恒 true；subgroups 按归属会话判。
    if (record.kind == AylaSocialKind.subgroups) {
      return item is AylaSubGroup &&
          item.conversationId == (record.options.groupId ?? '');
    }
    return true;
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

  /// 选择本次请求的实现：子群 kind 优先 [subgroupRequestOverride]，
  /// 其余 kind 用 [requestOverride]（通用游标页形态，自动包成 [AylaSocialPage]）。
  AylaSocialRequest _resolveSend(AylaSocialKind kind) {
    if (kind == AylaSocialKind.subgroups && subgroupRequestOverride != null) {
      return subgroupRequestOverride!;
    }
    final AylaDirectoryPageFunction? legacy = requestOverride;
    if (legacy != null) {
      return (AylaSocialKind kind, AylaSocialOptions options, String? cursor) async =>
          _widen<Object>(await legacy(kind, options, cursor));
    }
    return _request;
  }

  /// 按 kind 分发（web `requestPage`，128–141）；未接线的 kind **显式抛错**。
  Future<AylaSocialPage> _request(
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
      case AylaSocialKind.subgroups:
        // web :133 `chatApi.listSubgroupsPage(options.groupId!, params)` ——
        // **不做 `_widen`**：落地段要读它的 `default`（`:174`）。
        final AylaSubgroupPage page = await AylaChatApi.listSubgroupsPage(
          options.groupId ?? '',
          limit: kAylaSocialPageSize,
          cursor: cursor,
        );
        return AylaSocialPage(
          page: AylaDirectoryPage<Object>(
            results: List<Object>.of(page.results),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            total: page.total,
          ),
          defaultSubgroup: page.defaultSubgroup,
        );
      default:
        throw UnsupportedError(
          'social kind $kind 尚未接线（见 social_store.dart 文件头「未实现 1」）',
        );
    }
  }

  static AylaSocialPage _widen<T extends Object>(
    AylaDirectoryPage<T> page,
  ) =>
      AylaSocialPage(
        page: AylaDirectoryPage<Object>(
          results: List<Object>.of(page.results),
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          total: page.total,
          totalMemberCount: page.totalMemberCount,
        ),
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

/// 社交缓存订阅装配 —— web `ensureSocialTracking`（`stores/social.ts:108–120`）的等价物。
///
/// ## 为什么需要它（用户实报的根因）
/// 「窄屏群列表 / 宽屏左侧群头像列的顺序不随 WS 更新」在 web 上是**两条机制拼起来的**：
/// - `sortGroupsByActivity` 负责**排序**（读四个目录 store + `chatState.groupActivityAt`）；
/// - `reconcileCached`（本条）负责**喂新数据** —— 把 `chatState.conversations` /
///   `subgroupState.byGroup` 的新值就地合并进 social record 的已加载投影。
/// Flutter 侧此前只有第一条（`aylaSortGroupsByActivity`），第二条完全缺席
/// ⇒ 主页 `_groups()` 读的 social record 里的会话摘要（标题 / 最后一条消息 / 未读）
/// **永不随 WS 刷新**。本类补齐第二条。
///
/// ## 与 web 的**机制差异**（登记，逐条说明理由）
/// | web | 行 | 本件 | 说明 |
/// |---|---|---|---|
/// | `useAuthStore.subscribe`（比 `currentUser?.id` / `accessToken`） | 111–113 | `AylaSocialStore.userId` setter |
/// 该 setter 已在值变化时 `reset()`，与 web「id 变 / 令牌清空 ⇒ reset」等价；
/// 登录后由 `app_preload.dart` 赋 `userId`，因此不必再挂第三条订阅 |
/// | `useChatStore.subscribe((next, old) => next.conversations !== old.conversations)` | 114–116 |
/// `AylaChatState` 的 `addListener` + **逐项身份比较** |
/// Flutter 的 `notifyListeners()` 无参 ⇒ 拿不到 `next`/`old`；且两个 getter 每次返回新实例
/// （`List.unmodifiable` / `Map.unmodifiable`）⇒ 用「长度 + 逐元素 `identical`」表达 web 的
/// 数组身份判据（净效果一致，见 `onChat` 的说明） |
/// | `useSubGroupStore.subscribe(...next.byGroup !== old.byGroup)` | 117–119 | 同上（展平后逐项） |
/// web 的入参是 `Object.values(byGroup).flat()`（展平后一整条数组），本件同 |
/// | 模块级 `tracking` + `unsubscribers` | 35·41–42 | 实例字段 + [dispose] |
/// Flutter 侧由 provider 持有单例（`room_providers.dart`），生命周期归 provider |
/// | `merging` 模块级布尔 | 40·88 | `AylaSocialStore.runMerging` | 语义护栏：回灌期间不再触发对账 |
///
/// ⚠️ **不挂在 `AylaSocialStore` 自己身上**：store 是纯 `ChangeNotifier` 数据件
/// （与 `AylaDirectoryStore` 同口径，见其单例注释），装配归 provider 层 —— 本类即该层。
class AylaSocialTracking {
  AylaSocialTracking({required AylaSocialStore store}) : _store = store;

  final AylaSocialStore _store;
  final List<void Function()> _unsubscribers = <void Function()>[];

  bool _bound = false;

  /// 逐项**身份**比较（长度 + 每个位置 `identical`）。
  ///
  /// 为什么不是 `identical(a, b)`：两个源的 getter 每次调用都包一层新实例
  /// （`AylaChatState.conversations` → `List.unmodifiable`、
  /// `AylaSubGroupState.byGroup` → `Map.unmodifiable`）⇒ 引用比较恒 false。
  /// web 的判据是**数组身份**（`next.conversations !== old.conversations`），
  /// 「数组被替换但元素全同」在 web 上也会进 `reconcileCached` 并因 `changed === false`
  /// 而 no-op ⇒ 本判据与 web 净效果一致。
  static bool _sameItems(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// 上一次并入对账的会话列表**引用**（web 的 `old.conversations`）。
  List<AylaConversationSummary>? _conversations;

  /// 上一次并入对账的子群投影**引用**（web 的 `old.byGroup`）。
  Map<String, List<AylaSubGroup>>? _byGroup;

  /// 订阅两个源（web `:114–119`；auth 那条由 `userId` setter 承担）。
  ///
  /// 幂等：重复调用不重复挂监听（web 的 `if (tracking) return`，`:109`）。
  void bind({
    required AylaChatState chatState,
    required AylaSubGroupState subgroupState,
  }) {
    if (_bound) return;
    _bound = true;
    _conversations = chatState.conversations;
    _byGroup = subgroupState.byGroup;

    void onChat() {
      final List<AylaConversationSummary> next = chatState.conversations;
      final List<AylaConversationSummary>? old = _conversations;
      _conversations = next;
      // web :115：`next.conversations !== old.conversations`。
      // ⚠️ Flutter 侧**不能直接用 `identical`**：`AylaChatState.conversations` 的 getter
      // 每次调用都 `List.unmodifiable(...)` 包一层新实例（`chat_state.dart:34–35`）
      // ⇒ 两次读取永远不 identical。等价判据 = **逐项身份比较**：
      // 元素数组与顺序都没变时，`reconcileCached` 的 before/after 映射完全相同、
      // `changed` 必然为 false（web 那一侧同理：数组被替换但元素全同也是 no-op）
      // ⇒ 提前 return 与照常 reconcile **净效果一致**，只是省掉一次无谓的对账。
      if (old != null && _sameItems(next, old)) return;
      _store.reconcileCached(
        AylaSocialKind.conversations,
        List<Object>.of(next),
        List<Object>.of(old ?? const <AylaConversationSummary>[]),
      );
    }

    void onSubgroups() {
      final Map<String, List<AylaSubGroup>> next = subgroupState.byGroup;
      final Map<String, List<AylaSubGroup>>? old = _byGroup;
      _byGroup = next;
      // web :118：`Object.values(next.byGroup).flat()` / `Object.values(old.byGroup).flat()`
      // —— 展平后仍按上一条的**逐项身份**判据（`byGroup` getter 同样每次包新实例，
      // 见 `subgroup_state.dart:51–55`）。
      final List<AylaSubGroup> nextFlat = <AylaSubGroup>[
        for (final List<AylaSubGroup> list in next.values) ...list,
      ];
      final List<AylaSubGroup> oldFlat = <AylaSubGroup>[
        for (final List<AylaSubGroup> list
            in (old ?? const <String, List<AylaSubGroup>>{}).values)
          ...list,
      ];
      if (old != null && _sameItems(nextFlat, oldFlat)) return;
      _store.reconcileCached(
        AylaSocialKind.subgroups,
        List<Object>.of(nextFlat),
        List<Object>.of(oldFlat),
      );
    }


    chatState.addListener(onChat);
    subgroupState.addListener(onSubgroups);
    _unsubscribers
      ..add(() => chatState.removeListener(onChat))
      ..add(() => subgroupState.removeListener(onSubgroups));
  }

  /// **取页回流装配**（web `stores/social.ts:170–181` 的落地段写入口）。
  ///
  /// ## 为什么需要它（用户实报「发条消息根本不排上去」的根因）
  /// web 的 `loadSocial` **双写**：既写 social record，也写回 `useChatStore` /
  /// `useSubGroupStore`。Flutter 侧 `load()` 此前**只写 record** ⇒
  /// 「social 有、chatState 没有」的群（第 2 页 / 新群 / 别处刷新）会让
  /// `chat_ws.dart:656` 的 `if (conv != null)` 为假 ⇒ `setLastMessage` 与
  /// `bumpGroupActivity` 都不执行 ⇒ **排序不动**。
  ///
  /// ## 与 web 的机制差异（登记）
  /// web 用模块级 `merging` 布尔 + 直接调 store；Flutter 的 [AylaSocialStore] 是
  /// **纯 `ChangeNotifier`**（不反向依赖 chatState/subgroupState，见类注释）⇒
  /// 由本方法注入两个回调。护栏同样是 store 内的 [AylaSocialStore._merging]
  /// （web `:88` 的 `if (merging) return`，本件 [AylaSocialStore.reconcileCached] 首行）。
  ///
  /// 幂等：重复调用只覆盖同一个回调（后写胜出），不重复挂监听。
  void bindRehydration({
    required AylaChatState chatState,
    required AylaSubGroupState subgroupState,
  }) {
    _store.onConversationLoaded = chatState.upsertConversation;
    _store.onSubgroupLoaded =
        (String groupId, AylaSubGroup sg, {required bool isDefault}) {
      // web `:179` `upsertSubgroup(options.groupId!, item)` —— 默认组与普通条目
      // 走**同一条** upsert（默认组不额外标记；`is_default` 由条目自身携带）。
      subgroupState.upsertSubgroup(groupId, sg);
    };
  }

  /// 解绑（登出 / 测试收尾；web `disposeSocialTracking`，`:121–125`）。
  void dispose() {
    for (final void Function() off in _unsubscribers) {
      off();
    }
    _unsubscribers.clear();
    _bound = false;
    _conversations = null;
    _byGroup = null;
  }
}
