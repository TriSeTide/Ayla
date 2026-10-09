/// 收藏状态机 —— web `stores/favoriteStatus.ts` 131 行的 Flutter 等价物（精简：
/// 按类型批量查询 + 60s 新鲜期 + 动作）。
///
/// ## 逐条对应的 web 语义
/// - 键 = `"<type>:<id>"`（`favoriteStatus.ts:18`）；
/// - **状态未知 ≠ 未收藏**：`favoriteId === undefined` 是「没查过/查询中」，
///   `null` 才是「未收藏」（`favoriteStatus.ts:1–2` 的注释，是这套状态机的核心不变量）；
/// - 单次查询上限 100 个 id（`favoriteStatus.ts:86` 的 `slice(0, 100)` 与
///   `api/favorites.ts:25` 的硬上限）；
/// - 60s 内不重复查询（`favoriteStatus.ts:121`）；
/// - 响应必须覆盖请求的每个 id，否则视为**不完整**并报错（`favoriteStatus.ts:93`）；
/// - 点按钮时若状态未知/出错 ⇒ 点击 = **重新拉取状态**（不是收藏）
///   （`FavoriteButton.tsx:35–38`）——本类把这条做成 [toggle] 内的分支。
///
/// ## 自给自足（2026-10-08 修：结构缺陷）
/// web 的收藏键**自己加载自己**（`FavoriteButton.tsx:22` 调 `useFavoriteStatuses`，
/// 后者在 `useFavoriteStatuses.ts:12–16` 的 `useEffect` 里
/// **retain + load + 卸载 release**）⇒ 任何地方放一个收藏键都自动工作，
/// 页面无需接线。Flutter 侧对应物 = [AylaFavoriteStatusController.retain]
/// （引用计数）+ `AylaFavoriteButton` 的 `targetType/targetId/controller` 模式
/// （见 `widgets/base/favorite_button.dart`）。
///
/// 修前缺陷：状态/加载/切换**外提给页面** ⇒ 页面漏调一次 [load]，
/// 该处收藏键就永远停在 `unknown`（禁用 + 「正在加载收藏状态」）。
///
/// ## 查询队列（2026-10-09 复刻 web `drain`）
/// web 的每个收藏键都独立调 `loadFavoriteStatuses`（`useFavoriteStatuses.ts:14`），
/// 但状态查询**不是「一个键一个请求」**：id 先进按类型分组的 `queue`
/// （`favoriteStatus.ts:26 / 123–125`），再 `queueMicrotask(drain)`；
/// `drain`（`:81–114`）每次取 100 个 id、**并发上限 2**，完成后继续消费
/// ⇒ 一屏 N 个挂载的收藏键合并成**有界批量请求**。
/// 这正是 `/favorites/status/` 硬上限 100（`api/favorites.ts:25`）的由来，也是
/// 一屏 50 条消息不会变成 50 个请求的原因。本文件按下述口径复刻同一语义。
///
/// WS 的 `favorite.changed` 增量（[apply]）已可用。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/favorites_api.dart';
import '../widgets/base/favorite_button.dart' show AylaFavoriteState;

/// 作用域代际（web `epoch`，`favoriteStatus.ts:22`）：账号切换时自增 ⇒
/// 在途响应作废（`favoriteStatus.ts:92 / 102`）。
///
/// ## 登记（未接线，与本轮缺陷无关）
/// web 在 `ensureFavoriteScope`（`favoriteStatus.ts:28–48`）里
/// `useAuthStore.subscribe` 监听账号变化；Flutter 侧目前**没有**在登录/登出时调用
/// [aylaFavoriteResetScope]（本任务文件范围不含 `main.dart`）。
/// 影响面：同一控制器实例跨越登录周期时，旧账号的收藏状态可能残留到新账号首次写入为止。
/// 实际风险低 —— 每个页面/收藏键各持一个控制器实例，登出会走路由守卫换页并销毁它们；
/// 接线点 = `main.dart` 的 `aylaStartSocialTracking` 同处（订阅 `authNotifierProvider`）。
int _favoriteScopeEpoch = 0;

/// 作用域代际的**变更通知**（web 的 `useAuthStore.subscribe` + Zustand 订阅：
/// `favoriteStatus.ts:36–42` 里 epoch 变化会**立刻** `setState({entries: new Map()})`
/// ⇒ 所有挂载的 `FavoriteButton` 立即重渲染为 unknown 并重新 `load`）。
///
/// Flutter 侧没有全局 store 的自动重渲染，用一个 [ValueNotifier] 表达同一时序：
/// `AylaFavoriteButton` 自给自足档监听它，代际一变就重绑（release 旧键 + retain 新键
/// + 重新 load），**无需等待一次外部 rebuild**。
final ValueNotifier<int> aylaFavoriteScopeListenable = ValueNotifier<int>(0);

/// 当前代际。控制器用它在**每次读写前**同步账号作用域（web `ensureFavoriteScope`）。
int aylaFavoriteScopeEpoch() => _favoriteScopeEpoch;

/// 已构造且未 dispose 的控制器（web 是模块级单例 store ⇒ 天然只有一份；
/// Flutter 侧可有多个实例，代际切换时必须**全部**立即清空）。
final List<AylaFavoriteStatusController> _registry =
    <AylaFavoriteStatusController>[];

/// web `ensureFavoriteScope()`：账号变化 ⇒ 代际自增 + 所有控制器**立即**清空已查状态
/// （`favoriteStatus.ts:36–42` 的 `epoch += 1` + `setState({ entries: new Map() })`）。
///
/// **只在账号标识真的变化时由调用方触发**（web `if (scope !== next)`）⇒
/// 重复调用只会多留一代，不会伪造状态。
void aylaFavoriteResetScope() {
  _favoriteScopeEpoch += 1;
  // ① 立即清空（web 同帧生效）：不等下一次读写。
  for (final AylaFavoriteStatusController controller in List.of(_registry)) {
    controller.resetForScopeChange();
  }
  // ② 通知挂载中的收藏键重绑（web 的 store 订阅重渲染）。
  aylaFavoriteScopeListenable.value = _favoriteScopeEpoch;
}

/// 单个目标的收藏状态。
class AylaFavoriteEntryStatus {
  const AylaFavoriteEntryStatus({
    this.known = false,
    this.favoriteId,
    this.loading = false,
    this.error,
    this.updatedAt = 0,
    this.revision = 0,
  });

  /// 是否已查到过状态（web `favoriteId !== undefined`）。
  final bool known;

  /// 条目代际（web `FavoriteStatus.revision`，`favoriteStatus.ts:11`）：每次写入自增。
  /// 在途响应只有代际未被后续写入覆盖时才落盘（`favoriteStatus.ts:99`）。
  final int revision;

  /// 收藏 id（[known] 为 true 时：null = 未收藏，数字 = 已收藏）。
  final int? favoriteId;

  final bool loading;
  final String? error;

  /// 写入时间（ms epoch；60s 新鲜期判定用）。
  final int updatedAt;
}

/// 状态查询（注入以便纯逻辑测试）。
typedef AylaFavoriteStatusFetcher = Future<AylaFavoriteStatuses> Function(
  String targetType,
  List<String> targetIds,
);

/// 收藏 / 取消收藏（注入以便纯逻辑测试）。
typedef AylaFavoriteAdd = Future<int> Function(
  String targetType,
  String targetId,
);
typedef AylaFavoriteRemove = Future<void> Function(int favoriteId);

/// 收藏状态 Notifier：三域卡片 / 搜索结果 / 收藏页共用。
class AylaFavoriteStatusController extends ChangeNotifier {
  AylaFavoriteStatusController({
    AylaFavoriteStatusFetcher? fetcher,
    AylaFavoriteAdd? add,
    AylaFavoriteRemove? remove,
  })  : _fetch = fetcher ?? AylaFavoritesApi.getFavoriteStatuses,
        _add = add ?? AylaFavoritesApi.addFavorite,
        _remove = remove ?? AylaFavoritesApi.removeFavorite {
    _registry.add(this);
  }

  final AylaFavoriteStatusFetcher _fetch;
  final AylaFavoriteAdd _add;
  final AylaFavoriteRemove _remove;

  /// 状态新鲜期（web 60_000ms）。
  static const Duration freshFor = Duration(seconds: 60);

  /// 单次批量查询上限（web `slice(0, 100)`）。
  static const int batchLimit = 100;

  final Map<String, AylaFavoriteEntryStatus> _entries =
      <String, AylaFavoriteEntryStatus>{};
  final Map<String, String?> _actionErrors = <String, String?>{};
  final Set<String> _busy = <String>{};

  /// 引用计数（web `retained`，`favoriteStatus.ts:19`）：键 → 持有它的挂载组件数。
  ///
  /// 挂在屏上的目标**永不被淘汰**（`favoriteStatus.ts:57` 的
  /// `!retained.has(candidate)`）；两个组件持有同一键时，先卸载的那个
  /// release 到 1 ⇒ 状态保留（web 同语义）。
  final Map<String, int> _retained = <String, int>{};

  /// 缓存上限（web `favoriteStatus.ts:54` 的 1024）。
  static const int cacheLimit = 1024;

  /// 并发请求上限（web `drain` 的 `while (active < 2 …)`，`favoriteStatus.ts:83`）。
  static const int concurrency = 2;

  /// 待查询队列（web `queue`，`favoriteStatus.ts:26`）：类型 → 待查 id（同类型合并）。
  final Map<String, Set<String>> _queue = <String, Set<String>>{};

  /// 在途请求数（web `active`，`favoriteStatus.ts:25`）。
  int _active = 0;

  /// 是否已排过一次 drain（web `scheduled`，`favoriteStatus.ts:24`）。
  bool _scheduled = false;

  /// 等待「该键本轮查询落盘」的调用方（Flutter 侧 [load] 是 `Future`，
  /// web 的 `loadFavoriteStatuses` 是同步入队 ⇒ 用它把 await 语义补回来；
  /// 不改变任何状态语义，只决定 `await load(...)` 何时返回）。
  final Map<String, List<Completer<void>>> _waiters =
      <String, List<Completer<void>>>{};

  int _revision = 0;
  bool _disposed = false;

  /// 状态键（web `favoriteStatusKey`）。
  static String keyOf(String targetType, String targetId) =>
      '$targetType:$targetId';

  /// 上次同步时的账号作用域代际（web `scope` 变量，
  /// `favoriteStatus.ts:20 / 34–42`）。
  int _scope = aylaFavoriteScopeEpoch();

  /// web `ensureFavoriteScope()`：作用域（登录账号）变了 ⇒
  /// 代际自增、清空全部条目（`favoriteStatus.ts:36–42`）。
  ///
  /// **只在真的变化时清** ⇒ 重复调用无副作用；不清 `_retained`（引用计数
  /// 归组件生命周期所有，由各自的 release 收尾）。
  void _syncScope() {
    final int next = aylaFavoriteScopeEpoch();
    if (next == _scope) return;
    _clearForScope();
  }

  /// 代际变化 → 清空（web `favoriteStatus.ts:36–42` 的 `setState({entries: new Map()})`
  /// 加上 `queue.clear()` / `active = 0`）。
  ///
  /// 由 [aylaFavoriteResetScope] **立即**调用（不等下一次读写）—— web 的
  /// `ensureFavoriteScope` 是同步生效的：账号一变，所有挂载的收藏键当帧就回到 unknown。
  void resetForScopeChange() {
    if (_disposed) return;
    if (aylaFavoriteScopeEpoch() == _scope) return;
    _clearForScope();
  }

  void _clearForScope() {
    _scope = aylaFavoriteScopeEpoch();
    _entries.clear();
    _actionErrors.clear();
    _busy.clear();
    _queue.clear(); // web `queue.clear()`（favoriteStatus.ts:39）
    _active = 0; // web `active = 0`（favoriteStatus.ts:40）
    _completeAllWaiters();
    _notify(); // web 的 store 写入会通知订阅者（收藏键立即回到 unknown）
  }

  /// 按钮三态（+ 错误态）。
  ///
  /// ## ⚠️ 惰性补加载（2026-10-09 二次修复：web「渲染即加载」的等价物）
  /// 用户复现：「**刷新该页面后能点**，但从其他页面切回来又变成禁用
  /// （提示正在加载收藏状态）；群内消息界面没问题」。
  ///
  /// 根因：web 的加载点是**组件挂载**（`FavoriteButton.tsx:22` →
  /// `useFavoriteStatuses.ts:12–16` 的 `useEffect`）⇒ 只要渲染出收藏键就一定会加载。
  /// Flutter 侧的**注入档**调用点（页面传 `favoriteState:` 给
  /// `AylaLiveChannelCard` / `AylaPostCard` / `AylaGameRoomCard` 等）把加载挂在
  /// **页面自己的目录回调**上（`_onPagerChanged` 里的 `_favorites.load(...)`）——
  /// 那条回调**不保证触发**：
  /// - `state/directory_store.dart:682–688` 的 60 秒缓存短路在**任何
  ///   `notifyListeners` 之前** `return` ⇒ 切回页面命中缓存时 `_pager` 不通知
  ///   ⇒ `_onPagerChanged` 不执行 ⇒ 页面渲染了卡片却从不查询状态 ⇒ 永久 unknown；
  /// - `state/posts_store.dart:321–327` 的 `shouldLoad(key)` 为 false 时
  ///   `posts_hub_page._start()` 连 `pager.load()` 都不调，更不会有通知。
  ///
  /// 「刷新后能点」= 刷新走 `refresh()` 绕过缓存 ⇒ 有通知 ⇒ 顺带加载了收藏状态；
  /// 「消息气泡没问题」= 它已走自给自足档（`message_bubble.dart`），不依赖页面接线。
  ///
  /// ⇒ 本节让**查询本身**承担加载：调用方（页面 build）第一次问某个键的状态时，
  /// 若该键从未被查询过，就排队补一次 [load]（microtask 合并、按类型批量，
  /// 与 drain 同批、同 web 的 `queueMicrotask(drain)` 时序）。
  /// 语义与 web 完全一致（渲染即加载），且**无需改任何页面**。
  ///
  /// 不产生重复请求：已查过（含 error 档 ⇒ 由用户点击重试，`FavoriteButton.tsx:35–38`）
  /// 或已在途/已排队的键都不再排队；[load] 自身另有在途去重与 60 秒新鲜期。
  AylaFavoriteState stateOf(String targetType, String targetId) {
    final AylaFavoriteEntryStatus? entry = _entries[keyOf(targetType, targetId)];
    if (entry == null) {
      _scheduleAutoLoad(targetType, targetId);
      return AylaFavoriteState.unknown;
    }
    if (entry.error != null && entry.known == false) {
      return AylaFavoriteState.error;
    }
    if (entry.loading && entry.known == false) return AylaFavoriteState.unknown;
    if (!entry.known) return AylaFavoriteState.unknown;
    return entry.favoriteId != null
        ? AylaFavoriteState.favorited
        : AylaFavoriteState.notFavorited;
  }

  /// [stateOf] 的惰性补加载：从未查询过的键 ⇒ 排一次批量查询。
  ///
  /// ⚠️ **不能在 [stateOf] 里同步调 [load]**：`stateOf` 由 `build()` 调用，
  /// 而 `load` 会同步 `notifyListeners`（把状态置 loading）⇒ 持有本控制器的页面
  /// 若在 listener 里 `setState`，就会报 “setState() called during build”
  /// （本项目 2026-10-08 实测过同一坑，见 `favorite_button.dart` 的 `_bind`）。
  /// ⇒ 与 web 的 `queueMicrotask(drain)`（`favoriteStatus.ts:127–130`）同拍：
  /// 只入队 + 排一个 microtask，build 结束后才真正发请求。
  void _scheduleAutoLoad(String targetType, String targetId) {
    if (_disposed) return;
    final String key = keyOf(targetType, targetId);
    if (!_autoLoadPending.add(key)) return; // 已排过 ⇒ 幂等（一屏 N 卡只多一个 microtask）
    scheduleMicrotask(() {
      _autoLoadPending.remove(key);
      if (_disposed) return;
      // 已被别的路径（页面 load / WS apply / 用户点击）填上 ⇒ 不必再查。
      if (_entries.containsKey(key)) return;
      unawaited(load(targetType, <String>[targetId]));
    });
  }

  /// 待惰性补加载的键（幂等去重；web 无此结构，纯 Flutter 侧时序需要）。
  final Set<String> _autoLoadPending = <String>{};

  /// 收藏 id（未查到 → null；已查到未收藏 → null）。用于收藏页的跳转/联动。
  int? favoriteIdOf(String targetType, String targetId) =>
      _entries[keyOf(targetType, targetId)]?.favoriteId;

  /// 操作失败文案（web 按钮内的 `actionError`）。
  String? actionErrorOf(String targetType, String targetId) =>
      _actionErrors[keyOf(targetType, targetId)];

  /// 是否正在切换收藏（web 按钮内的 `busy`）。
  bool busyOf(String targetType, String targetId) =>
      _busy.contains(keyOf(targetType, targetId));

  /// 条目代际（web `entries.get(key)?.revision`；未写入过 → null）。
  int? revisionOf(String targetType, String targetId) =>
      _entries[keyOf(targetType, targetId)]?.revision;

  /// 状态是否在**重新查询中**（web `state.loading` 与
  /// `FavoriteButton.tsx:69` 的禁用项之一）。
  bool loadingOf(String targetType, String targetId) =>
      _entries[keyOf(targetType, targetId)]?.loading ?? false;

  /// 当前引用计数（web `retained.get(key) ?? 0`；测试与诊断用）。
  int retainCountOf(String targetType, String targetId) =>
      _retained[keyOf(targetType, targetId)] ?? 0;

  /// 是否已查到过状态（web `favoriteId !== undefined`）。
  bool knownOf(String targetType, String targetId) =>
      _entries[keyOf(targetType, targetId)]?.known ?? false;

  /// **引用计数 retain**（web `retainFavoriteStatus`，
  /// `favoriteStatus.ts:63–73`）。
  ///
  /// 返回值 = release 回调（**幂等**：web 实现也只在计数 > 0 时递减，
  /// 多调一次只把计数夹在 0）。调用方在 `initState` retain、
  /// `dispose` release，即得 web `useFavoriteStatuses.ts:12–16`
  /// 的挂载语义 —— 收藏键因此可以自己加载自己。
  void Function() retain(String targetType, List<String> targetIds) {
    final List<String> keys = <String>[
      for (final String id in targetIds.toSet()) keyOf(targetType, id),
    ];
    for (final String key in keys) {
      _retained[key] = (_retained[key] ?? 0) + 1;
    }
    return () {
      for (final String key in keys) {
        final int count = (_retained[key] ?? 1) - 1;
        if (count > 0) {
          _retained[key] = count;
        } else {
          _retained.remove(key);
        }
      }
    };
  }

  /// 1024 条缓存淘汰（web `write` 内的 `favoriteStatus.ts:52–59`）：
  /// 只淘汰**不在途、且没有被任何组件 retain** 的**最早写入**条目。
  ///
  /// 与 web 的差别（登记）：web 在插入点做「边插边淘汰」；Flutter 侧 Map 的迭代序
  /// 天然是「首次写入序」⇒ 先写先淘汰，正是 web
  /// 「idle, off-screen cache entries are evictable」的语义。
  void _evict() {
    if (_entries.length <= cacheLimit) return;
    for (final String key in _entries.keys.toList()) {
      if (_entries.length <= cacheLimit) break;
      final AylaFavoriteEntryStatus? state = _entries[key];
      if (state == null || state.loading || _retained.containsKey(key)) continue;
      _entries.remove(key);
    }
  }

  /// 查询状态。[force] = 忽略新鲜期与在途标记（web `loadFavoriteStatuses(..., true)`）。
  ///
  /// 与 web 同为**入队语义**（`favoriteStatus.ts:116–130`）：只把 id 放进 [type] 的队列
  /// 并排一次 drain，之后由 [AylaFavoriteStatusController._drain] 合并成有界批量请求。
  /// Flutter 侧补回 `Future`：等**本批涉及的键**落盘后返回（状态语义不变）。
  Future<void> load(
    String targetType,
    List<String> targetIds, {
    bool force = false,
  }) async {
    if (_disposed) return;
    _syncScope();
    if (_disposed) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<Completer<void>> waiters = <Completer<void>>[];
    bool enqueued = false;
    Set<String>? pending = _queue[targetType];
    for (final String id in targetIds.toSet()) {
      final String key = keyOf(targetType, id);
      final AylaFavoriteEntryStatus current =
          _entries[key] ?? const AylaFavoriteEntryStatus();
      // web `:121` `if (current.loading || …) continue`（在途去重）。
      if (current.loading) {
        waiters.add(_waiterFor(key));
        continue;
      }
      if (!force &&
          current.known &&
          current.error == null &&
          now - current.updatedAt < freshFor.inMilliseconds) {
        continue;
      }
      // web `:122` `write(key, { ...current, loading: true, error: null, revision: ++revision })`
      _entries[key] = AylaFavoriteEntryStatus(
        known: current.known,
        favoriteId: current.favoriteId,
        loading: true,
        updatedAt: current.updatedAt,
        revision: ++_revision,
      );
      pending ??= _queue[targetType] ??= <String>{};
      pending.add(id);
      enqueued = true;
      waiters.add(_waiterFor(key));
    }
    if (waiters.isEmpty) return;
    // web `:127–130`：`scheduled` 去重 + `queueMicrotask(drain)`。
    if (enqueued && !_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_drain);
    }
    await Future.wait(<Future<void>>[
      for (final Completer<void> waiter in waiters) waiter.future,
    ]);
  }

  /// 登记一个「等该键本轮落盘」的 awaiter。
  Completer<void> _waiterFor(String key) {
    final Completer<void> waiter = Completer<void>();
    (_waiters[key] ??= <Completer<void>>[]).add(waiter);
    return waiter;
  }

  /// 本批 100 个 id 落盘后唤醒等待者（web 无此步，见 [load] 的说明）。
  void _completeWaiters(String targetType, List<String> ids) {
    for (final String id in ids) {
      final List<Completer<void>>? list = _waiters.remove(keyOf(targetType, id));
      if (list == null) continue;
      for (final Completer<void> waiter in list) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  /// 代际切换时唤醒全部等待者（web `queue.clear()` 的对应收尾）。
  void _completeAllWaiters() {
    final List<List<Completer<void>>> lists = _waiters.values.toList();
    _waiters.clear();
    for (final List<Completer<void>> list in lists) {
      for (final Completer<void> waiter in list) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  /// web `drain()`（`favoriteStatus.ts:81–114`）：并发上限 [concurrency]，
  /// 每次从队首类型取最多 [batchLimit] 个 id 发一批。
  void _drain() {
    _scheduled = false;
    while (_active < concurrency && _queue.isNotEmpty) {
      final MapEntry<String, Set<String>> first = _queue.entries.first;
      final String type = first.key;
      final Set<String> pending = first.value;
      final List<String> ids = pending.take(batchLimit).toList();
      for (final String id in ids) {
        pending.remove(id);
      }
      if (pending.isEmpty) _queue.remove(type);
      unawaited(_runBatch(type, ids));
    }
  }

  /// 单批请求落地（web `:88–112` 的 then/catch/finally）。
  Future<void> _runBatch(String targetType, List<String> ids) async {
    // web `:88` 的 `requestEpoch = epoch`：账号切换后响应作废。
    final int requestEpoch = aylaFavoriteScopeEpoch();
    // web `:89` 的 `expected`：**按 revision 快照**每个 id 的当前代际，
    // 回填时逐条比对 `current.revision === expected.get(id)`（`:99` / `:106`）——
    // 只要期间有任何更新的写入（WS / 收藏动作 / 重新查询）覆盖过该条，本次结果就丢弃。
    // ⚠️ 不能用 updatedAt 代替：同毫秒内的两次写入会撞值（本文件 2026-10-08 修正）。
    final Map<String, int> expected = <String, int>{
      for (final String id in ids)
        id: (_entries[keyOf(targetType, id)] ?? const AylaFavoriteEntryStatus())
            .revision,
    };
    _active += 1;
    try {
      final AylaFavoriteStatuses response = await _fetch(targetType, ids);
      if (_disposed || requestEpoch != aylaFavoriteScopeEpoch()) return;
      final bool incomplete = response.targetType != targetType ||
          ids.any((String id) => !response.statuses.containsKey(id));
      if (incomplete) throw StateError('收藏状态响应不完整，请重试');
      for (final String id in ids) {
        final String key = keyOf(targetType, id);
        final AylaFavoriteEntryStatus? current = _entries[key];
        if (current == null || current.revision != expected[id]) continue;
        _entries[key] = AylaFavoriteEntryStatus(
          known: true,
          favoriteId: response.statuses[id],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          revision: ++_revision,
        );
      }
    } catch (err) {
      if (_disposed || requestEpoch != aylaFavoriteScopeEpoch()) return;
      for (final String id in ids) {
        final String key = keyOf(targetType, id);
        final AylaFavoriteEntryStatus? current = _entries[key];
        if (current == null || current.revision != expected[id]) continue;
        _entries[key] = AylaFavoriteEntryStatus(
          known: current.known,
          favoriteId: current.favoriteId,
          error: err is Exception ? _messageOf(err) : '收藏状态加载失败',
          updatedAt: current.updatedAt,
          revision: ++_revision,
        );
      }
    } finally {
      // web `:108–112`：代际已变则**不递减**（`_syncScope` 已把它归零）。
      if (!_disposed && requestEpoch == aylaFavoriteScopeEpoch()) {
        _active -= 1;
        _evict();
        _completeWaiters(targetType, ids);
        _notify();
        _drain();
      }
    }
  }

  /// 切换收藏。状态未知/出错时退化为**重新拉取状态**（web 行为），不发收藏请求。
  Future<void> toggle(String targetType, String targetId) async {
    if (_disposed) return;
    _syncScope();
    final String key = keyOf(targetType, targetId);
    final AylaFavoriteEntryStatus current =
        _entries[key] ?? const AylaFavoriteEntryStatus();
    if (current.error != null || !current.known) {
      await load(targetType, <String>[targetId], force: true);
      return;
    }
    if (_busy.contains(key)) return;
    // web `FavoriteButton.tsx:41` 的 `requestRevision = state.revision`：
    // 请求期间若条目被**更新写入**（WS / 重新查询）覆盖 ⇒ 结果作废（favoriteStatus.ts:52）。
    final int requestRevision = current.revision;
    _busy.add(key);
    _actionErrors[key] = null;
    _notify();
    try {
      final int? favoriteId = current.favoriteId;
      int? next;
      if (favoriteId != null) {
        await _remove(favoriteId);
        next = null;
      } else {
        next = await _add(targetType, targetId);
      }
      if (_disposed) return;
      if ((_entries[key]?.revision ?? 0) != requestRevision) return;
      _entries[key] = AylaFavoriteEntryStatus(
        known: true,
        favoriteId: next,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        revision: ++_revision,
      );
    } catch (err) {
      if (_disposed) return;
      _actionErrors[key] =
          err is Exception ? _messageOf(err) : '收藏操作失败，请重试';
    } finally {
      if (!_disposed) {
        _busy.remove(key);
        _notify();
      }
    }
  }

  /// 直接写入状态（WS `favorite.changed` / 收藏页本地删除后对账用）。
  ///
  /// web `applyFavoriteStatus`（`favoriteStatus.ts:76–79`）：
  /// 新写入带自增 revision ⇒ **作废任何在途请求**对该目标的回填（`:75`）。
  void apply(String targetType, String targetId, int? favoriteId) {
    _syncScope();
    _entries[keyOf(targetType, targetId)] = AylaFavoriteEntryStatus(
      known: true,
      favoriteId: favoriteId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      revision: ++_revision,
    );
    _actionErrors.remove(keyOf(targetType, targetId));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _registry.remove(this);
    _retained.clear();
    _entries.clear();
    _queue.clear();
    _completeAllWaiters(); // 不让 `await load(...)` 的调用方永久挂起
    super.dispose();
  }

  static String _messageOf(Object err) {
    final String text = err.toString();
    // ApiException.toString() = "ApiException(<status>, <message>)" —— 取可读消息。
    final RegExpMatch? m =
        RegExp(r'^[A-Za-z]+((d+), (.*))$').firstMatch(text);
    return m == null ? text : m.group(2)!;
  }
}

/// **共享控制器单例** —— web 的模块级 `useFavoriteStatusStore`
/// （`favoriteStatus.ts:17`）。
///
/// ## 为什么必须是单例
/// web 的收藏状态**不是每键一份**：`entries` / `retained` / `queue` / `revision` /
/// `epoch` 全是 `favoriteStatus.ts` 的**模块级变量**，所有 `FavoriteButton` 共用
/// ⇒ ① 一屏 N 个收藏键经 drain 合并成**有界批量请求**（并发 2、每批 100、
/// `favoriteStatus.ts:81–125`）；② 任意一处写入（本键 toggle / WS `favorite.changed` /
/// 收藏页删除）立即广播给全部挂载的键（`:50–61 / 76–79`）。
///
/// Flutter 侧此前每个 `AylaFavoriteButton` 自建**私有**控制器 ⇒ 一屏 N 个键就是
/// N 份缓存 + N 个单点请求，既偏离 web 语义，也让「自给自足」变得昂贵。
/// 未显式传 `AylaFavoriteButton.controller` 时统一用本实例（顶层变量惰性初始化）。
///
/// ⚠️ 本实例**永不 dispose**（跟随进程生命周期，与 web 模块级 store 同）；
/// 组件卸载只 `release` 引用计数（`favoriteStatus.ts:63–73`）。
/// 需要隔离缓存时仍可显式传入自己的控制器（注入档 / 单测）。
final AylaFavoriteStatusController aylaSharedFavoriteStatusController =
    AylaFavoriteStatusController();
