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
/// ## 成员事件与实时性（2026-10-02 补齐）
/// - tsx 242–287：本页在 chat WS 的 `onFrame` 上消费三帧 ——
///   `group.request.resolved`（`status == accepted` ⇒ 记入「已通过」集合；否则移除）、
///   `group.joined`（成员关系置真 + 从「已通过」集合移除）、
///   `group.member.left`（**仅在 `member_id` 是自己时**把成员关系置假）。
///   实现见 [_SearchPageState._onFrame]；帧载荷见后端
///   `apps/chat/consumers.py` 与 `ws/chat.ts` 的同名分支。
/// - tsx 243–251 / 282–284 / 134–142：成员关系是**带版本的用户级事实**，优先于
///   「更早发出的响应里的 is_member」—— Flutter 侧用 [AylaSearchMembership] 表达
///   （`revision` 单调递增，`membershipChanges` 语义），见 [_SearchPageState._membership];
/// - tsx 336–339：`stale` ⇒ 自动重搜（不打扰用户；`!loading && !error` 才触发）。
///
/// ## 与 web 的机制差异（登记）
/// - tsx 51–65 的 searchPageMemory（跨挂载结果缓存 + 失效）未实现：切页/重进重新搜索；
///   随之 `withCurrentMembership`（tsx 134–142）**只做「响应落地时套用已知成员事实」
///   这一档**（缓存那一档无对象可套）；
/// - 在线判定用 UserPublic.online（后端字段）；presence store 的实时在线属后续批次；
/// - tsx 346 / 121：切换分类与打开结果**前先显式保存**（`saveScrollPosition(scope, …)`）；
/// - **滚动位置记忆已接**（2026-10-02）：web `useScrollRestore(scope, pageRef, { ready: results != null })`
///   （tsx 118）—— Flutter 侧键 = 当前搜索作用域（同 web 的 `scope`），
///   实现见 `widgets/base/scroll_restore.dart`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/search_api.dart';
import '../core/api/users_api.dart';
import '../core/models/conversation.dart'
    show AylaConversationSummary;
import '../core/models/post.dart' show AylaPost;
import '../core/models/subgroup.dart' show AylaGroupApplyData;
import '../state/auth_state.dart';
import '../state/chat_providers.dart'
    show chatStateProvider, chatWsProvider;
import '../state/search_history.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/dialogs.dart' show AylaModalOverlay;
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_result_cards.dart';
import '../widgets/base/page_state.dart';
import '../widgets/base/scroll_restore.dart'
    show AylaScrollMemory, AylaScrollRestore;
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

/// 成员关系事实表（web `membershipChanges` / `membershipRevision`，tsx 105–106）。
///
/// 语义（tsx 243–251 + 134–142）：
/// - 每条事实带**单调递增的版本号**；响应落地时若版本晚于请求发起时刻，
///   就用事实覆盖响应里的 `is_member`（「请求途中发生的成员事件优先于更早的响应」）；
/// - 没有事实时**保持 null**，由 [AylaSearchPageState] 的四级兜底继续往下找
///   （结果内 is_member → 已加入会话集合）；
/// - 值变回「与响应一致」时不删事实（web 只在 `is_member !== undefined` 时删缓存项，
///   `membershipChanges` 本身在 URL effect 里整体清空，见 [_SearchPageState.didUpdateWidget]）。
class AylaSearchMembership {
  final Map<String, ({bool member, int revision})> _facts =
      <String, ({bool member, int revision})>{};

  int _revision = 0;

  /// 当前版本号（请求发起前取一次，落地时比对）。
  int get revision => _revision;

  /// 记一条事实（tsx 244：`membershipChanges.current.set(id, { member, revision: ++membershipRevision.current })`）。
  void record(String groupId, bool member) {
    _facts[groupId] = (member: member, revision: ++_revision);
  }

  /// 取事实（无 = null）；`since` 为请求发起时的版本 ⇒ **更晚的才优先**。
  bool? memberOf(String groupId, {int? since}) {
    final ({bool member, int revision})? fact = _facts[groupId];
    if (fact == null) return null;
    if (since != null && fact.revision <= since) return null;
    return fact.member;
  }

  /// 清空（web URL effect 的整体复位，tsx 303）。
  void clear() {
    _facts.clear();
  }
}

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

  /// 已通过审批的群（tsx 110）：`group.request.resolved(accepted)` 记入、
  /// `group.joined` 与「拒绝」档移除。
  final Set<String> _acceptedGroupIds = <String>{};

  /// 成员关系事实表（tsx 105–106 / 243–251）。
  final AylaSearchMembership _membership = AylaSearchMembership();

  /// 结果已过时 ⇒ 自动重搜（tsx 99 / 186 / 250 / 278 / 336–339）。
  bool _stale = false;

  /// 本次请求发起时的成员事实版本（`membershipAtStart`，tsx 163）。
  int _membershipAtStart = 0;

  /// chat WS 帧解绑（tsx 286 的 `off`）。
  void Function()? _frameOff;

  /// 滚动位置恢复（web `useScrollRestore(scope, …)`，tsx 118）。
  late final AylaScrollRestore _restore;

  int _requestId = 0;

  /// 作用域键（web searchScope 的 q + filter）。
  String get _scope => '$_q|$_filter';

  @override
  void initState() {
    super.initState();
    _history.addListener(_onHistoryChanged);
    _history.load();
    _restore = AylaScrollRestore(
      key: 'search:$_scope',
      controller: _scroll,
      ready: false, // tsx 118：ready = results != null（首帧无结果）
    )..attach();
    // tsx 242–287：成员事件（group.request.resolved / group.joined / group.member.left）。
    _frameOff = ref.read(chatWsProvider).onFrame(_onFrame);
    if (_q.isNotEmpty) _refreshSearch(_q);
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String nextQuery = (widget.initialQuery ?? '').trim();
    final String nextFilter =
        aylaHubFilterOf(SearchPage.filters, widget.initialType);
    if (nextQuery == _q && nextFilter == _filter) return;
    // tsx 121：搜索词/分类变化前先显式保存当前位置（旧 scope 的键）。
    AylaScrollMemory.save('search:$_scope', _scroll);
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
      // tsx 301/303/308：请求序号 +1、成员事实与「已通过」集合整体复位、stale 清掉
      _membership.clear();
      _acceptedGroupIds.clear();
      _stale = false;
    });
    _restore.update(ready: false); // 新 scope 尚无结果
    if (_q.isNotEmpty) _refreshSearch(_q);
  }

  @override
  void dispose() {
    _frameOff?.call();
    _frameOff = null;
    _history.removeListener(_onHistoryChanged);
    _history.dispose();
    _restore.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------- 成员事件（tsx 242–287）

  /// 三帧成员事件（web `ws/chat.ts` 同名分支 + tsx 242–287）。
  ///
  /// ⚠️ 与 web 逐条同一条守卫（tsx 253）：
  /// `if (!active.current || activeScope.current !== scope || searchScope(q, filter) !== scope) return;`
  /// —— 非当前作用域的帧一律丢弃（否则切页后旧帧会污染新结果）。
  void _onFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    switch (rawType) {
      case 'group.request.resolved':
        _onGroupRequestResolved(_dataOf(frame));
      case 'group.joined':
        _onGroupJoined(frame);
      case 'group.member.left':
        _onGroupMemberLeft(_dataOf(frame));
      default:
        return;
    }
  }

  Map<String, dynamic> _dataOf(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  /// `group.request.resolved`（tsx 254–269）。
  void _onGroupRequestResolved(Map<String, dynamic> data) {
    final String conversationId = data['conversation_id']?.toString() ?? '';
    if (conversationId.isEmpty) return;
    final bool accepted = data['status'] == 'accepted';
    setState(() {
      if (accepted) {
        _acceptedGroupIds.add(conversationId);
      } else {
        _acceptedGroupIds.remove(conversationId);
      }
      // tsx 264–269：有查询词时作废结果 + 置 stale（Flutter 侧无跨挂载缓存 ⇒ 只置 stale，
      // 由 [_maybeRefreshStale] 自动重搜，同一效果）。
      if (_q.isNotEmpty) _stale = true;
    });
  }

  /// `group.joined`（tsx 270–281）：成员关系置真 + 从「已通过」移除。
  void _onGroupJoined(Map<String, dynamic> frame) {
    final Object? rawConv = frame['conversation'];
    if (rawConv is! Map) return;
    final String id = rawConv['id']?.toString() ?? '';
    if (id.isEmpty) return;
    setState(() {
      _membership.record(id, true);
      _acceptedGroupIds.remove(id);
      if (_q.isNotEmpty) _stale = true;
    });
  }

  /// `group.member.left`（tsx 282–284）：**仅本人**离开才把成员关系置假。
  void _onGroupMemberLeft(Map<String, dynamic> data) {
    final String? me = ref.read(authNotifierProvider).user?.id;
    if (me == null || me.isEmpty) return;
    if (data['member_id']?.toString() != me) return;
    final String conversationId = data['conversation_id']?.toString() ?? '';
    if (conversationId.isEmpty) return;
    setState(() => _membership.record(conversationId, false));
  }

  /// tsx 336–339：`if (stale && q.trim() && !loading && !error) refreshSearch(q);`
  ///
  /// 在 build 的帧后回调里求值（Flutter 无 React 的 effect 时机）——调用时先清
  /// `_stale`，由 `_refreshSearch` 按 `membershipChangedDuringRequest` 决定是否置回，
  /// 因此「刷新期间再来成员事件 ⇒ 继续刷到稳定」与 web 同，且不会自激循环。
  void _maybeRefreshStale() {
    if (!mounted) return;
    if (!_stale || _q.trim().isEmpty || _loading || _error != null) return;
    _stale = false;
    unawaited(_refreshSearch(_q));
  }

  /// 按已知成员事实覆盖响应里的 `is_member`（tsx 134–142 的 `withCurrentMembership`，
  /// 只保留「事实」这一档：请求发起前的旧事实不覆盖）。
  AylaSearchResults _withCurrentMembership(AylaSearchResults response) {
    final AylaSearchGroup<AylaSearchGroupItem>? groups = response.groups;
    if (groups == null) return response;
    return AylaSearchResults(
      users: response.users,
      groups: AylaSearchGroup<AylaSearchGroupItem>(
        items: <AylaSearchGroupItem>[
          for (final AylaSearchGroupItem g in groups.items)
            if (_membership.memberOf(g.id, since: _membershipAtStart)
                case final bool member)
              AylaSearchGroupItem(
                id: g.id,
                title: g.title,
                isMember: member,
                avatar: g.avatar,
                memberCount: g.memberCount,
                joinPolicy: g.joinPolicy,
                createdAt: g.createdAt,
              )
            else
              g,
        ],
        total: groups.total,
        nextCursor: groups.nextCursor,
        hasMore: groups.hasMore,
      ),
      posts: response.posts,
      lives: response.lives,
      games: response.games,
      voices: response.voices,
    );
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
    // tsx 163：请求发起时的成员事实版本（请求途中发生的成员事件优先于本响应）。
    _membershipAtStart = _membership.revision;
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
      // tsx 179：请求途中是否发生过成员事件（版本号被推进）。
      final bool membershipChangedDuringRequest =
          _membership.revision > _membershipAtStart;
      setState(() {
        // tsx 180 + 134–142：落地前套用请求途中产生的成员事实。
        _results = _withCurrentMembership(next);
        _resultsScope = scope;
        // tsx 186：`setStale(membershipChangedDuringRequest)` —— 请求途中发生过成员事件
        // 就**保持 stale**，由 [_maybeRefreshStale] 再刷一轮，直到数据稳定
        //（web 原话 tsx 334–336）；没有成员事件则清掉。
        _stale = membershipChangedDuringRequest;
      });
      _restore.update(ready: true); // tsx 118：ready = results != null
    } catch (err) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = err is Exception ? _messageOf(err) : '搜索失败';
        // 真实错误停止自动刷新（web 原话，tsx 334–336）——stale 留待用户重试。
        _stale = false;
      });
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
        // tsx 211：续页同样套用成员事实（`withCurrentMembership(response, membershipAtStart)[type]`）。
        final AylaSearchResults patched = _withCurrentMembership(response);
        final AylaSearchGroup<Object?>? patchedGroup = _groupOf(patched, key);
        _results = _mergeGroup(
          _results,
          key,
          patchedGroup ?? incoming,
        );
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

  /// tsx 144–148 的四级兜底（**逐级短路，事实优先于响应**）：
  /// 1. 成员事实（[AylaSearchMembership]，用户级、带版本）；
  /// 2. 当前结果内的同 id 条目（`resultRef.current?.groups?.items.find(...)?.is_member`；
  ///    本页每条结果只渲染一次 ⇒ 与第 3 级同值，保留它的理由是 tsx 159–194 的
  ///    续页合并路径下结果表可能比传入的条目更新 —— Flutter 侧 `_results` 就是那张表，
  ///    故这里显式查表而不是直接用 `group.isMember`）；
  /// 3. 传入条目自身的 `is_member`；
  /// 4. 已加入会话集合（chat store 的群会话 id；web `joinedConversationIds` tsx 82–85）。
  ///
  /// ⚠️ **第 3/4 级之间 web 还有 `group.is_member` 的 undefined 判定**：
  /// tsx 146 的 `?? group.is_member` 对 `undefined` 会继续往下；
  /// Flutter 的 [AylaSearchGroupItem.isMember] 已是 `bool?`（undefined ↔ null 同形）⇒ 一致。
  bool _groupIsJoined(AylaSearchGroupItem group) {
    final bool? fact = _membership.memberOf(group.id);
    if (fact != null) return fact;
    final AylaSearchGroupItem? inResults = _groupInResults(group.id);
    if (inResults?.isMember != null) return inResults!.isMember!;
    if (group.isMember != null) return group.isMember!;
    return _joinedConversationIds.contains(group.id);
  }

  AylaSearchGroupItem? _groupInResults(String id) {
    for (final AylaSearchGroupItem item
        in _results?.groups?.items ?? const <AylaSearchGroupItem>[]) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 当前用户已加入的群会话 id（web `joinedConversationIds`，tsx 82–85）。
  Set<String> get _joinedConversationIds => <String>{
        for (final AylaConversationSummary c
            in ref.read(chatStateProvider).conversations)
          if (c.isGroup) c.id,
      };

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final bool wide = !narrow;

    // tsx 118：ready = results != null（当前作用域）。active 恒真 —— 搜索结果区
    // 与浮层是**同一页**（web 的 pageRef 也只在浮层打开时才可能被遮挡，不卸载）。
    _restore.update(ready: (_resultsScope == _scope ? _results : null) != null);
    // tsx 336–339：stale ⇒ 自动重搜（帧后求值，避免 build 中触发请求）。
    if (_stale) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _maybeRefreshStale();
      });
    }

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
        fadeGlass: false,
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
        // .search-history 基样式 padding sp3 sp4 sp3（search.css:11–17）+ 目录页组规则：
        // 左右**恒 0**（directory-filters.css:171–180，该规则不在媒体查询内）；
        // 它**不在** 199–208 的顶部归零名单内 ⇒ 顶部保持 sp3（宽窄同值）。
        padding: aylaDirectoryListPadding(context, zeroTopWhenWide: false),
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

  /// 打开结果前显式保存滚动位置（web `openPath`，tsx 120–123：
  /// `saveScrollPosition(scope, pageRef.current); navigate(path);`）。
  void _openPath(String path) {
    AylaScrollMemory.save('search:$_scope', _scroll);
    context.go(path);
  }

  /// 打开帖子详情（路由 /posts/:postId）。
  void _openPost(AylaPost post) => _openPath('/posts/$post.id');

  /// 打开桌游房（路由 /games/:roomId）。
  void _openRoom(String roomId) =>
      _openPath('/games/${Uri.encodeComponent(roomId)}');

  /// 打开语音房 / 直播间（路由前缀由调用方给出）。
  void _openChannel(String prefix, String channelId) =>
      _openPath('$prefix/${Uri.encodeComponent(channelId)}');

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
