/// 全局搜索（路由 /search?q=&type=）—— web pages/SearchPage.tsx 521 行的等价物。
///
/// ## 事实源（逐条）
/// - tsx 41–49：七个分类（全部/用户/群聊/帖子/直播间/语音房/桌游室）；
/// - tsx 297–324：URL q 驱动（进入 /search?q=… 或顶栏/历史更新 q 时自动搜索）；
///   tsx 327–332：历史 chips / 表单提交统一走 URL（replace，不污染历史栈）；
/// - tsx 172：**all → limit 3；单类 → limit 20**；
/// - tsx 362–373：历史 chips（仅在 !q 且历史非空时渲染）+「清空」；
/// - tsx 375：搜索中（.search-loading，search.css:32–37，组规则左右归零）；
/// - tsx 376–378：错误（.search-error，search.css:39–43；destructive 文案 +「重试搜索」ghost 键）；
/// - tsx 380–460：六类分组，**渲染顺序 = 用户 → 群聊 → 帖子 → 桌游室 → 语音房 → 直播间**
///   （与 FILTERS 顺序不同，逐条对 tsx 380/411/427/436/445/451）；
/// - tsx 462–467：无结果空态（.search-empty，search.css:46–57；title 20px + desc）；
/// - tsx 472–489：用户资料浮层（.user-profile-overlay，search.css:304–312）+ 入群申请弹窗；
/// - tsx 494–521：ResultGroup（count === 0 整组不渲染；单类视图隐藏组标题）。
///
/// ## 与 web 的机制差异（登记）
/// - **WS 成员事件未接线**（tsx 242–287 的 group.request.resolved / group.joined /
///   group.member.left）：chat WS 帧路由属第 3 批 ⇒ 本轮成员关系只取响应的 is_member；
/// - groupIsJoined 四级兜底里，第三/四级（当前结果内的 is_member、已加入会话集合）
///   本轮分别由「响应 is_member」与「空集合」承担 —— chat store 的会话列表属第 3 批；
/// - tsx 51–65 的 searchPageMemory（跨挂载结果缓存 + 失效）未实现：切页/重进重新搜索；
/// - 在线判定用 UserPublic.online（后端字段）；presence store 的实时在线属后续批次；
/// - 滚动位置记忆（useScrollRestore / saveScrollPosition）未实现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/search_api.dart';
import '../core/api/users_api.dart';
import '../core/models/post.dart' show AylaPost;
import '../core/models/subgroup.dart' show AylaGroupApplyData;
import '../state/auth_state.dart';
import '../state/search_history.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/dialogs.dart' show AylaModalOverlay;
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_result_cards.dart';
import '../widgets/base/page_state.dart';
import '../widgets/base/profile_and_filters.dart'
    show AylaDirectoryFilters, AylaUserProfileCard;
import '../widgets/game/game_room_card.dart';
import '../widgets/group/group_apply.dart' show AylaGroupApplyDialog;
import '../widgets/live/live_hall.dart' show AylaLiveChannelCard, AylaLiveCardData;
import '../widgets/posts/post_card.dart' show AylaPostCard;
import '../widgets/search/search_history_chips.dart';
import '../widgets/search/search_result_group.dart';
import '../widgets/search/search_user_row.dart';
import '../widgets/voice/voice_channels.dart'
    show AylaVoiceCardData, AylaVoiceChannelCard;
import '../core/models/game_room.dart' show AylaGameCardData;
import 'hub_support.dart';

/// 六类结果的键（web RESULT_KEYS 的 Dart 侧表达）。
enum AylaSearchResultKey { users, groups, posts, lives, games, voices }

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery, this.initialType});

  /// ?q=（路由读取；null / 空 = 未搜索态）。
  final String? initialQuery;

  /// ?type=（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 七个分类（tsx 41–49，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'user', label: '用户'),
    (key: 'group', label: '群聊'),
    (key: 'post', label: '帖子'),
    (key: 'live', label: '直播间'),
    (key: 'voice', label: '语音房'),
    (key: 'game', label: '桌游室'),
  ];

  /// 分类键 → 结果组键（tsx 38 的 RESULT_TYPES）。
  static const Map<String, AylaSearchResultKey> typeToKey =
      <String, AylaSearchResultKey>{
    'user': AylaSearchResultKey.users,
    'group': AylaSearchResultKey.groups,
    'post': AylaSearchResultKey.posts,
    'live': AylaSearchResultKey.lives,
    'game': AylaSearchResultKey.games,
    'voice': AylaSearchResultKey.voices,
  };

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late String _q = (widget.initialQuery ?? '').trim();
  late String _filter = aylaHubFilterOf(SearchPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaSearchHistoryController _history = AylaSearchHistoryController();

  AylaSearchResults? _results;

  /// 结果所属作用域（web resultScope）：与当前 scope 不同 ⇒ 不渲染旧结果。
  String _resultsScope = '';

  bool _loading = false;
  String? _error;

  /// 每组独立的续页状态（web pageStatus）。
  final Map<AylaSearchResultKey, ({bool loading, String? error})> _pageStatus =
      <AylaSearchResultKey, ({bool loading, String? error})>{};

  /// 用户资料浮层（tsx 113/472–478）。
  AylaSearchUserItem? _selectedUser;
  String? _profileBusy;
  String? _profileError;

  /// 入群申请弹窗（tsx 114/480–489）。
  AylaSearchGroupItem? _selectedGroup;

  /// 已通过审批的群（tsx 110；WS group.request.resolved 未接线 ⇒ 本轮恒空）。
  final Set<String> _acceptedGroupIds = <String>{};

  int _requestId = 0;

  /// 作用域键（web searchScope 的 q + filter）。
  String get _scope => '$_q|$_filter';

  @override
  void initState() {
    super.initState();
    _history.addListener(_onHistoryChanged);
    _history.load();
    if (_q.isNotEmpty) _refreshSearch(_q);
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String nextQuery = (widget.initialQuery ?? '').trim();
    final String nextFilter =
        aylaHubFilterOf(SearchPage.filters, widget.initialType);
    if (nextQuery == _q && nextFilter == _filter) return;
    setState(() {
      _q = nextQuery;
      _filter = nextFilter;
      _results = null;
      _resultsScope = _scope;
      _loading = false;
      _error = null;
      _pageStatus.clear();
      _selectedGroup = null;
      _selectedUser = null;
      _profileError = null;
    });
    if (_q.isNotEmpty) _refreshSearch(_q);
  }

  @override
  void dispose() {
    _history.removeListener(_onHistoryChanged);
    _history.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  /// tsx 159–194 + 230–238：重取第一页（替换可见结果），并记录一次搜索历史。
  ///
  /// ⚠️ web 的 pushHistory 在 **doSearch** 里（tsx 234），而 URL effect（tsx 321）
  /// 与「重试搜索」（tsx 377）都走 doSearch ⇒ URL 驱动的搜索也会记录历史；
  /// submitQuery（tsx 327–332）只改 URL、自己**不**记录。
  Future<void> _refreshSearch(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _history.push(trimmed); // tsx 234
    final String scope = '$trimmed|$_filter';
    final int requestId = ++_requestId;
    final AylaSearchResultKey? single = SearchPage.typeToKey[_filter];
    setState(() {
      _pageStatus.clear();
      _loading = true;
      _error = null;
    });
    try {
      final AylaSearchResults next = await AylaSearchApi.searchPage(
        q: trimmed,
        types: single == null ? null : <String>[_wireOf(single)],
        limit: single == null ? 3 : 20, // tsx 172
      );
      if (!mounted || requestId != _requestId || scope != _scope) return;
      setState(() {
        _results = next;
        _resultsScope = scope;
      });
    } catch (err) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _error = err is Exception ? _messageOf(err) : '搜索失败');
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _loading = false);
      }
    }
  }

  /// tsx 196–228：某组续页（每组独立游标 + 独立 loading/error）。
  Future<void> _loadMore(AylaSearchResultKey key) async {
    final AylaSearchGroup<Object?>? group = _groupOf(_results, key);
    if (group == null || !group.hasMore) return;
    if (_pageStatus[key]?.loading == true) return;
    final String? cursor = group.nextCursor;
    if (cursor == null) return;
    final int requestId = _requestId;
    setState(() {
      _pageStatus[key] = (loading: true, error: null);
    });
    try {
      final AylaSearchResults response = await AylaSearchApi.searchPage(
        q: _q,
        types: <String>[_wireOf(key)],
        limit: 20,
        cursor: cursor,
      );
      if (!mounted || requestId != _requestId) return;
      final AylaSearchGroup<Object?>? incoming = _groupOf(response, key);
      if (incoming == null ||
          (incoming.hasMore &&
              (incoming.nextCursor == null || incoming.nextCursor == cursor))) {
        throw StateError('搜索续页未推进，请重试或重新搜索');
      }
      setState(() {
        _results = _mergeGroup(_results, key, incoming);
        _pageStatus[key] = (loading: false, error: null);
      });
    } catch (err) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _pageStatus[key] = (
          loading: false,
          error: err is Exception ? _messageOf(err) : '加载更多失败',
        );
      });
    }
  }

  /// 历史 chips / 表单提交（tsx 327–332）：改写 URL；搜索由 didUpdateWidget 驱动。
  void _submitQuery(String query) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    // 只改 URL：历史记录由 _refreshSearch 的 push 承担（web tsx 327–332 同）
    context.replace(_url(trimmed, _filter));
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    context.replace(_url(_q, next));
  }

  String _url(String query, String filter) {
    final List<String> params = <String>[];
    final String trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      final String encoded = Uri.encodeComponent(trimmed);
      params.add('q=$encoded');
    }
    if (filter != 'all') params.add('type=$filter');
    if (params.isEmpty) return '/search';
    final String qs = params.join('&');
    return '/search?$qs';
  }

  /// 头像点击目标（web goUserProfile：自己 → /profile，他人 → /user/:id）。
  void _openUserProfile(AylaSearchUserItem user) {
    final String? me = ref.read(authNotifierProvider).user?.id;
    if (me != null && me == user.id) {
      context.go('/profile');
    } else {
      final String encoded = Uri.encodeComponent(user.id);
      context.go('/user/$encoded');
    }
  }

  Future<void> _addFriend(AylaSearchUserItem user) async {
    if (_profileBusy != null) return;
    setState(() {
      _profileBusy = 'friend';
      _profileError = null;
    });
    try {
      await AylaUsersApi.createFriendRequest(toUserId: user.id);
    } catch (err) {
      if (mounted) {
        setState(() =>
            _profileError = err is Exception ? _messageOf(err) : '发送好友申请失败');
      }
    } finally {
      if (mounted) setState(() => _profileBusy = null);
    }
  }

  Future<void> _sendMessage(AylaSearchUserItem user) async {
    if (_profileBusy != null) return;
    setState(() {
      _profileBusy = 'chat';
      _profileError = null;
    });
    try {
      final String conversationId =
          await AylaUsersApi.openPrivateConversation(user.id);
      if (!mounted) return;
      if (conversationId.isNotEmpty) {
        final String encoded = Uri.encodeComponent(conversationId);
        context.go('/chat/$encoded');
      }
    } catch (err) {
      if (mounted) {
        setState(() =>
            _profileError = err is Exception ? _messageOf(err) : '打开会话失败');
      }
    } finally {
      if (mounted) setState(() => _profileBusy = null);
    }
  }

  /// tsx 144–148 的成员关系判定（本轮：响应的 is_member 为权威；
  /// WS 增量与已加入会话集合的空缺见文件头登记）。
  bool _groupIsJoined(AylaSearchGroupItem group) => group.isMember == true;

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final bool wide = !narrow;

    final Widget page = AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '搜索分类',
        options: SearchPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        leading: AylaDirectoryBackButton(onPressed: _back), // tsx 352
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconSearch')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Search',
          title: '全局搜索',
          // tsx 357：加载中 / 无查询词时显示省略号
          stats: _searchStatsLabel(),
        ),
      ),
      content: AylaDirectoryContent(
        controller: _scroll,
        scope: _scope, // web key={scope}（tsx 359）
        label: aylaHubFilterLabel(SearchPage.filters, _filter),
        child: _body(wide),
      ),
    );

    final Widget? overlay = _overlay();
    if (overlay == null) return page;
    // web：浮层是页面根的 fixed 兄弟（tsx 472–489 在 .search-page 内）
    return Stack(
      children: <Widget>[page, overlay],
    );
  }

  Widget? _overlay() {
    final AylaSearchUserItem? selectedUser = _selectedUser;
    if (selectedUser != null) {
      return AylaModalOverlay(
        onDismiss: () => setState(() {
          _selectedUser = null;
          _profileError = null;
        }),
        centerBoth: true, // .user-profile-overlay 两档都居中（search.css:304–312）
        child: AylaUserProfileCard(
          nickname: selectedUser.nickname ?? '',
          username: selectedUser.username ?? '',
          signature: selectedUser.signature,
          avatarUrl:
              (selectedUser.avatar ?? '').isEmpty ? null : selectedUser.avatar,
          online: selectedUser.online,
          error: _profileError,
          friendBusy: _profileBusy == 'friend',
          chatBusy: _profileBusy == 'chat',
          onAddFriend: () => _addFriend(selectedUser),
          onSendMessage: () => _sendMessage(selectedUser),
          onClose: () => setState(() {
            _selectedUser = null;
            _profileError = null;
          }),
        ),
      );
    }
    final AylaSearchGroupItem? selectedGroup = _selectedGroup;
    if (selectedGroup != null) {
      return AylaGroupApplyDialog(
        group: AylaGroupApplyData(
          id: selectedGroup.id,
          title: selectedGroup.title,
          joinPolicy: selectedGroup.joinPolicy,
          avatar: selectedGroup.avatar,
        ),
        onClose: () => setState(() => _selectedGroup = null),
        onJoined: (String conversationId) {
          setState(() => _selectedGroup = null);
          final String encoded = Uri.encodeComponent(conversationId);
          context.go('/group/$encoded');
        },
      );
    }
    return null;
  }

  Widget _body(bool wide) {
    final AylaSearchResults? results = _resultsScope == _scope ? _results : null;
    final bool single = _filter != 'all';

    if (_q.isEmpty) {
      // tsx 362–373：只有 !q 且历史非空时才渲染（否则内容区为空）
      if (_history.history.isEmpty) return const SizedBox.shrink();
      return AylaSearchHistoryChips(
        history: _history.history,
        query: _q,
        onSelect: _submitQuery,
        onClear: _history.clear,
      );
    }

    final List<Widget> sections = <Widget>[];

    if (_loading) {
      // .search-loading（search.css:32–37 + 目录页组规则左右归零）
      sections.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: AylaSpacing.sp4),
        child: Text(
          '搜索中…', // tsx 375
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AylaColors.textSecondary),
        ),
      ));
    }

    if (_error != null) {
      // .search-error（search.css:39–43）
      sections.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 13,
                color: AylaColors.destructive,
              ),
            ),
            AylaGlassButton(
              label: '重试搜索', // tsx 377
              variant: AylaGlassButtonVariant.ghost,
              onPressed: () => _refreshSearch(_q),
            ),
          ],
        ),
      ));
    }

    if (results != null && results.hasAnyResult) {
      sections.add(Padding(
        // .search-results（search.css:59–66；≥769 时 padding-top 归零）
        padding: EdgeInsets.only(
          top: wide ? 0 : AylaSpacing.sp3,
          bottom: AylaSpacing.sp4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp4,
          children: <Widget>[
            _usersGroup(results, single),
            _groupsGroup(results, single),
            _postsGroup(results, single),
            _gamesGroup(results, single),
            _voicesGroup(results, single),
            _livesGroup(results, single),
          ],
        ),
      ));
    }

    if (results != null &&
        !results.hasAnyResult &&
        !_loading &&
        _error == null) {
      // .search-empty（search.css:46–57；title 字号 20）
      sections.add(Padding(
        // ⚠️ web 的 search.css:47 写的是 `padding: var(--sp-10) var(--sp-4)`，但
        // tokens.css 从未定义 --sp-10 ⇒ **整条声明失效** ⇒ 实际回落到
        // app.css:762 的 `padding: var(--sp-3)`（左右再被 directory-filters.css:171–180
        // 的目录页组规则归零）。这里按真实值表达。
        padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: AylaSpacing.sp3,
          children: <Widget>[
            AylaPlaceholderTitle('未找到「$_q」相关结果', fontSize: 20),
            const AylaPlaceholderDesc('换个关键词试试，或检查是否有拼写错误'),
          ],
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: sections,
    );
  }

  Widget _usersGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaSearchUserItem>? group = results.users;
    final List<AylaSearchUserItem> items =
        group?.items ?? const <AylaSearchUserItem>[];
    return AylaSearchResultGroup(
      title: '用户',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.users]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.users]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.users),
      children: <Widget>[
        for (final AylaSearchUserItem user in items)
          AylaSearchUserRow(
            nickname: user.nickname ?? '',
            username: user.username ?? '',
            signature: user.signature, // tsx 405：有才渲染
            avatarUrl: (user.avatar ?? '').isEmpty ? null : user.avatar,
            online: user.online,
            onOpenProfile: () => _openUserProfile(user),
            onTap: () => setState(() => _selectedUser = user),
          ),
      ],
    );
  }

  Widget _groupsGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaSearchGroupItem>? group = results.groups;
    final List<AylaSearchGroupItem> items =
        group?.items ?? const <AylaSearchGroupItem>[];
    return AylaSearchResultGroup(
      title: '群聊',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.groups]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.groups]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.groups),
      children: <Widget>[
        for (final AylaSearchGroupItem item in items)
          AylaGroupResultCard(
            group: AylaGroupResultData(
              id: item.id,
              title: item.title,
              memberCount: item.memberCount,
              joinPolicy: item.joinPolicy,
              avatar: item.avatar,
            ),
            // tsx 418：已加入 / 已通过 / 申请入群
            entryLabel: _groupIsJoined(item)
                ? '已加入'
                : _acceptedGroupIds.contains(item.id)
                    ? '已通过'
                    : '申请入群',
            onOpen: () {
              if (_groupIsJoined(item)) {
                final String encoded = Uri.encodeComponent(item.id);
                context.go('/group/$encoded');
              } else if (!_acceptedGroupIds.contains(item.id)) {
                setState(() => _selectedGroup = item);
              }
            },
          ),
      ],
    );
  }

  Widget _postsGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaPost>? group = results.posts;
    final List<AylaPost> items = group?.items ?? const <AylaPost>[];
    return AylaSearchResultGroup(
      title: '帖子',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.posts]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.posts]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.posts),
      children: <Widget>[
        for (final AylaPost post in items)
          AylaPostCard(
            post: post,
            previewOnly: true, // tsx 431
            action: null,
            onOpen: () => _openPost(post),
          ),
      ],
    );
  }

  Widget _gamesGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaGameCardData>? group = results.games;
    final List<AylaGameCardData> items =
        group?.items ?? const <AylaGameCardData>[];
    return AylaSearchResultGroup(
      title: '桌游室',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.games]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.games]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.games),
      children: <Widget>[
        for (final AylaGameCardData room in items)
          AylaGameRoomCard(
            room: room,
            showFavorite: false, // tsx 440：action={null}
            onEnter: () => _openRoom(room.id),
          ),
      ],
    );
  }

  Widget _voicesGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaVoiceCardData>? group = results.voices;
    final List<AylaVoiceCardData> items =
        group?.items ?? const <AylaVoiceCardData>[];
    return AylaSearchResultGroup(
      title: '语音房',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.voices]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.voices]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.voices),
      children: <Widget>[
        for (final AylaVoiceCardData channel in items)
          AylaVoiceChannelCard(
            channel: channel,
            browsing: true, // tsx 448
            onEnter: () => _openChannel('/voice', channel.id),
          ),
      ],
    );
  }

  Widget _livesGroup(AylaSearchResults results, bool single) {
    final AylaSearchGroup<AylaLiveCardData>? group = results.lives;
    final List<AylaLiveCardData> items =
        group?.items ?? const <AylaLiveCardData>[];
    return AylaSearchResultGroup(
      title: '直播间',
      count: group?.total ?? 0,
      showTitle: !single,
      hasMore: group?.hasMore ?? false,
      loading:
          _loading || (_pageStatus[AylaSearchResultKey.lives]?.loading ?? false),
      error: _pageStatus[AylaSearchResultKey.lives]?.error,
      onMore: () => _loadMore(AylaSearchResultKey.lives),
      children: <Widget>[
        for (final AylaLiveCardData channel in items)
          AylaLiveChannelCard(
            channel: channel,
            showActions: false, // tsx 455：action={null}
            onEnter: () => _openChannel('/live', channel.id),
          ),
      ],
    );
  }

  /// 打开帖子详情（路由 /posts/:postId）。
  void _openPost(AylaPost post) {
    final String postId = post.id.toString();
    context.go('/posts/$postId');
  }

  /// 打开桌游房（路由 /games/:roomId）。
  void _openRoom(String roomId) {
    final String encoded = Uri.encodeComponent(roomId);
    context.go('/games/$encoded');
  }

  /// 打开语音房 / 直播间（路由前缀由调用方给出）。
  void _openChannel(String prefix, String channelId) {
    final String encoded = Uri.encodeComponent(channelId);
    context.go('$prefix/$encoded');
  }

  /// tsx 357：加载中 / 无查询词 → 省略号；否则「N 条结果」。
  String _searchStatsLabel() {
    if (_loading || _q.isEmpty) return '… 条结果';
    final int total = _results?.totalResults ?? 0;
    return '$total 条结果';
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }

  static String _wireOf(AylaSearchResultKey key) => switch (key) {
        AylaSearchResultKey.users => 'user',
        AylaSearchResultKey.groups => 'group',
        AylaSearchResultKey.posts => 'post',
        AylaSearchResultKey.lives => 'live',
        AylaSearchResultKey.games => 'game',
        AylaSearchResultKey.voices => 'voice',
      };

  static AylaSearchGroup<Object?>? _groupOf(
    AylaSearchResults? results,
    AylaSearchResultKey key,
  ) {
    if (results == null) return null;
    switch (key) {
      case AylaSearchResultKey.users:
        return _wrap<AylaSearchUserItem>(results.users);
      case AylaSearchResultKey.groups:
        return _wrap<AylaSearchGroupItem>(results.groups);
      case AylaSearchResultKey.posts:
        return _wrap<AylaPost>(results.posts);
      case AylaSearchResultKey.lives:
        return _wrap<AylaLiveCardData>(results.lives);
      case AylaSearchResultKey.games:
        return _wrap<AylaGameCardData>(results.games);
      case AylaSearchResultKey.voices:
        return _wrap<AylaVoiceCardData>(results.voices);
    }
  }

  static AylaSearchGroup<Object?>? _wrap<T>(AylaSearchGroup<T>? group) {
    if (group == null) return null;
    return AylaSearchGroup<Object?>(
      items: group.items,
      total: group.total,
      nextCursor: group.nextCursor,
      hasMore: group.hasMore,
    );
  }

  static AylaSearchResults _mergeGroup(
    AylaSearchResults? current,
    AylaSearchResultKey key,
    AylaSearchGroup<Object?> incoming,
  ) {
    final AylaSearchResults base = current ?? const AylaSearchResults();
    switch (key) {
      case AylaSearchResultKey.users:
        return AylaSearchResults(
          users: AylaSearchGroup<AylaSearchUserItem>(
            items: _merge<AylaSearchUserItem>(
              base.users?.items ?? const <AylaSearchUserItem>[],
              incoming.items.cast<AylaSearchUserItem>(),
              (AylaSearchUserItem u) => u.id,
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
          groups: base.groups,
          posts: base.posts,
          lives: base.lives,
          games: base.games,
          voices: base.voices,
        );
      case AylaSearchResultKey.groups:
        return AylaSearchResults(
          users: base.users,
          groups: AylaSearchGroup<AylaSearchGroupItem>(
            items: _merge<AylaSearchGroupItem>(
              base.groups?.items ?? const <AylaSearchGroupItem>[],
              incoming.items.cast<AylaSearchGroupItem>(),
              (AylaSearchGroupItem g) => g.id,
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
          posts: base.posts,
          lives: base.lives,
          games: base.games,
          voices: base.voices,
        );
      case AylaSearchResultKey.posts:
        return AylaSearchResults(
          users: base.users,
          groups: base.groups,
          posts: AylaSearchGroup<AylaPost>(
            items: _merge<AylaPost>(
              base.posts?.items ?? const <AylaPost>[],
              incoming.items.cast<AylaPost>(),
              (AylaPost p) => p.id.toString(),
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
          lives: base.lives,
          games: base.games,
          voices: base.voices,
        );
      case AylaSearchResultKey.lives:
        return AylaSearchResults(
          users: base.users,
          groups: base.groups,
          posts: base.posts,
          lives: AylaSearchGroup<AylaLiveCardData>(
            items: _merge<AylaLiveCardData>(
              base.lives?.items ?? const <AylaLiveCardData>[],
              incoming.items.cast<AylaLiveCardData>(),
              (AylaLiveCardData c) => c.id,
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
          games: base.games,
          voices: base.voices,
        );
      case AylaSearchResultKey.games:
        return AylaSearchResults(
          users: base.users,
          groups: base.groups,
          posts: base.posts,
          lives: base.lives,
          games: AylaSearchGroup<AylaGameCardData>(
            items: _merge<AylaGameCardData>(
              base.games?.items ?? const <AylaGameCardData>[],
              incoming.items.cast<AylaGameCardData>(),
              (AylaGameCardData g) => g.id,
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
          voices: base.voices,
        );
      case AylaSearchResultKey.voices:
        return AylaSearchResults(
          users: base.users,
          groups: base.groups,
          posts: base.posts,
          lives: base.lives,
          games: base.games,
          voices: AylaSearchGroup<AylaVoiceCardData>(
            items: _merge<AylaVoiceCardData>(
              base.voices?.items ?? const <AylaVoiceCardData>[],
              incoming.items.cast<AylaVoiceCardData>(),
              (AylaVoiceCardData c) => c.id,
            ),
            total: incoming.total,
            nextCursor: incoming.nextCursor,
            hasMore: incoming.hasMore,
          ),
        );
    }
  }

  /// 按 id 去重合并（追加页语义：新条目覆盖旧条目，保持旧顺序在前）。
  static List<T> _merge<T>(
    List<T> old,
    List<T> incoming,
    String Function(T item) keyOf,
  ) {
    final Map<String, T> merged = <String, T>{
      for (final T item in old) keyOf(item): item,
    };
    for (final T item in incoming) {
      merged[keyOf(item)] = item;
    }
    return merged.values.toList(growable: false);
  }

  static String _messageOf(Object err) {
    final String text = err.toString();
    final RegExpMatch? m =
        RegExp(r'^[A-Za-z]+\((\d+), (.*)\)$').firstMatch(text);
    return m == null ? text : m.group(2)!;
  }
}
