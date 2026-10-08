/// 帖子信息流共享 store —— web `stores/posts.ts`（151 行）**信息流部分**的 Flutter 等价物。
///
/// ## 为什么需要它
/// web 的帖子流是全站共享的：`appInit.ts:38` 登录后预取 `listPosts({ scope: "feed", limit: 20 })`
/// 并 `setPage(...)` 落地（`appInit.ts:42`），`PostsHubPage` 进入时读同一份并带
/// `isPostsStale()` 判定（`stores/posts.ts:146–151`，默认 60 秒）⇒ 切页面不重复加载。
/// Flutter 侧原实现是页面私有的 `AylaPagedList`（每次进入重新取页），
/// 该缺口已在 `pages/posts_hub_page.dart` 文件头「机制差异 2」登记，本次补齐。
///
/// ## 逐条对应的 web 语义
/// | web | 行 | 本件 |
/// |---|---|---|
/// | 字段 `posts` / `nextCursor` / `hasMore` / `loading` / `error` / `scope` / `lastFetched` | 13–21 | [AylaPostsStore] 同名字段 |
/// | `setPage`（重置列表 + `lastFetched = Date.now()`） | 59–60 | [AylaPostsStore.setPage] |
/// | `appendPage`（按 `id` 去重追加） | 62–67 | [AylaPostsStore.appendPage] |
/// | `setLoading` / `setError`（error 同时收 loading） | 69–70 | 同 |
/// | `setScope`（换 scope **清空列表与游标**） | 71 | 同 |
/// | `reset` | 133–143 | 同（不含 favoriteByPostId，见「未实现」） |
/// | `isPostsStale(maxAgeMs = 60_000)` | 146–151 | [AylaPostsStore.isStale] / [kAylaPostsFreshWindowMs] |
///
/// ## WS 增量四件套（web 92–131）**已接**（2026-10-01）
/// `upsertPost` / `removePost` / `markViewedBatch` / `updatePostViewCount` 四条
/// 由 `core/ws/posts_frames.dart` 的 [AylaPostsFramesBridge]（chat WS 的 `post.*` 帧）
/// 与页面（浏览上报）共同消费。四条的语义逐条对齐 web：
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `upsertPost`（已存在**原位替换**、不存在**插到列表头部**） | 92–106 | [AylaPostsStore.upsertPost] |
/// | `removePost`（**不回退排序**） | 108–111 | [AylaPostsStore.removePost] |
/// | `markViewedBatch`（空 map **早退**；命中项写 `is_viewed=true` + `view_count`） | 113–124 | [AylaPostsStore.markViewedBatch] |
/// | `updatePostViewCount`（只刷 `view_count`，**不**标已读） | 126–131 | [AylaPostsStore.updatePostViewCount] |
///
/// ## 未实现（登记）
/// 1. **`favoriteByPostId` / `setFavorite` / `loadFavorites`**（web 73–90）—— Flutter 侧
///    收藏态由 `state/favorite_status.dart`（`AylaFavoriteStatusController`）承担，
///    页面按 `stateOf('post', key)` 取，不在此重复一份事实。
library;

import 'package:flutter/foundation.dart';

import '../core/models/post.dart' show AylaPost;
import 'paged_list.dart' show AylaPageRequest, AylaPagedList;

/// 信息流缓存窗口（web `isPostsStale` 默认 `60_000`，`stores/posts.ts:147`）。
const int kAylaPostsFreshWindowMs = 60000;

/// 帖子信息流共享 store（web `usePostsStore` 的信息流部分）。
class AylaPostsStore extends ChangeNotifier {
  List<AylaPost> _posts = <AylaPost>[];
  String? _nextCursor;
  bool _hasMore = false;
  bool _loading = false;
  String? _error;
  String _scope = 'feed';
  int? _lastFetched;

  /// 已加载的帖子（顺序即服务端顺序）。
  List<AylaPost> get posts => List<AylaPost>.unmodifiable(_posts);

  String? get nextCursor => _nextCursor;

  bool get hasMore => _hasMore;

  bool get loading => _loading;

  String? get error => _error;

  /// 当前信息流作用域（web `PostScope`：`feed` / `mine` / `group:<id>`）。
  String get scope => _scope;

  /// 最近一次成功落地的时间（毫秒；null = 从未取到）。
  int? get lastFetched => _lastFetched;

  /// 是否已取到过数据（决定首屏骨架 vs 列表）。
  bool get loaded => _lastFetched != null;

  /// 首屏（重置列表）—— web `setPage`（59–60）。
  void setPage(List<AylaPost> posts, String? nextCursor, bool hasMore) {
    _posts = List<AylaPost>.unmodifiable(posts);
    _nextCursor = nextCursor;
    _hasMore = hasMore;
    _loading = false;
    _error = null;
    _lastFetched = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// 追加下一页（按 id 去重）—— web `appendPage`（62–67）。
  void appendPage(List<AylaPost> posts, String? nextCursor, bool hasMore) {
    final Set<int> seen = <int>{for (final AylaPost p in _posts) p.id};
    _posts = List<AylaPost>.unmodifiable(<AylaPost>[
      ..._posts,
      for (final AylaPost p in posts)
        if (seen.add(p.id)) p,
    ]);
    _nextCursor = nextCursor;
    _hasMore = hasMore;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  void setLoading(bool loading) {
    if (_loading == loading) return;
    _loading = loading;
    notifyListeners();
  }

  /// web `setError`：写错误的同时收起 loading（70）。
  void setError(String? error) {
    _error = error;
    _loading = false;
    notifyListeners();
  }

  /// 切换作用域 —— web `setScope`（71）：**清空列表与游标**。
  void setScope(String scope) {
    if (_scope == scope) return;
    _scope = scope;
    _posts = <AylaPost>[];
    _nextCursor = null;
    _hasMore = false;
    notifyListeners();
  }

  /// WS / 目录落地：插入或更新帖子 —— web `upsertPost`（92–106）。
  ///
  /// **已存在则原位替换**（保持它在列表中的位置）；**不存在则插入到列表头部**
  /// （「最新优先」，web 101–104 的注释原话）。
  ///
  /// ⚠️ [AylaPost] 是 `const` 全 `final` 的不可变模型（无 `copyWith`）⇒ 这里按
  /// web 一样**整条替换**（web 也是 `posts.map(p => p.id === post.id ? post : p)`），
  /// 不做字段级合并 —— 语义与 web 一致（REST 详情才是权威，帧只带简化字段）。
  void upsertPost(AylaPost post) {
    final int index = _posts.indexWhere((AylaPost p) => p.id == post.id);
    if (index >= 0) {
      final List<AylaPost> next = List<AylaPost>.of(_posts);
      next[index] = post;
      _posts = List<AylaPost>.unmodifiable(next);
    } else {
      _posts = List<AylaPost>.unmodifiable(<AylaPost>[post, ..._posts]);
    }
    notifyListeners();
  }

  /// WS 推送：从列表移除 —— web `removePost`（108–111）。
  ///
  /// **不回退排序**：只从列表里去掉条目，其余顺序不动（web `chat.ts:795` 的注释原话）。
  void removePost(int postId) {
    final int length = _posts.length;
    final List<AylaPost> next = <AylaPost>[
      for (final AylaPost p in _posts)
        if (p.id != postId) p,
    ];
    if (next.length == length) return;
    _posts = List<AylaPost>.unmodifiable(next);
    notifyListeners();
  }

  /// 浏览上报成功后批量落地（浏览与已读同源）—— web `markViewedBatch`（113–124）。
  ///
  /// `updated` = `{post_id(字符串) → 最新 view_count}`；命中项写 `is_viewed = true`
  /// 并把 `view_count` 覆盖为**最新值**（幂等覆盖，不是累加）。
  /// **空 map 早退**（web 115–116：`if (ids.size === 0) return state`）——
  /// 不触发一次无意义的重渲染。
  void markViewedBatch(Map<String, int> updated) {
    if (updated.isEmpty) return;
    final Set<int> ids = <int>{
      for (final String key in updated.keys)
        if (int.tryParse(key) case final int id) id,
    };
    if (ids.isEmpty) return;
    _posts = List<AylaPost>.unmodifiable(<AylaPost>[
      for (final AylaPost p in _posts)
        if (ids.contains(p.id)) _withViewed(p, updated['${p.id}']) else p,
    ]);
    notifyListeners();
  }

  /// WS `post.viewed`（**他人**浏览）：只刷新 `view_count`，**不**标记本人已读
  /// —— web `updatePostViewCount`（126–131）。
  void updatePostViewCount(int postId, int viewCount) {
    final int index = _posts.indexWhere((AylaPost p) => p.id == postId);
    if (index < 0) return;
    final List<AylaPost> next = List<AylaPost>.of(_posts);
    next[index] = _withViewCount(next[index], viewCount);
    _posts = List<AylaPost>.unmodifiable(next);
    notifyListeners();
  }

  /// 数据是否过期（web `isPostsStale`，146–151）。
  bool isStale({int maxAgeMs = kAylaPostsFreshWindowMs}) {
    final int? lastFetched = _lastFetched;
    if (lastFetched == null) return true;
    return DateTime.now().millisecondsSinceEpoch - lastFetched > maxAgeMs;
  }

  /// 登出 / 会话过期清空（web `reset`，133–143）。
  void reset() {
    _posts = <AylaPost>[];
    _nextCursor = null;
    _hasMore = false;
    _loading = false;
    _error = null;
    _scope = 'feed';
    _lastFetched = null;
    notifyListeners();
  }
}

/// 模块级单例 —— web `usePostsStore`（`stores/posts.ts:49`）的模块级 store 语义：
/// `appInit` 预加载与帖子页共用同一实例。
final AylaPostsStore aylaPostsStore = AylaPostsStore();

/// `is_viewed = true` + `view_count` 覆盖 —— web `markViewedBatch` 的
/// `{ ...p, is_viewed: true, view_count: updated[String(p.id)] ?? p.view_count }`（118–122）。
///
/// ⚠️ [AylaPost] 无 `copyWith`（`core/models/post.dart` 是纯 `const` 模型），
/// 且模型属**共享领域件**（本轮不动它有意的不可变形态）⇒ 这里在**本文件内**用
/// 「重建实例」表达；`viewCount` 缺席时保留原值（web 的 `??` 链同义）。
AylaPost _withViewed(AylaPost post, int? viewCount) => AylaPost(
      id: post.id,
      author: post.author,
      authorId: post.authorId,
      authorNickname: post.authorNickname,
      title: post.title,
      body: post.body,
      visibility: post.visibility,
      groupId: post.groupId,
      groupName: post.groupName,
      allowedGroupIds: post.allowedGroupIds,
      allowedGroupNames: post.allowedGroupNames,
      images: post.images,
      commentCount: post.commentCount,
      isAuthor: post.isAuthor,
      viewCount: viewCount ?? post.viewCount,
      isViewed: true,
      createdAt: post.createdAt,
      updatedAt: post.updatedAt,
    );

/// 只覆盖 `view_count` —— web `updatePostViewCount` 的
/// `{ ...p, view_count: viewCount }`（128–130）。
AylaPost _withViewCount(AylaPost post, int viewCount) => AylaPost(
      id: post.id,
      author: post.author,
      authorId: post.authorId,
      authorNickname: post.authorNickname,
      title: post.title,
      body: post.body,
      visibility: post.visibility,
      groupId: post.groupId,
      groupName: post.groupName,
      allowedGroupIds: post.allowedGroupIds,
      allowedGroupNames: post.allowedGroupNames,
      images: post.images,
      commentCount: post.commentCount,
      isAuthor: post.isAuthor,
      viewCount: viewCount,
      isViewed: post.isViewed,
      createdAt: post.createdAt,
      updatedAt: post.updatedAt,
    );

/// 帖子页「每 tab 独立分页缓存」—— web `postTabPages`
/// （`pages/PostsHubPage.tsx:76–87`）的 Flutter 等价物。
///
/// ## 与 [AylaPostsStore] 的分工（web 同构）
/// - [AylaPostsStore] = 全站帖子信息流 store（web `usePostsStore`）：`appInit` 预加载落地、
///   群内帖子（`GroupPosts.tsx:78`）读它；
/// - **本件** = 一级帖子页自己的**每 tab 分页快照**（web `postTabPages`）：一级帖子页
///   **不读** `usePostsStore`（`PostsHubPage.tsx:98–101` 从 `postTabPages` 恢复 `useState`）。
///
/// ## 逐条对应的 web 语义
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `const postTabPages = new Map<string, PostTabState>()`（模块级、跨挂载保留） | 77 | [_pagers] / [_updatedAt] |
/// | `scope = \`posts:${account}:${filter}\`` | 97 | [AylaPostTabCache.keyFor] |
/// | 切 tab / 重挂载：`cached ? {...cached, loading:false} : emptyPostTab()` | 98–101·148–151 | [AylaPostTabCache.acquire]（复用同一 pager 实例 ⇒ items/cursor/loaded 保留） |
/// | **`loaded && Date.now() - updatedAt < 60_000 ⇒ 不重拉`** | **224** | [AylaPostTabCache.shouldLoad] |
/// | 成功落地写 `updatedAt: Date.now()` | 193·200 | [AylaPostTabCache.markUpdated] |
/// | 账号切换 ⇒ `postTabSession += 1` + `postTabPages.clear()` | 79–86 | [AylaPostTabCache.clear]（登出链调用） |
/// | 缓存上限（`while (size > 14) delete 最旧`） | 138 | [maxTabs] |
///
/// ## 位置说明（与 web 的差异，有意）
/// web 把该 Map 放在**页面模块**里；Flutter 侧放在 state 层，理由是登出 / 会话过期
/// （`main.dart` 的 `onSessionExpired`、`app_shell` 的登出）需要一处可达的清空入口。
/// 结构与语义逐条同 web。
class AylaPostTabCache {
  /// 首屏复用窗口（web `PostsHubPage.tsx:224` 的 `60_000`）。
  static const int freshWindowMs = 60000;

  /// 缓存 tab 上限（web `:138` 的 `while (postTabPages.size > 14)`）。
  static const int maxTabs = 14;

  final Map<String, AylaPagedList<AylaPost>> _pagers =
      <String, AylaPagedList<AylaPost>>{};
  final Map<String, int> _updatedAt = <String, int>{};

  /// 取页实现覆盖（依赖注入点；**生产恒为 null** ⇒ 页面走真实 `AylaPostsApi.listPosts`，
  /// 测试注入成功响应以验证「二次进入不重拉」——仓内约定不 mock HTTP）。
  AylaPageRequest<AylaPost>? requestOverride;

  /// tab key（web `scope`，`PostsHubPage.tsx:97`）：`posts:{account}:{filter}`。
  static String keyFor({required String account, required String filter}) =>
      'posts:$account:$filter';

  /// 取（或建）该 tab 的分页状态机；命中即**复用同一实例**（跨挂载保留 items/cursor）。
  AylaPagedList<AylaPost> acquire(
    String key, {
    required AylaPagedList<AylaPost> Function() create,
  }) {
    final AylaPagedList<AylaPost>? cached = _pagers[key];
    if (cached != null) return cached;
    final AylaPagedList<AylaPost> pager = create();
    _pagers[key] = pager;
    _evictOverflow();
    return pager;
  }

  /// 是否该拉首页（web `:224`：`loaded && now - updatedAt < 60_000` ⇒ **false**）。
  bool shouldLoad(String key) {
    final AylaPagedList<AylaPost>? pager = _pagers[key];
    final int? updatedAt = _updatedAt[key];
    if (pager == null || updatedAt == null) return true;
    if (!pager.loaded) return true;
    return DateTime.now().millisecondsSinceEpoch - updatedAt >= freshWindowMs;
  }

  /// 成功落地后打时间戳（web `:193·200`）。
  void markUpdated(String key) {
    _updatedAt[key] = DateTime.now().millisecondsSinceEpoch;
  }

  /// 该 tab 当前实例（无则 null）。
  AylaPagedList<AylaPost>? pagerOf(String key) => _pagers[key];

  /// 从**全部 tab** 的已加载投影里摘掉一条帖子 ——
  /// web `PostsHubPage.tsx:237–241`：
  /// ```ts
  /// for (const [key, cached] of postTabPages) {
  ///   if (!key.startsWith(`posts:${account}:`)) continue;
  ///   postTabPages.set(key, { ...cached, posts: cached.posts.filter((p) => p.id !== postId) });
  /// }
  /// ```
  /// 「避免切回旧 tab 时复活已删帖」。
  ///
  /// ⚠️ 账号维度由「缓存整体随登出清空」（[clear]）承担 —— Flutter 侧不跨账号共享
  /// 缓存实例（`AylaPostTabCache` 是模块级单例，但 `clear()` 在登出链上调），
  /// 因此这里不需要 web 的 `startsWith(`posts:${account}:`)` 前缀过滤。
  /// 快照只动 `items`，**不动游标 / hasMore**（同 web：只重写 posts 字段）。
  void removeFromAllTabs(int postId) {
    for (final AylaPagedList<AylaPost> pager in _pagers.values) {
      if (!pager.items.any((AylaPost p) => p.id == postId)) continue;
      pager.setItems(<AylaPost>[
        for (final AylaPost p in pager.items)
          if (p.id != postId) p,
      ]);
    }
  }

  /// 清空（登出 / 会话过期 / 账号切换；web `postTabSession` 机制）。
  void clear() {
    for (final AylaPagedList<AylaPost> pager in _pagers.values) {
      pager.dispose();
    }
    _pagers.clear();
    _updatedAt.clear();
  }

  void _evictOverflow() {
    while (_pagers.length > maxTabs) {
      final String oldest = _pagers.keys.first;
      _pagers.remove(oldest)?.dispose();
      _updatedAt.remove(oldest);
    }
  }
}

/// 模块级单例（与 [aylaPostsStore] 同层；见 [AylaPostTabCache] 的「位置说明」）。
final AylaPostTabCache aylaPostTabCache = AylaPostTabCache();
