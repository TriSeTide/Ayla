/// 帖子域帧桥 —— web `ws/chat.ts` 的 `post.*` 四条分支的 Flutter 等价物。
///
/// ## 为什么单独一件
/// 与 `core/ws/room_frames.dart` 同因：这四条帧走 **chat WS**（此前登记在
/// `kAylaChatWsOutOfBatchFrames` 里），效应跨两个域 —— 帖子 store（`state/posts_store.dart`）
/// 与群未读投影（`state/chat_state.dart` 的 [AylaChatState.adjustPostUnread] +
/// `bumpGroupActivity`）。集中成一件可被 chat WS 与测试共同驱动，也避免 `chat_ws.dart`
/// 反向依赖帖子域。
///
/// ## 逐条对应（web 事实源）
/// | 帧 | web | 本桥 |
/// |---|---|---|
/// | `post.created` | `chat.ts:766–791`（**REST 详情才权威**：帧只带简化字段；拉 `GET /posts/<id>/`
///   ⇒ upsert + `bumpGroups` ⇒ 非作者则可见群 **+1**） | [AylaPostsFramesBridge] 同 |
/// | `post.deleted` | `chat.ts:793–797`（`removePost(post_id)`；**不回退排序**、**不动未读**） | 同 |
/// | `post.updated` | `chat.ts:799–812`（同 created 的 REST 对账 + `bumpGroups`；**不动未读**） | 同 |
/// | `post.viewed` | `chat.ts:814–839`（`viewer_id == 本人` ⇒ `markViewedBatch` + 去重后按可见群 **−1**；否则只刷 `view_count`） | 同 |
///
/// ## 未读计数的两条调用点（web `chat.ts:779–788 / 826–835`）
/// 群未读帖子数只在 **WS** 上增减（浏览上报的 REST 响应**不**减红点）：
/// - `post.created`：非作者本人时，对 `post.allowed_group_ids` 每个群 **+1**，
///   并用 30s 窗口去重（后端对「归属群 + 白名单」可能重复广播，WS 重连 resume 也可能重放——
///   同一 postId 30s 内只计一次）；
/// - `post.viewed`（本人）：`markViewedBatch` 之外，按 `allowed_group_ids` 去重后每群 **−1**，
///   同样 30s 窗口去重。
///
/// ⚠️ **为什么本人分支要去重**：同一条浏览会被广播到「群组频道」+「本人频道」各一次
/// ⇒ 本人会收到 2 次（web 原话，`chat.ts:818–819`）。`view_count` 覆盖是幂等的、不受去重影响。
///
/// ## 去重窗口的载体（与 web 的有意差异，登记）
/// web 把两个 Map 放在 **模块级**（`chat.ts:43 / 66`，随页面生命周期存活）；
/// Flutter 侧放在**桥实例**上（`postsFramesBridgeProvider` 是容器级单例，登录期内唯一，
/// 登出随容器销毁）⇒ 语义等价：同一登录会话内同一 postId 只计一次。
/// 惰性清理同 web（`chat.ts:54–59 / 77–82`：超 200 条时删掉 2 倍窗口之前的旧条目）。
///
/// ## 纪律
/// - **403/404 一律静默**（web 原话：当前用户不可见或帖子已删除，忽略提示）——
///   不把「看不到」写成「不存在」；
/// - **账号守卫**：REST 往返期间账号变了就丢弃结果（与 `room_frames.dart` 同法）；
/// - 帧结构非法（缺 `post.id` / `post_id`）⇒ 直接忽略，不猜测。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/chat_state.dart';
import '../../state/posts_store.dart'
    show AylaPostTabCache, AylaPostsStore;
import '../api/posts_api.dart';
import '../models/post.dart' show AylaPost;
import '../net/dio_client.dart' show ApiException;
import 'chat_ws.dart';

/// 本桥**转正**的 4 条 `post.*` 帧（[kAylaChatWsOutOfBatchFrames] 7 → 3）。
const List<String> kAylaPostsFramesTurnedOn = <String>[
  'post.created',
  'post.deleted',
  'post.updated',
  'post.viewed',
];

/// `post.created` 幂等去重窗口（web `chat.ts:42` 的 `POST_CREATED_DEDUP_MS`）。
const int kAylaPostCreatedDedupMs = 30000;

/// `post.viewed` 本人已读去重窗口（web `chat.ts:65` 的 `POST_VIEWED_DEDUP_MS`）。
const int kAylaPostViewedDedupMs = 30000;

/// 去重 Map 的惰性清理阈值（web `chat.ts:55 / 78` 的 `size > 200`）。
const int kAylaPostDedupSweepSize = 200;

/// 帖子帧桥（挂在 chat WS 的 `onFrame` 上；单例由 provider 持有）。
class AylaPostsFramesBridge {
  AylaPostsFramesBridge({
    required AylaPostsStore postsStore,
    required AylaChatState chatState,
    required String? Function() currentUserId,
    int Function()? now,
    AylaPostTabCache? postTabCache,
  })  : _posts = postsStore,
        _chat = chatState,
        _currentUserId = currentUserId,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _postTabCache = postTabCache;

  final AylaPostsStore _posts;
  final AylaChatState _chat;
  final String? Function() _currentUserId;

  /// **一级帖子页的 tab 分页快照缓存**（web 模块级 `postTabPages`，`PostsHubPage.tsx:77`）。
  ///
  /// ⚠️ **2026-10-20 全量普查修复 —— 用户实报「群外发帖刷不出来、群内可以」的根因**。
  ///
  /// 这份缓存与 [AylaPostsStore] 是**两份不同的数据**：
  /// - [AylaPostsStore]：全局信息流（群内帖子页 / 主页活动源读它）—— 本桥**早已**维护；
  /// - [AylaPostTabCache]：**一级帖子页**的 tab 分页快照（不在全局 store 里）——
  ///   修复前**只有页面自己**挂在 `chat.onFrame` 上的监听会更新它。
  ///
  /// 页面一被导航走（发帖后 `context.go` 跳详情页、切到别的 tab……），那个监听就
  /// `unregister` ⇒ 期间到达的 `post.created` **全部丢失**；返回列表时又命中
  /// `shouldLoad` 的 60 秒新鲜窗口 ⇒ **不重拉** ⇒ 新帖不出现。
  ///
  /// web 侧同病（`chatWS.onFrame` 同样在 `useEffect` 里、随卸载解绑）——
  /// 按要求在 Flutter 侧**补上全局写法**（比 web 更正确）：帧桥持有缓存引用，
  /// 页面挂不挂载都能维护它。
  final AylaPostTabCache? _postTabCache;

  /// 时钟注入口（测试用；生产恒为 `DateTime.now`）。
  final int Function() _now;

  /// `postId → 最近一次处理时间(ms)`（web `postCreatedHandledAt`，`chat.ts:43`）。
  final Map<int, int> _postCreatedHandledAt = <int, int>{};

  /// 同上，本人已读（web `postViewedHandledAt`，`chat.ts:66`）。
  final Map<int, int> _postViewedHandledAt = <int, int>{};

  void Function()? _off;

  /// 挂到 chat WS 上（幂等）。
  void attach(AylaChatWsClient chat) {
    _off?.call();
    _off = chat.onFrame(handleFrame);
  }

  /// 解绑（登出/测试收尾）。
  void detach() {
    _off?.call();
    _off = null;
  }

  /// 处理一帧（测试可直接投喂）。
  void handleFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    switch (rawType) {
      case 'post.created':
      case 'post.updated':
        // web 766–791 / 799–812：帧只带简化字段 ⇒ 以**权限 REST 详情**为权威
        // （作者/可见群/「images」），拉回来 upsert。
        // ⚠️ 两条帧的差别只在**未读**：只有 created 对非作者 +1（见 [_reconcilePost]）。
        unawaited(_reconcilePost(frame, bumpUnread: rawType == 'post.created'));
      case 'post.deleted':
        // web 793–797：删除**不回退排序**（卡片保持在原位置）—— removePost 只去掉条目。
        // web 此分支**不动未读**（红点由 viewed / 会话摘要持久化承担）⇒ 本桥同。
        final int? postId = _postIdOf(frame, fromPost: false);
        if (postId == null) return;
        _posts.removePost(postId);
        // 一级帖子页的 tab 快照同步摘除（web `PostsHubPage.tsx:237–241` 的
        // `removeFromAllTabs`；页面未挂载时同样要摘，否则切回旧 tab 会复活已删帖）。
        _postTabCache?.removeFromAllTabs(postId);
      case 'post.viewed':
        _applyViewed(frame);
      default:
        return;
    }
  }

  /// `post.created` / `post.updated`：拉 REST 详情 → upsert → bump 可见群活跃度
  /// （web `chat.ts:772–790 / 805–811`）。
  ///
  /// [bumpUnread] = true 时（**仅 `post.created`**）再走未读 +1：
  /// web 只在 created 分支里 `adjustPostUnread`（`chat.ts:779–788`），
  /// `post.updated` 不碰未读（编辑不算新帖）。
  Future<void> _reconcilePost(
    Map<String, dynamic> frame, {
    required bool bumpUnread,
  }) async {
    final int? postId = _postIdOf(frame, fromPost: true);
    if (postId == null) return;
    final String? actor = _currentUserId();
    try {
      final AylaPost? post = await AylaPostsApi.getPost(postId);
      if (actor != _currentUserId()) return;
      // `getPost` 对非法响应返回 null（`core/api/posts_api.dart:77–81`）——
      // 拿到 null 说明响应形状不合法，**不伪造**一条帖子。
      if (post == null) return;
      _posts.upsertPost(post);
      _bumpGroups(_visibleGroupIds(post));
      // 一级帖子页的 tab 快照同步合并（web `PostsHubPage.tsx:245–261` 的 `update(...)`：
      // 已存在则原位替换、不存在则插到头部）。**关键**：这里在帧桥做，
      // 页面挂不挂载都生效 —— 修复前只有页面级监听会做，导航期间到达的帧会丢。
      _mergeIntoPostTabs(post);
      if (!bumpUnread) return;
      // ---- 群未读帖子数 +1（web 779–788）----
      // 作者自己发的帖子天然已读 ⇒ 不计（`docs/post_views_read_state.md`）。
      // `me` 为空（未登录/已登出）时 web 同样跳过（`if (me && …)`）。
      final String? me = _currentUserId();
      if (me == null || me.isEmpty) return;
      if (post.authorId == me) return;
      // 幂等：同一 postId 的重复事件（后端归属群+白名单重复广播 / WS 重放）只计一次。
      if (_markPostCreatedHandled(postId)) return;
      // ⚠️ web 用的是 **allowed_group_ids 白名单**（不是 visibleGroupIds 的并集）
      // —— `chat.ts:784` 原话。两者在「归属群也在白名单」时同值，但归属群**不在**白名单的
      // 情形只有白名单会 +1（与后端 `allowed_groups` 的可见性判据一致）。
      for (final String gid in _dedupNonEmpty(post.allowedGroupIds)) {
        _chat.adjustPostUnread(gid, 1);
      }
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或帖子已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// 测试入口：直接驱动「合并进 tab 快照」这一步（等价 `post.created` 的 REST 对账成功后的落点）。
  @visibleForTesting
  void mergePostIntoTabsForTest(AylaPost post) => _mergeIntoPostTabs(post);

  /// 把一条帖子合并进一级帖子页的 tab 快照（web `PostsHubPage.tsx:245–261`）。
  ///
  /// 未注入缓存（单元测试/极端装配）时静默跳过 —— 不伪造，也不因此中断后面的未读逻辑。
  void _mergeIntoPostTabs(AylaPost post) {
    // 传当前用户：帧桥负责按 tab 口径过滤（「我的」档只收自己的、
    // 「好友」档不在本层判、`public` 档看 visibility）—— 见 mergeIntoAllTabs 注释。
    _postTabCache?.mergeIntoAllTabs(post, currentUserId: _currentUserId());
  }

  /// `post.viewed`（web `chat.ts:814–839`）：
  /// - `viewer_id == 本人` ⇒ [AylaPostsStore.markViewedBatch]（同步已读态）
  ///   **并**按可见群去重后 [AylaChatState.adjustPostUnread](-1)（红点递减）；
  /// - 否则 ⇒ [AylaPostsStore.updatePostViewCount]（只刷浏览量）。
  ///
  /// `view_count` **不去重**（web 原话：幂等覆盖，不受去重影响）。
  void _applyViewed(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final int? postId = int.tryParse(data['post_id']?.toString() ?? '');
    final int? viewCount = (data['view_count'] as num?)?.toInt();
    if (postId == null || viewCount == null) return;
    final String me = _currentUserId() ?? '';
    final String viewer = data['viewer_id']?.toString() ?? '';
    if (me.isNotEmpty && viewer == me) {
      _posts.markViewedBatch(<String, int>{postId.toString(): viewCount});
      // ---- 群未读红点 −1（web 826–835）----
      // 同一条浏览会同时广播到群组频道与本人频道 ⇒ 本人收到 2 次，
      // 递减按 postId 去重（只减一次）；`view_count` 的覆盖不受影响。
      if (_markPostViewedHandled(postId)) return;
      // web 原话：`const touched = new Set<string>()` —— 同一帧里重复的群只减一次。
      for (final String gid in _dedupNonEmpty(_stringList(data['allowed_group_ids']))) {
        _chat.adjustPostUnread(gid, -1);
      }
    } else {
      _posts.updatePostViewCount(postId, viewCount);
    }
  }

  /// 一段可见群 id 的活跃度 bump（web `bumpGroups`，`chat.ts:115–118`）。
  void _bumpGroups(List<String> ids) {
    for (final String id in ids) {
      _chat.bumpGroupActivity(id);
    }
  }

  /// 从「归属群 + 白名单群」提取可见群 id（web `visibleGroupIds`，`chat.ts:102–112`）：
  /// 去重、过滤空值。
  ///
  /// ⚠️ 与 web 的**有意差异**：web 的白名单来自 `post.allowed_group_ids`（可能含
  /// `null`，故有 `if (id != null)`）；Flutter 的 [AylaPost.allowedGroupIds] 是
  /// **非空字符串列表**（`fromJson` 已过滤 `item is String && item.isNotEmpty`，
  /// `core/models/post.dart:342–348`）⇒ 这里只需 `isNotEmpty` 兜底。
  /// `group` 一档两边同：web 判 `if (descriptor.group)`（空串为假），Flutter 用 `isNotEmpty`。
  static List<String> _visibleGroupIds(AylaPost post) {
    final Set<String> ids = <String>{};
    final String? group = post.groupId;
    if (group != null && group.isNotEmpty) ids.add(group);
    for (final String id in post.allowedGroupIds) {
      if (id.isNotEmpty) ids.add(id);
    }
    return ids.toList(growable: false);
  }

  // ======================= 两个 30s 去重窗口（web chat.ts:41–83） =======================

  /// `post.created` 幂等去重：返回 **true 表示本次是重复事件**（已处理过，不再计未读）。
  ///
  /// 与 web 逐行同：命中窗口内会**刷新时间戳**（滑动窗口，`chat.ts:50`），
  /// 并在条目数超 [kAylaPostDedupSweepSize] 时惰性清理 `2 × 窗口` 之前的旧条目。
  bool _markPostCreatedHandled(int postId) =>
      _markHandled(_postCreatedHandledAt, postId, kAylaPostCreatedDedupMs);

  /// `post.viewed` 本人已读去重：返回 **true 表示红点递减已处理过**。
  bool _markPostViewedHandled(int postId) =>
      _markHandled(_postViewedHandledAt, postId, kAylaPostViewedDedupMs);

  bool _markHandled(Map<int, int> table, int postId, int windowMs) {
    final int now = _now();
    final int? last = table[postId];
    if (last != null && now - last < windowMs) {
      table[postId] = now; // 命中窗口内刷新时间戳（web 同）
      return true;
    }
    table[postId] = now;
    if (table.length > kAylaPostDedupSweepSize) {
      final int cutoff = windowMs * 2;
      table.removeWhere((int _, int at) => now - at > cutoff);
    }
    return false;
  }

  /// 帧里的 `allowed_group_ids` / 帖子白名单：只取非空字符串并**去重**（保持首次出现顺序）。
  ///
  /// web 在 `post.viewed` 里用 `Set` 去重（`chat.ts:828–833`）；
  /// `post.created` 直接遍历白名单数组（同群只出现一次 ⇒ 无需去重，
  /// 这里统一走同一函数，对 created 是等价无副作用的）。
  static List<String> _dedupNonEmpty(List<String> ids) {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final String id in ids) {
      if (id.isEmpty) continue;
      if (seen.add(id)) out.add(id);
    }
    return out;
  }

  /// 把帧里的 JSON 数组安全转成 `List<String>`（非字符串/嵌套结构一律丢弃，不猜语义）。
  static List<String> _stringList(Object? raw) => <String>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is String) item,
      ];

  /// 取帧里的帖子 id。
  ///
  /// `fromPost`：`post.created` / `post.updated` 的 id 在 `frame.post.id`
  /// （`api/types.ts:753–782`）；`post.deleted` 的 id 是**顶层** `frame.post_id`
  /// （`api/types.ts:766–769`）。
  static int? _postIdOf(Map<String, dynamic> frame, {required bool fromPost}) {
    if (fromPost) {
      final Object? post = frame['post'];
      if (post is! Map) return null;
      return int.tryParse(post['id']?.toString() ?? '');
    }
    return int.tryParse(frame['post_id']?.toString() ?? '');
  }
}
