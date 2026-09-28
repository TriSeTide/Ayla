/// 帖子详情（路由 /posts/:postId）—— web pages/PostDetailPage.tsx（728 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 399–428：加载态 = 头部（返回 + 「帖子」）+ `AylaPostDetailSkeleton`
///   （**不渲染 composer**）；
/// - tsx 430–438：空/错态 —— 2026-09-28 用户裁决**修**（不再照抄原 web「无头 + 贴顶无内距」）：
///   顶栏与加载态同构（返回键 + 「帖子」），正文交给 chrome 的非滚动主体
///   `AylaPostDetailEmpty`（`.post-detail-state` 档：内距/间距逐值取自 web 既有空态规范
///   —— `home.css:622–629` 的 `sp12 sp6` + `sp4`、`home.css:673–682` 的整页居中）；
/// - tsx 442–495：详情壳（`.post-detail` + 玻璃头 + 返回 + 「帖子」+ 分享 +
///   作者操作区「编辑 / 删除」，删除是**就地两态** tsx 486–489）；
/// - tsx 497–599：全屏编辑面板 ⇒ 件 `AylaPostEditFullscreen`；
/// - tsx 601–708：滚动区（详情卡 + 评论列）；
/// - tsx 615–684：详情卡 = `AylaPostCard` 的详情档（正文恒展开 / 媒体可点开查看器 /
///   时间用绝对时间 / 底排只留浏览数 + 收藏并右对齐）；
/// - tsx 677–683：底排浏览数 —— web 写 `{post.view_count ?? 0}`；
///   **Flutter 侧按「读不到不写成 0」纪律处理**（null ⇒ 不渲染该统计，
///   与卡片档 PostCard.tsx:141 的守卫一致）⇒ 登记为有意偏离；
/// - tsx 686–707：评论列（`AylaCommentList` hideComposer + revealItems + replayKey）
///   + `StablePaginationFooter` 三态（正在加载更多评论… / 加载更多评论 / 已加载全部评论
///   / 错误 + 重试「重试加载更多评论」`errorKind === "append"` 否则「重试评论」）；
/// - tsx 605–609：评论触底追加（距底 < 240 且**编辑中不触发**、有内容可滚才触发）；
/// - tsx 709–717：底部输入区 `AylaCommentComposer`（`inputEntered`、编辑态 inert）；
/// - tsx 719–725：图片查看器（`AylaImageViewer`）。
///
/// ## 数据层（web stores/posts.ts + usePostComments.ts）
/// - 详情：`GET /posts/<id>/`；浏览上报 `POST /posts/views/`（幂等，本人 ⇒ is_viewed）；
/// - `view_count` 合并用 **Math.max**（tsx 178）：上报结果小于当前值时不回退；
/// - 评论：`GET /posts/<id>/comments/?limit=20&cursor=`（**升序**、按 created_at + id），
///   发评论 `POST /posts/<id>/comments/`、删评论 `DELETE /posts/comments/<id>/`；
/// - 编辑保存：`PATCH /posts/<id>/`（**只有 images 变化才带 images**，tsx 365–376；
///   可见性多选 → 单值 public > friends > group，tsx 360–364；保存禁用 =
///   `savingEdit || editUploading || !body.trim()` —— **空标题可提交**，tsx 507）。
///
/// ## 机制差异（登记）
/// 1. **无帖子/评论缓存与 WS 增量**：web 从 `stores/posts` 取 cachedPost 秒开（tsx 109–111），
///    并监听 `comment.created/comment.deleted/post.viewed`（tsx 219–245）；Flutter 侧
///    帖子 WS 帧分发未接 ⇒ 每次进入都取详情，评论数与浏览量靠本地操作 + 刷新更新；
/// 2. **评论列用页面内状态机**（items/cursor/hasMore/loaded/loading/error + revision）：
///    web `usePostComments` 需要**本地 insert/remove**（发/删评论后对账）与
///    `errorKind`（init / append 两档文案），而 `AylaPagedList` 的 items 只读且只有单一
///    error ⇒ 逐条照搬 web 状态机会更保真（登记为偏差）；
/// 3. **分享弹窗接线未做**（按钮已在头部渲染、点击无动作）—— 同 posts_hub_page 登记；
/// 4. **编辑面板的媒体上传/回收未接线**（13 号 §4.3 既有登记项「媒体/视频接线未完成」）：
///    面板只展示既有媒体的缩略图与移除键，新增媒体走 13 号 4.3 的注入点；
/// 5. 滚动位置记忆（`useScrollRestore`）未实现（与其他页同登记）；
/// 6. `presenceOnline`（在线用户集合）未接 —— 卡片的在线态回落到帖子内联 `author.online`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart';
import '../core/api/posts_api.dart';
import '../core/media/media_signer.dart' show MediaVariant;
import '../core/models/conversation.dart';
import '../core/models/post.dart';
import '../core/net/dio_client.dart' show ApiException;
import '../state/favorite_status.dart';
import '../state/shell_state.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/pagination_footer.dart';
import '../widgets/base/visibility_selector.dart' show AylaVisibilitySelector, AylaVisibilitySelection;
import '../widgets/base/resource_image.dart'
    show AylaResourceImage, mediaContentUrl;
import '../widgets/chat/image_viewer.dart';
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import '../widgets/posts/comments.dart';
import '../widgets/posts/post_card.dart';
import '../widgets/posts/post_detail_chrome.dart';
import '../widgets/posts/post_edit_fullscreen.dart';
import '../widgets/posts/post_page_chrome.dart' show aylaPostDetailTime;
import '../widgets/base/share.dart' show AylaShareButton;
import '../theme/buttons.dart' show AylaMsgActionButton;

class PostDetailPage extends ConsumerStatefulWidget {
  const PostDetailPage({super.key, required this.postId, this.from});

  /// 路径参数 :postId（web `Number(postId)`；非数字 ⇒ 空/错态）。
  final String postId;

  /// `?from=mine|user`（进详情前列表页写入的来源，用于返回）。
  final String? from;

  @override
  ConsumerState<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends ConsumerState<PostDetailPage> {
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final ScrollController _scroll = ScrollController();

  AylaPost? _post;
  bool _loading = true;
  String? _error;
  int _rev = 0;

  // ---- 评论分页（web usePostComments 的状态机）----
  List<AylaPostComment> _comments = const <AylaPostComment>[];
  String? _cursor;
  bool _commentsHasMore = false;
  bool _commentsLoaded = false;
  bool _commentsLoading = false;
  String? _commentsError;
  bool _commentsAppendError = false;
  int _commentsRev = 0;
  int _commentsReplay = 0;
  AylaPostComment? _replyTarget;

  // ---- 编辑态（tsx 121–133）----
  bool _editing = false;
  bool _saving = false;
  String? _mediaError;
  String? _actionError;
  final TextEditingController _editTitle = TextEditingController();
  final TextEditingController _editBody = TextEditingController();
  AylaVisibilitySelection _editVisibility = const AylaVisibilitySelection();
  List<String> _editGroupIds = const <String>[];
  /// 编辑面板的媒体（**media_id 列表**，全量替换语义；web tsx 470–478 的 existing）。
  List<String> _initialMediaIds = const <String>[];
  List<String> _editMediaIds = const <String>[];

  bool _confirmingDelete = false;
  bool _deleting = false;
  int? _viewerIndex;

  /// 查看器条目（帖子媒体或评论图片；web tsx 719–725 / CommentList.tsx:161–167）。
  List<AylaMediaDescriptor> _viewerItems = const <AylaMediaDescriptor>[];

  /// 可见性选择器的群列表（web 由组件自拉；Flutter 注入 ⇒ 页面取会话目录）。
  List<({String id, String title})> _groups = const <({String id, String title})>[];
  bool _groupsLoading = false;

  ShellUiNotifier? _shellNotifier;

  int? get _postId => int.tryParse(widget.postId);

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onFavoritesChanged);
    _load();
    _loadGroups();
    // tsx 100–104：群外详情让底栏下滑离场（shell owner）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
      _shellNotifier = notifier;
      notifier.setBottomTabsLeaving(true);
    });
  }

  @override
  void dispose() {
    _favorites.removeListener(_onFavoritesChanged);
    _favorites.dispose();
    _editTitle.dispose();
    _editBody.dispose();
    _scroll.dispose();
    final ShellUiNotifier? notifier = _shellNotifier;
    if (notifier != null) {
      // ⚠️ 必须延迟到生命周期之外复位：在 dispose 里直接改 provider 会触发
      // Riverpod 的「Tried to modify a provider while the widget tree was building」
      // 断言（实测红过：router_test 的路由探测走一遍详情页就抛）。
      // 与各页 unregisterRefresh 的 scheduleMicrotask 惯例同。
      scheduleMicrotask(() => notifier.setBottomTabsLeaving(false));
    }
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- 详情

  Future<void> _load() async {
    final int? id = _postId;
    if (id == null) {
      setState(() {
        _loading = false;
        _error = null; // 非数字 ⇒ 空态显示「帖子不存在」（tsx 433 的兜底）
      });
      return;
    }
    final int rev = ++_rev;
    setState(() {
      _loading = _post == null;
      _error = null;
    });
    try {
      final AylaPost? post = await AylaPostsApi.getPost(id);
      if (!mounted || rev != _rev) return;
      setState(() {
        _post = post;
        _loading = false;
      });
      _loadComments();
      _reportViews();
    } catch (err) {
      if (!mounted || rev != _rev) return;
      setState(() {
        _loading = false;
        _error = err is ApiException ? err.message : '帖子加载失败';
      });
    }
  }

  /// tsx 194–216：浏览上报（幂等）+ `Math.max` 合并（旧值不回退）。
  Future<void> _reportViews() async {
    final AylaPost? post = _post;
    if (post == null) return;
    try {
      final Map<String, int> updated =
          await AylaPostsApi.reportPostViews(<int>[post.id]);
      final int? next = updated[post.id.toString()];
      if (!mounted || next == null) return;
      final AylaPost? current = _post;
      if (current == null) return;
      final int now = current.viewCount ?? 0;
      if (next <= now) return; // 单调合并
      setState(() {
        _post = _copyPost(current, viewCount: next, isViewed: true);
      });
    } catch (_) {
      // 失败保持原态（web：失败不伪造已读）
    }
  }

  AylaPost _copyPost(
    AylaPost post, {
    int? viewCount,
    bool? isViewed,
    int? commentCount,
  }) =>
      AylaPost(
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
        commentCount: commentCount ?? post.commentCount,
        isAuthor: post.isAuthor,
        viewCount: viewCount ?? post.viewCount,
        isViewed: isViewed ?? post.isViewed,
        createdAt: post.createdAt,
        updatedAt: post.updatedAt,
      );

  // ---------------------------------------------------------------- 评论

  Future<void> _loadComments({bool append = false}) async {
    final int? id = _postId;
    if (id == null || _commentsLoading) return;
    if (append && !_commentsHasMore) return;
    final int rev = ++_commentsRev;
    setState(() {
      _commentsLoading = true;
      _commentsError = null;
      _commentsAppendError = append;
    });
    try {
      final AylaDirectoryPage<AylaPostComment> page =
          await AylaPostsApi.listCommentsPage(
        id,
        cursor: append ? _cursor : null,
      );
      if (!mounted || rev != _commentsRev) return;
      final Map<String, AylaPostComment> merged = <String, AylaPostComment>{};
      if (append) {
        for (final AylaPostComment c in _comments) {
          merged[c.id.toString()] = c;
        }
      }
      for (final AylaPostComment c in page.results) {
        merged[c.id.toString()] = c;
      }
      setState(() {
        _comments = merged.values.toList(growable: false);
        _cursor = page.nextCursor;
        _commentsHasMore = page.hasMore;
        _commentsLoaded = true;
        _commentsLoading = false;
        _commentsError = null;
      });
    } catch (err) {
      if (!mounted || rev != _commentsRev) return;
      setState(() {
        _commentsLoading = false;
        _commentsError = err is ApiException ? err.message : '评论加载失败';
      });
    }
  }

  /// tsx 246–258：发评论（**await 成功后才插入**，失败保留正文）。
  Future<void> _sendComment(
    String body,
    int? replyTo,
    List<String> mediaIds,
  ) async {
    final int? id = _postId;
    if (id == null) return;
    final String trimmed = body.trim();
    if (trimmed.isEmpty && mediaIds.isEmpty) return;
    final AylaPostComment? created = await AylaPostsApi.createComment(
      id,
      body: trimmed,
      replyTo: replyTo,
      images: mediaIds,
    );
    if (!mounted || created == null) return;
    setState(() {
      _comments = <AylaPostComment>[..._comments, created];
      _replyTarget = null;
      _commentsReplay += 1;
      final AylaPost? post = _post;
      if (post != null) {
        _post = _copyPost(
          post,
          commentCount: (post.commentCount ?? 0) + 1,
        );
      }
    });
  }

  /// tsx 260–270：删评论（await 成功后才移除）。
  Future<void> _deleteComment(AylaPostComment comment) async {
    await AylaPostsApi.deleteComment(comment.id);
    if (!mounted) return;
    setState(() {
      _comments = <AylaPostComment>[
        for (final AylaPostComment c in _comments)
          if (c.id != comment.id) c,
      ];
      if (_replyTarget?.id == comment.id) _replyTarget = null;
      final AylaPost? post = _post;
      if (post != null && post.commentCount != null) {
        final int next = post.commentCount! > 0 ? post.commentCount! - 1 : 0;
        _post = _copyPost(post, commentCount: next);
      }
    });
  }

  /// tsx 605–609：触底追加（**编辑中不触发**；有内容可滚才触发）。
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (_editing ||
        _commentsError != null ||
        _commentsLoading ||
        !_commentsHasMore) {
      return false;
    }
    if (n.metrics.maxScrollExtent <= 0) return false; // scrollHeight > clientHeight
    if (n.metrics.extentAfter < 240) _loadComments(append: true);
    return false;
  }

  // ---------------------------------------------------------------- 删除 / 编辑

  /// tsx 275–289：删帖（就地两态确认；成功后返回列表）。
  Future<void> _confirmDelete() async {
    final int? id = _postId;
    if (id == null || _deleting) return;
    setState(() => _deleting = true);
    try {
      await AylaPostsApi.deletePost(id);
      if (!mounted) return;
      _goBack();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _actionError = err is ApiException ? err.message : '删除失败，请重试';
      });
    }
  }

  /// tsx 458–481：打开编辑面板并初始化字段。
  void _startEdit() {
    final AylaPost? post = _post;
    if (post == null) return;
    _editTitle.text = post.title;
    _editBody.text = post.body;
    final bool hasGroups = post.allowedGroupIds.isNotEmpty;
    setState(() {
      _editVisibility = AylaVisibilitySelection(
        isPublic: post.visibility == AylaPostVisibility.public,
        friends: post.visibility == AylaPostVisibility.friends,
        group: hasGroups,
      );
      _editGroupIds = post.allowedGroupIds;
      _editMediaIds = <String>[
        for (final AylaPostImage img in post.images)
          if (img.media != null) img.media!.mediaId,
      ];
      _initialMediaIds = _editMediaIds;
      _mediaError = null;
      _actionError = null;
      _editing = true;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _saving = false;
      _mediaError = null;
      _actionError = null;
    });
  }

  /// tsx 355–396：保存（images **仅在变化时**才带；多选 → 单值）。
  Future<void> _saveEdit() async {
    final AylaPost? post = _post;
    final int? id = _postId;
    if (post == null || id == null || _saving) return;
    final String body = _editBody.text.trim();
    if (body.isEmpty) return;
    // tsx 360–364：多选 → 单值（public > friends > group）
    final String? visibility = _editVisibility.isPublic
        ? 'public'
        : _editVisibility.friends
            ? 'friends'
            : _editVisibility.group
                ? 'group'
                : null;
    // tsx 356–359：选了群可见却没选群 ⇒ 阻断
    if (_editVisibility.group && _editGroupIds.isEmpty) {
      setState(() => _mediaError = '请至少选择一个群');
      return;
    }
    // tsx 365–376：**只有 images 变化才带 images**（全量替换语义）
    final bool imagesChanged = !_sameIds(_editMediaIds, _initialMediaIds);
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      final AylaPost? updated = await AylaPostsApi.updatePost(
        id,
        title: _editTitle.text.trim(),
        body: body,
        visibility: visibility,
        allowedGroupIds: _editGroupIds,
        images: imagesChanged ? _editMediaIds : null,
        // allowed_group_ids 只在选了「群可见」时才有意义（web tsx 360–364 的单值化）

      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
        if (updated != null) _post = updated;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _actionError = err is ApiException ? err.message : '保存失败，请重试';
      });
    }
  }

  /// 编辑面板的媒体格（web `tsx:561–569`）。
  Widget _editMediaThumb(AylaMediaDescriptor media) {
    if (media.kind == AylaMediaKind.video) {
      return AylaPostVideoCover(
        media: media,
        fit: BoxFit.cover,
      );
    }
    return AylaResourceImage(
      src: media.thumbnail ?? mediaContentUrl(media.mediaId),
      alt: '帖子图片',
      variant: media.thumbnail != null ? MediaVariant.thumb : null,
      fit: BoxFit.cover,
    );
  }

  bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- 导航 / 群列表

  /// tsx 80–87：PUSH 进入 ⇒ 返回上一页；否则回来源页（`?from=mine` ⇒ /posts/mine）。
  void _goBack() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(widget.from == 'mine' ? '/posts/mine' : '/posts');
  }

  /// 可见性选择器的群列表（web 由组件自拉 `useSocialPage("conversations")`）。
  Future<void> _loadGroups() async {
    setState(() => _groupsLoading = true);
    try {
      final AylaDirectoryPage<AylaConversationSummary> page =
          await AylaChatApi.listConversationsPage(type: 'group', limit: 100);
      if (!mounted) return;
      setState(() {
        _groups = <({String id, String title})>[
          for (final AylaConversationSummary c in page.results)
            if (c.isGroup) (id: c.id, title: c.title),
        ];
        _groupsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _groupsLoading = false);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final AylaPost? post = _post;

    if (_loading && post == null && _postId != null) {
      // tsx 399–428：头部 + 结构化骨架（**不渲染 composer**）
      return AylaFullScreenSwipeBack(
        enabled: narrow,
        onBack: _goBack,
        child: AylaPostDetailChrome(
          onBack: _goBack,
          // 加载态不渲染 composer（tsx 399–428）；骨架在滚动区内
          children: const <Widget>[AylaPostDetailSkeleton()],
        ),
      );
    }

    if (post == null) {
      // tsx 430–438（2026-09-28 用户裁决「修」）：顶栏与加载态同构（chrome 承担），
      // 正文 = chrome 的非滚动主体 AylaPostDetailEmpty（.post-detail-state 档）。
      return AylaFullScreenSwipeBack(
        enabled: narrow,
        onBack: _goBack,
        child: AylaPostDetailChrome(
          onBack: _goBack,
          body: AylaPostDetailEmpty(
            message: _error ?? '帖子不存在',
            onBack: _goBack,
          ),
        ),
      );
    }

    final List<AylaMediaDescriptor> media = <AylaMediaDescriptor>[
      for (final AylaPostImage img in post.images)
        if (img.media != null) img.media!,
    ];

    return AylaFullScreenSwipeBack(
      enabled: narrow,
      onBack: _goBack,
      child: Stack(
        children: <Widget>[
          AylaPostDetailChrome(
            onBack: _goBack,
            editing: _editing,
            scrollController: _scroll,
            onScrollNotification: _onScroll,
            // 分享按钮：web `tsx:449–455` 用默认 40（`.icon-btn-40`）；
            // ⚠️ 分享弹窗接线未做 ⇒ 这里给**空回调**（外观与 web 一致、点击无动作），
            // 不给 null（null 会被件渲染成禁用态，与 web 不符）—— 登记项见文件头差异 3。
            share: AylaShareButton(
              label: '分享帖子',
              size: 40,
              onPressed: () {},
            ),
            ownerActions: post.isAuthor ? _ownerActions() : null,
            composer: AylaCommentComposer(
              onSend: _sendComment,
              replyTarget: _replyTarget,
              onReplyClear: () => setState(() => _replyTarget = null),
              inputEntered: true,
              inert: _editing,
            ),
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  // .post-detail-card { max-width: 680px; margin: 0 auto }
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: AylaPostCard(
                    post: post,
                    onOpen: () {},
                    // 详情档：正文恒展开（tsx 637）+ 底排右对齐（posts.css 745–747）
                    expanded: true,
                    detail: true,
                    timeLabel: aylaPostDetailTime(post.createdAt),
                    onOpenMedia: (int index) => setState(() {
                      _viewerItems = media;
                      _viewerIndex = index;
                    }),
                    favoriteState:
                        _favorites.stateOf('post', post.id.toString()),
                    favoriteBusy: _favorites.busyOf('post', post.id.toString()),
                    favoriteError:
                        _favorites.actionErrorOf('post', post.id.toString()),
                    onToggleFavorite: (bool _) =>
                        _favorites.toggle('post', post.id.toString()),
                    onRetryFavoriteStatus: () => _favorites.load(
                      'post',
                      <String>[post.id.toString()],
                      force: true,
                    ),
                    onAuthorTap: post.authorId == null
                        ? null
                        : () => context.go('/user/${post.authorId}'),
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  // .post-detail-comments { max-width: 680px; margin: 0 auto }
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: _commentsSection(),
                ),
              ),
            ],
          ),
          if (_editing)
            // tsx 497–599：编辑面板覆盖详情页（absolute 语义 ⇒ 这里是 Stack 的满幅子项）
            Positioned.fill(
              child: AylaPostEditFullscreen(
                titleController: _editTitle,
                bodyController: _editBody,
                onCancel: _cancelEdit,
                onSave: _saveEdit,
                saving: _saving,
                // 媒体上传未接线（13 号 §4.3 登记项）⇒ 恒 false
                uploading: false,
                mediaCount: _editMediaIds.length,
                // 媒体格：既有媒体按 tsx 561–569 的两分支渲染
                // （视频 → AylaPostVideoCover；图片 → AylaResourceImage(thumb || content url)）
                mediaChildren: <Widget>[
                  for (final AylaPostImage img in post.images)
                    if (img.media != null) _editMediaThumb(img.media!),
                ],
                onRemoveMedia: null, // 媒体移除/上传未接线（13 号 §4.3 登记项）
                onAddMedia: null,
                visibilitySlot: AylaVisibilitySelector(
                  value: _editVisibility,
                  onChange: (AylaVisibilitySelection v) =>
                      setState(() => _editVisibility = v),
                  selectedGroupIds: _editGroupIds,
                  onSelectedGroupIdsChange: (List<String> ids) =>
                      setState(() => _editGroupIds = ids),
                  groups: _groups,
                  groupsLoading: _groupsLoading,
                  initialGroupId: post.groupId,
                  lockGroup: post.groupId != null,
                ),
                mediaError: _mediaError,
                actionError: _actionError,
              ),
            ),
          if (_viewerIndex != null && _viewerItems.isNotEmpty)
            AylaImageViewer(
              onClose: () => setState(() => _viewerIndex = null),
              items: <AylaViewerItem>[
                for (final AylaMediaDescriptor m in _viewerItems)
                  AylaViewerItem(
                    media: m,
                    alt: post.title.isEmpty ? '帖子图片' : post.title,
                  ),
              ],
              initialIndex: _viewerIndex!.clamp(0, _viewerItems.length - 1),
              alt: post.title.isEmpty ? '帖子图片' : post.title,
            ),
        ],
      ),
    );
  }

  /// tsx 456–494：作者操作区（编辑 / 删除，就地两态）。
  Widget _ownerActions() {
    return Row(
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        AylaMsgActionButton(label: '编辑', onPressed: _startEdit),
        AylaMsgActionButton(
          label: _deleting
              ? '删除中…'
              : (_confirmingDelete ? '确认删除？' : '删除'),
          onPressed: _deleting
              ? null
              : () {
                  if (_confirmingDelete) {
                    _confirmDelete();
                  } else {
                    setState(() => _confirmingDelete = true);
                  }
                },
        ),
      ],
    );
  }

  /// tsx 686–707：评论列 + 页脚三态。
  Widget _commentsSection() {
    Widget footer;
    if (_commentsError != null) {
      footer = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              _commentsError!,
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 14,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: AylaSpacing.sp2),
          AylaGlassButton(
            // tsx 702：errorKind === "append" ? 重试加载更多评论 : 重试评论
            label: _commentsAppendError ? '重试加载更多评论' : '重试评论',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: () => _loadComments(append: _commentsAppendError),
          ),
        ],
      );
    } else if (_commentsLoading && _commentsLoaded) {
      footer = const Text('正在加载更多评论…');
    } else if (_commentsHasMore) {
      footer = AylaGlassButton(
        label: '加载更多评论',
        variant: AylaGlassButtonVariant.ghost,
        onPressed: () => _loadComments(append: true),
      );
    } else if (_commentsLoaded && _comments.isNotEmpty) {
      footer = const Text('已加载全部评论');
    } else {
      footer = const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!_commentsLoaded && _commentsLoading)
          Semantics(
            liveRegion: true,
            label: '正在加载评论',
            child: const Text('正在加载评论…'),
          ),
        if (_commentsLoaded || _comments.isNotEmpty)
          AylaCommentList(
            comments: _comments,
            onSend: _sendComment,
            onDelete: _deleteComment,
            replyTarget: _replyTarget,
            onReply: (AylaPostComment c) => setState(() => _replyTarget = c),
            onReplyClear: () => setState(() => _replyTarget = null),
            hideComposer: true, // 详情页输入框固定在底部（tsx 696）
            revealItems: true,
            replayKey: _commentsReplay,
            onOpenImages: (List<AylaMediaDescriptor> images, int index,
                String alt) {
              // 评论图片查看器（web CommentList.tsx:161–167 由列表自带）
              setState(() {
                _viewerItems = images;
                _viewerIndex = index;
              });
            },
            onAuthorTap: (AylaPostComment c) {
              final String? id = c.authorId ?? c.author?.id;
              if (id != null) context.go('/user/$id');
            },
          ),
        AylaStablePaginationFooter(child: Center(child: footer)),
      ],
    );
  }
}
