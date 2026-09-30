/// 我的收藏（路由 /favorites）—— web pages/FavoritesPage.tsx 321 行的等价物。
///
/// ## 事实源（逐条）
/// - tsx 19–26：六个分类（全部/消息/帖子/直播/语音房/桌游房）；?type= 驱动（tsx 305–308）；
/// - tsx 302–319：目录壳（AylaDirectoryPage 三件套）+ 侧栏槽位
///   （leading = .icon-btn-40.directory-filter-back + IconBack 20（tsx 309）；
///   decor = IconHeart 64（tsx 310）；header = Favorites / 我的收藏 / 统计行（tsx 311–315））；
/// - tsx 268–271：加载态 .favorites-skeleton（两条 64 高骨架，首条 mb 8）；
/// - tsx 272–280：空态（title + desc 逐字）· 列表 · 页脚；
/// - tsx 91–106：列表容器 .favorites-list（窄屏单列 gap sp2 / ≥769 双列 gap sp3、
///   上下 padding sp4）；项 = .favorite-item（AylaFavoriteItem 件）+ FavoriteResultCard；
///   ⚠️ 内距再叠目录页组规则（directory-filters.css:171–180 左右恒 0 + 199–208 ≥769 顶部归零）
///   —— 由 [aylaDirectoryListPadding] 在调用点表达（原实现左右保留 sp4，2026-09-29 订正）；
///   末槽 = .msg-action-btn「取消收藏」（tsx 96–100）；
/// - tsx 36–67：openTarget 五类跳转（post/live/voice/game/message 带 msg/seq/subgroup 定位参数）；
/// - tsx 250–259：取消收藏（DELETE 成功后本地收尾，不依赖广播时序）；
/// - tsx 278–279：页脚 loadMore 的分支（首页失败 → 重取首页）。
///
/// ## 与 web 的机制差异（登记）
/// - web 的分页 state 是模块级缓存（favoritePages，按账号 + scope 键，60s 过期 +
///   跨分类失效 + WS favorite.changed 对账，tsx 109–266）；Flutter 侧用
///   AylaPagedList（页面内），无跨页缓存与 WS 对账 ⇒ 切页/重进重新拉取；
/// - 滚动位置记忆（useScrollRestore / saveScrollPosition）未实现；
/// - 瀑布流的跨挂载列分配记忆由 AylaMasonryGrid 的 memoryKey 承担（件已交付）——
///   本页 memoryKey 用 favorites 加当前分类键（web 版还含 user_id）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/favorites_api.dart';
import '../core/models/chat_message.dart' show AylaChatMessage;
import '../state/favorite_status.dart';
import '../state/paged_list.dart';
import '../theme/app_icons.dart';
import '../theme/buttons.dart' show AylaMsgActionButton;
import '../theme/tokens.dart';
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_result_cards.dart';
import '../widgets/base/favorite_item.dart';
import '../widgets/base/page_state.dart';
import '../widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import '../widgets/posts/masonry_grid.dart';
import '../widgets/profile/favorites_skeleton.dart';
import 'hub_support.dart';

class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, this.initialType});

  /// ?type=（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 六个分类（tsx 19–26，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'message', label: '消息'),
    (key: 'post', label: '帖子'),
    (key: 'live', label: '直播'),
    (key: 'voice', label: '语音房'),
    (key: 'game', label: '桌游房'),
  ];

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  late String _filter =
      aylaHubFilterOf(FavoritesPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  AylaPagedList<AylaFavoriteEntry>? _pager;

  /// 本轮本地已删除的收藏 id（web 的 owner.removed 墓碑）。
  final Set<int> _removed = <int>{};

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant FavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialType != oldWidget.initialType) {
      final String next =
          aylaHubFilterOf(FavoritesPage.filters, widget.initialType);
      if (next != _filter) {
        setState(() => _filter = next);
        _start();
      }
    }
  }

  @override
  void dispose() {
    _pager?.dispose();
    _scroll.dispose();
    _favorites.dispose();
    super.dispose();
  }

  void _onPagerChanged() {
    if (mounted) setState(() {});
  }

  void _start() {
    final AylaPagedList<AylaFavoriteEntry> pager =
        AylaPagedList<AylaFavoriteEntry>(
      request: (String? cursor) => AylaFavoritesApi.listFavoritesPage(
        type: _filter == 'all' ? null : _filter,
        cursor: cursor,
      ),
      keyOf: (AylaFavoriteEntry entry) => entry.card.id.toString(),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    _removed.clear();
    pager.load();
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    _start();
    context.replace(next == 'all' ? '/favorites' : '/favorites?type=$next');
  }

  /// 取消收藏（tsx 250–259）：成功后本地收尾。
  Future<void> _remove(AylaFavoriteEntry entry) async {
    try {
      await AylaFavoritesApi.removeFavorite(entry.card.id);
      if (!mounted) return;
      setState(() => _removed.add(entry.card.id));
      // 与收藏状态机对账（卡片上的心形键同步转「未收藏」）。
      _favorites.apply(
        _targetTypeWire(entry.card.targetType),
        entry.targetId,
        null,
      );
    } catch (_) {
      // 取消收藏失败静默（web tsx 256–258 同）
    }
  }

  /// 打开原内容（tsx 36–67 的 openTarget 五类）。
  void _open(AylaFavoriteEntry entry) {
    switch (entry.card.targetType) {
      case AylaFavoriteTargetType.post:
        _goWithId('/posts', entry.targetId);
      case AylaFavoriteTargetType.live:
        _goWithId('/live', entry.targetId);
      case AylaFavoriteTargetType.voice:
        _goWithId('/voice', entry.targetId);
      case AylaFavoriteTargetType.game:
        _goWithId('/games', entry.targetId);
      case AylaFavoriteTargetType.message:
        final AylaChatMessage? msg = entry.card.message;
        if (msg == null || msg.conversationId.isEmpty) return;
        final List<String> params = <String>[];
        if (msg.id.isNotEmpty) {
          final String encodedId = Uri.encodeComponent(msg.id);
          params.add('msg=$encodedId');
        }
        if (msg.seq > 0) {
          final int seq = msg.seq;
          params.add('seq=$seq');
        }
        final String subgroup = msg.subgroupId ?? '';
        if (subgroup.isNotEmpty) {
          final String encodedSubgroup = Uri.encodeComponent(subgroup);
          params.add('subgroup=$encodedSubgroup');
        }
        final String encodedConversation =
            Uri.encodeComponent(msg.conversationId);
        if (params.isEmpty) {
          context.go('/chat/$encodedConversation');
        } else {
          final String qs = params.join('&');
          context.go('/chat/$encodedConversation?$qs');
        }
    }
  }

  List<AylaFavoriteEntry> _rows(AylaPagedList<AylaFavoriteEntry> pager) {
    if (_removed.isEmpty) return pager.items;
    return <AylaFavoriteEntry>[
      for (final AylaFavoriteEntry entry in pager.items)
        if (!_removed.contains(entry.card.id)) entry,
    ];
  }

  /// tsx 314：合计条数 / 加载中显示省略号。
  String _statsLabel(AylaPagedList<AylaFavoriteEntry> pager) {
    if (!pager.loaded) return '… 条收藏';
    final int total = pager.total - _removed.length;
    final int shown = total < 0 ? 0 : total;
    return '$shown 条收藏';
  }

  /// 空态内距（`.favorites-content .home-state`）：基样式上下 sp12（home.css:622–629
  /// 的 `padding: sp12 sp6`）+ 收藏页顶部覆盖 sp3（directory-filters.css:185–187，
  /// **不在媒体查询内**）+ 组规则左右归零（171–180，同样全断点）⇒ 宽窄同值
  /// `(0, sp3, 0, sp12)`（原宽屏档给的左右 sp6 与 171–180 冲突，2026-09-29 按 web 订正）。
  static const EdgeInsets _emptyPadding = EdgeInsets.only(
    top: AylaSpacing.sp3,
    bottom: AylaSpacing.sp12,
  );

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaPagedList<AylaFavoriteEntry>? pager = _pager;
    final Widget page = AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '收藏分类',
        options: FavoritesPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        leading: AylaDirectoryBackButton(onPressed: _back), // tsx 309
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconHeart')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Favorites',
          title: '我的收藏',
          stats: pager == null ? '… 条收藏' : _statsLabel(pager),
        ),
      ),
      content: AylaDirectoryContent(
        fadeGlass: false,
        controller: _scroll,
        scope: 'favorites:$_filter', // web key={scope}（tsx 316）
        label: aylaHubFilterLabel(FavoritesPage.filters, _filter),
        child: _body(narrow, pager),
      ),
    );

    // 窄屏返回手势（tsx 301：FullScreenSwipeBack enabled={isNarrow}）
    return narrow
        ? AylaFullScreenSwipeBack(enabled: true, onBack: _back, child: page)
        : page;
  }

  Widget _body(bool narrow, AylaPagedList<AylaFavoriteEntry>? pager) {
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 268–271；目录页组规则：左右恒 0（directory-filters.css:171–180）+ ≥769 顶部归零
      // （199–208 的名单含 `.favorites-skeleton`）⇒ 宽屏 (0, 0, 0, sp4) / 窄屏 (0, sp4, 0, sp4)。
      return AylaFavoritesSkeleton(
        padding: aylaDirectoryListPadding(
          context,
          top: AylaSpacing.sp4,
          bottom: AylaSpacing.sp4,
        ),
      );
    }
    final List<AylaFavoriteEntry> rows = _rows(pager);
    if (rows.isEmpty) {
      return AylaPageState(
        title: '这个分类还没有收藏', // tsx 274
        description: '在对应场景点收藏，内容会出现在这里', // tsx 275
        padding: _emptyPadding,
      );
    }
    return AylaMasonryGrid<AylaFavoriteEntry>(
      items: rows,
      itemKey: (AylaFavoriteEntry entry) => entry.card.id,
      memoryKey: 'favorites:$_filter', // web memoryKey（tsx 87）
      columns: narrow ? 1 : 2, // web: singleColumn ? 1 : 2（tsx 80–85）
      gap: AylaSpacing.sp2, // .favorites-list gap sp2
      masonryGap: AylaSpacing.sp3, // .is-masonry gap sp3
      // 基样式 padding sp3 sp4（profile.css:458–465）+ 目录页组规则：左右恒 0
      // （directory-filters.css:171–180，全断点）+ ≥769 顶部归零（199–208）
      // ⇒ 窄屏单列 (0, sp3, 0, sp3)。
      padding: aylaDirectoryListPadding(context),
      // ≥769 双列档：基样式上下 sp4（profile.css:524–532 的 .favorites-list.is-masonry，
      // 0-2-0 的 padding-top 被 0-3-0 的组规则压成 0）⇒ 宽屏 (0, 0, 0, sp4)。
      masonryPadding: aylaDirectoryListPadding(
        context,
        bottom: AylaSpacing.sp4,
      ),
      footer: AylaDirectoryLoadMore(
        loading: pager.loading,
        error: pager.error,
        hasMore: pager.hasMore,
        invalidated: pager.invalidated,
        // tsx 279：首页失败 → 重取首页
        loadMore: () => pager.error != null && pager.items.isEmpty
            ? pager.refresh()
            : pager.loadMore(),
        refresh: pager.refresh,
      ),
      itemBuilder: (BuildContext context, AylaFavoriteEntry entry, int index) {
        return AylaFavoriteItem(
          child: AylaFavoriteResultCard(
            favorite: entry.card,
            onOpen: () => _open(entry),
            senderLabel: entry.messageSenderNickname,
            action: AylaMsgActionButton(
              label: '取消收藏', // tsx 99
              onPressed: () => _remove(entry),
            ),
          ),
        );
      },
    );
  }

  /// 按 id 跳转（路径前缀由调用方给出）。
  void _goWithId(String prefix, String targetId) {
    final String encoded = Uri.encodeComponent(targetId);
    context.go('$prefix/$encoded');
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }
}

/// 收藏目标类型 → 后端字面量（收藏状态机与 API 用 snake_case 值）。
String _targetTypeWire(AylaFavoriteTargetType type) => switch (type) {
      AylaFavoriteTargetType.post => 'post',
      AylaFavoriteTargetType.live => 'live',
      AylaFavoriteTargetType.voice => 'voice',
      AylaFavoriteTargetType.game => 'game',
      AylaFavoriteTargetType.message => 'message',
    };
