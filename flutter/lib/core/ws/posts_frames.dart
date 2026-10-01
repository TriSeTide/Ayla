/// 帖子域帧桥 —— web `ws/chat.ts` 的 `post.*` 四条分支的 Flutter 等价物。
///
/// ## 为什么单独一件
/// 与 `core/ws/room_frames.dart` 同因：这四条帧走 **chat WS**（此前登记在
/// `kAylaChatWsOutOfBatchFrames` 里），效应跨两个域 —— 帖子 store（`state/posts_store.dart`）
/// 与群「新内容」排序（`state/chat_state.dart` 的 `bumpGroupActivity`）。
/// 集中成一件可被 chat WS 与测试共同驱动，也避免 `chat_ws.dart` 反向依赖帖子域。
///
/// ## 逐条对应（web 事实源）
/// | 帧 | web | 本桥 |
/// |---|---|---|
/// | `post.created` | `chat.ts:766–791`（**REST 详情才权威**：帧只带简化字段；拉 `GET /posts/<id>/` ⇒ upsert + `bumpGroups`） | [AylaPostsFramesBridge] 同 |
/// | `post.deleted` | `chat.ts:793–797`（`removePost(post_id)`；**不回退排序**） | 同 |
/// | `post.updated` | `chat.ts:799–812`（同 created 的 REST 对账；**不在 updated 里 bump 未读**） | 同 |
/// | `post.viewed` | `chat.ts:814–839`（`viewer_id == 本人` ⇒ `markViewedBatch`；否则 `updatePostViewCount`） | 同 |
///
/// ## 未实现（登记，**不伪造**）
/// 1. **`adjustPostUnread`（群未读帖子数）**：web 在 `post.created`（779–788）与
///    `post.viewed`（826–835）里对可见群加减未读；Flutter 侧 `AylaChatState`
///    **没有** `adjustPostUnread`（`state/chat_state.dart:18` 已登记为「属帖子域批次，
///    届时补」）⇒ 本轮**仍不实现**，不写假投影。随之而来：web 的
///    `markPostCreatedHandled` / `markPostViewedHandled` 两个 30s 去重窗口
///    （`chat.ts:41–83`）**唯一作用就是给「未读只减一次」去重**，未实现未读计数时
///    没有可去重的对象 ⇒ **不搬过来**（搬了就是死代码，且会让人误以为未读已接）。
///    待 `adjustPostUnread` 落地时按 web 一起补（含两个 Map 与惰性清理）。
/// 2. **`comment.*` / `favorite.changed`**：不在本桥范围（前者 web 本身是 no-op、
///    由帖子详情页的 `onFrame` 消费；后者属收藏状态收敛轮）⇒ 仍留在
///    [kAylaChatWsOutOfBatchFrames] 里显式登记。
///
/// ## 纪律
/// - **403/404 一律静默**（web 原话：当前用户不可见或帖子已删除，忽略提示）——
///   不把「看不到」写成「不存在」；
/// - **账号守卫**：REST 往返期间账号变了就丢弃结果（与 `room_frames.dart` 同法）；
/// - 帧结构非法（缺 `post.id` / `post_id`）⇒ 直接忽略，不猜测。
library;

import 'dart:async';

import '../../state/chat_state.dart';
import '../../state/posts_store.dart' show AylaPostsStore;
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

/// 帖子帧桥（挂在 chat WS 的 `onFrame` 上；单例由 provider 持有）。
class AylaPostsFramesBridge {
  AylaPostsFramesBridge({
    required AylaPostsStore postsStore,
    required AylaChatState chatState,
    required String? Function() currentUserId,
  })  : _posts = postsStore,
        _chat = chatState,
        _currentUserId = currentUserId;

  final AylaPostsStore _posts;
  final AylaChatState _chat;
  final String? Function() _currentUserId;

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
        unawaited(_reconcilePost(frame));
      case 'post.deleted':
        // web 793–797：删除**不回退排序**（卡片保持在原位置）—— removePost 只去掉条目。
        final int? postId = _postIdOf(frame, fromPost: false);
        if (postId == null) return;
        _posts.removePost(postId);
      case 'post.viewed':
        _applyViewed(frame);
      default:
        return;
    }
  }

  /// `post.created` / `post.updated`：拉 REST 详情 → upsert → bump 可见群活跃度
  /// （web `chat.ts:772–790 / 805–811`）。
  ///
  /// ⚠️ `post.updated` **不** bump 未读（web 只在 created 里 `adjustPostUnread`）；
  /// 本桥两档都只做 upsert + bumpGroups —— 即 web 两档的**共同部分**，逐条一致
  /// （未读部分见文件头「未实现 1」）。
  Future<void> _reconcilePost(Map<String, dynamic> frame) async {
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
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或帖子已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// `post.viewed`（web `chat.ts:814–839`）：
  /// - `viewer_id == 本人` ⇒ [AylaPostsStore.markViewedBatch]（同步已读态）；
  /// - 否则 ⇒ [AylaPostsStore.updatePostViewCount]（只刷浏览量）。
  ///
  /// ⚠️ 本人分支里 web 还有「按 postId 去重后减群未读」一档（826–835）——
  /// Flutter 侧未读计数未实现（见文件头「未实现 1」），故只做已读态与浏览量。
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
