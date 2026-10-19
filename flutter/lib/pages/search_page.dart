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

import '../core/api/chat_api.dart' show AylaChatApi;
import '../core/api/search_api.dart';
import '../core/api/users_api.dart';
import '../core/models/conversation.dart'
    show AylaConversationSummary;
import '../core/models/post.dart' show AylaPost;
import '../core/models/social_requests.dart' show AylaGroupJoinResult;
import '../core/models/subgroup.dart'
    show AylaGroupApplyData, AylaGroupApplyResult;
import '../core/net/dio_client.dart' show ApiException;
import '../state/auth_state.dart';
import '../state/chat_providers.dart'
    show chatStateProvider, chatWsProvider;
import '../state/search_history.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/dialogs.dart' show AylaModalOverlay;
import '../widgets/base/css_columns.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_result_cards.dart';
import '../widgets/base/page_state.dart';
import '../widgets/base/reveal.dart' show AylaRevealItem, AylaRevealScope;
import '../widgets/base/scroll_restore.dart'
    show AylaScrollMemory, AylaScrollRestore;
import '../widgets/base/profile_and_filters.dart'
    show AylaDirectoryFilters, AylaUserProfileCard;
import '../widgets/game/game_room_card.dart';
import '../widgets/group/group_apply.dart'
    show AylaGroupApplyDialog, AylaGroupApplyException;
import '../widgets/live/live_hall.dart' show AylaLiveChannelCard, AylaLiveCardData;
import '../widgets/posts/post_card.dart' show AylaPostCard;
import 'post_detail_page.dart' show aylaPostSharePayloadFor;
import 'share_support.dart' show AylaShareController, aylaOpenShareSheet;
import '../widgets/search/search_history_chips.dart';
import '../widgets/search/search_result_group.dart';
import '../widgets/search/search_user_row.dart';
import '../widgets/shell/create_sheet.dart' show AylaRootOverlay;
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

/// 逐条浮入的**跨组下标记数器**（web `useListEntryMotion.ts:68–80` 的 `let index = 0`）。
///
/// web 是在**整棵 pageRef 子树**上按 DOM 顺序给命中 selector 的节点连续编号
/// （用户行 → 群卡 → 帖卡 → 桌游卡 → 语音卡 → 直播卡 → 各组页脚按钮），
/// `staggerDelay(index) = min(index*50, 300)` 由此得到（`useRevealOnEnter.ts`）。
/// Flutter 侧六个分组各自知道自己的项数、却不知道全局位次 ⇒ 用一个按调用顺序
/// 递增的计数器在 `_body` 的 build 期串起来（build 顺序 = 树顺序 = DOM 顺序）。
///
/// ⚠️ **顺序纪律**：每组的页脚按钮排在**本组结果项之后**（web DOM 亦如此），所以
/// `footerRevealIndex` 用 [offset] 显式带上本组项数；调用点的书写顺序 = 求值顺序
/// ⇒ 必须写在 `children` 之前（现写法已保证）。
class _RevealIndex {
  int _value = 0;

  /// 取号并前进（列表项）。
  int next() => _value++;

  /// 第 `count` 个位置之后的下标（页脚按钮 = 本组最后一项之后）。
  int offset(int count) => _value + count;
}

class _SearchPageState extends ConsumerState<SearchPage> {
  /// 分享弹窗控制器（2026-10-03：搜索结果的帖子卡此前没传 `onShare` ⇒ 转发键禁用）。
  final AylaShareController _share = AylaShareController();
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

  /// 刷新重播计数（web `replayNonce`，`SearchPage.tsx:102`）。
  ///
  /// web 只在「已有结果时刷新」递增（tsx 181–185：
  /// `if (replacingVisible) { setResumeEntry(true); setReplayNonce(n+1) }`）
  /// ⇒ 已入场结果整批重播一次浮入（`useListEntryMotion.ts:34–55`）；
  /// 首屏（`replacingVisible == false`）不递增，项各自按 [AylaRevealItem] 首次入场。
  int _replayNonce = 0;

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
    // ⚠️ **早退判据必须锚在「上一个 widget 的参数」上，不能锚在本地 state 上**
    // （2026-10-15 用户实报修复：「除了全部以外的选项卡全都是空白」的根因）。
    //
    // 原写法 `if (nextQuery == _q && nextFilter == _filter) return;` 会被
    // [_onFilterChange] 抢先破坏 —— 它**先** `setState(_filter = next)` **再** `context.replace`：
    //   1. 点击「用户」⇒ `_filter` 本地已是 'user'；
    //   2. `context.replace('/search?...&type=user')` ⇒ 本方法被调用；
    //   3. `nextFilter`('user') == `_filter`('user') ⇒ **return 早退**；
    //   4. 于是**既不发新请求、也不重置 `_results`/`_resultsScope`**；
    //   5. `_body` 里 `_resultsScope`('..|all') != `_scope`('..|user') ⇒ `results == null`
    //      ⇒ **内容区空白**；而侧栏 stats 读的仍是旧 `_results.totalResults`
    //      ⇒ 显示上一个分类的条数（用户截图：「用户」tab 高亮却写着「42 条结果」而正文空白）。
    //
    // 正确判据 = 「路由给的参数是否与本 widget 上一次收到的不同」—— 本地 `_filter` 是
    // 用户意图的**即时投影**，不能用来判断「URL 是否变过」。
    final String prevQuery = (oldWidget.initialQuery ?? '').trim();
    final String prevFilter =
        aylaHubFilterOf(SearchPage.filters, oldWidget.initialType);
    if (nextQuery == prevQuery && nextFilter == prevFilter) return;
    // 本地 state 已经跟上（点击路径）⇒ 补齐剩下的「重置 + 重取」即可，避免重复 setState。
    if (nextQuery == _q && nextFilter == _filter) {
      _restore.update(ready: false);
      if (_q.isNotEmpty) _refreshSearch(_q);
      return;
    }
    // tsx 121：搜索词/分类变化前先显式保存当前位置（旧 scope 的键）。
    AylaScrollMemory.save('search:$_scope', _scroll);
    setState(() {
      _q = nextQuery;
      _filter = nextFilter;
      // ⚠️ 清空结果并**把作用域对齐到新的 scope**：两者必须一起做。
      // 若只清 `_results` 而 `_resultsScope` 留旧值（原实现把 `_resultsScope` 设成
      // `_scope`（新值）却没清 `_results`，或反之），就会出现「有 total 却无列表」的半态。
      _results = null;
      _resultsScope = '';
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
    _share.dispose();
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
    // tsx 164：`replacingVisible = resultRef.current != null && activeScope.current === key`
    // —— 「再次搜索同一作用域且已有结果」= 刷新档 ⇒ 完成后整批重播浮入（tsx 181–185）。
    final bool replacingVisible =
        _results != null && _resultsScope == scope;
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
        // tsx 181–185：已有结果时刷新 ⇒ 已入场结果整批重播一次浮入。
        //（`setResumeEntry(true)` 是 web 对 `suppressEntry` 的解除，Flutter 侧
        // 本页尚无滚动恢复抑制档，见文件头登记 ⇒ 只表达重播。）
        if (replacingVisible) _replayNonce += 1;
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
      context.push('/user/$encoded');
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
        context.push('/chat/$encoded');
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
    // ⚠️ **浮层必须挂根 Overlay**（2026-10-09 修「遮罩被顶栏截断」）。
    //
    // 修前：`Stack(children: [page, overlay])` —— 遮罩落在**页内**，
    // 而页面的上边界在顶栏之下（AppShell 是 `Column[TopNav, Expanded(内容), …]`，
    // go_router 又把页面放进 shell navigator 的那层 Overlay）⇒ 实测
    //   宽屏 1526×900：顶栏 (0,0)–(1526,76)，遮罩 **(0,76)–(1526,900)** ❌
    //   窄屏  400×760：顶栏 (0,0)–(400,56)，遮罩 **(0,56)–(400,696)** ❌（上下都被截）
    // 顶栏（窄屏连底部 tab 那条）不被压暗。
    //
    // web 事实源：浮层全部 `createPortal(…, document.body)`，注释原文写明理由
    // ——「调用处（如 ChannelSidebar 的 backdrop-filter 玻璃侧栏）会创建 stacking
    // context，成为 fixed 后代的 containing block → 弹层被裁剪/束缚在容器内」
    // （`ShareSheet.tsx:216`、`GroupApplyDialog` 同族）。本页两个浮层在 web 也都是
    // portal：用户资料浮层 `SearchPage.tsx:472–478` 的 `.user-profile-overlay`
    // （`search.css:304–312` 是 `position: fixed; inset: 0`）+ 入群申请弹窗
    // `SearchPage.tsx:480–489` 的 `<GroupApplyDialog>`（`search.css:180` 同样 fixed）。
    //
    // Flutter 等价物 = `AylaRootOverlay`（`OverlayPortal` +
    // `OverlayChildLocation.rootOverlay`，`widgets/shell/create_sheet.dart`）——
    // **只复用、不改它本体**（它属并行 agent 的写域）。
    //
    // ⚠️ 本页**只需一个** portal：两个浮层在同一时刻最多只有一个（`_overlay()` 的
    // 分支保证），且它们**不会**与第三个同级弹层叠放 ⇒ 不需要像群信息域那样
    // 「收敛为调用方一个 portal + Stack 内部排序」的多层编排。
    return Stack(
      children: <Widget>[
        page,
        AylaRootOverlay(builder: (BuildContext _) => overlay),
      ],
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
        // web 在 `GroupApplyForm` 内直接调 `applyToGroup`（`GroupApplyDialog.tsx:44`）；
        // Flutter 侧按 B5 的注入口径把这一步留给页面层 —— 本处即那个注入点。
        // ⚠️ 此前**未传** ⇒ `group_apply.dart:253` 的提交键永久禁用（用户实报「点不动」）。
        onSubmit: _applyToGroup,
        onJoined: (String conversationId) {
          // web tsx 486–488：只关弹窗 + 跳群；成员关系由 `group.joined` 帧负责。
          setState(() => _selectedGroup = null);
          final String encoded = Uri.encodeComponent(conversationId);
          // ⚠️ **群路由必须用 `go`，不能用 `push`**：群页 5 条路由共用同一个
          // `kAylaGroupShellPageKey`（`router/app_router.dart:91`，为的是切场景不重建整页），
          // 同 key 下 push 会抛 `!keyReservation.contains(key)` 断言 ⇒ **红屏崩溃**
          // （2026-10-19 实机复现）。群内的逐级返回由 `GroupPage` 的 PopScope +
          // 场景历史栈承担（`_popScene`），不依赖路由栈。
          context.go('/group/$encoded');
        },
      );
    }
    return null;
  }

  /// 提交入群申请（web `GroupApplyDialog.tsx:44` 的 `applyToGroup(group.id, message)`）。
  ///
  /// 两态翻译（tsx 45–49）：
  /// - `{status:"accepted", conversation_id}` ⇒ [AylaGroupApplyResult.accepted]
  ///   （表单走 `onDone` ⇒ [onJoined] 跳群）；
  /// - 申请单（待审批）⇒ [AylaGroupApplyResult.pending]
  ///   （表单转「申请已发送」成功态，**不跳转**）。
  ///
  /// 失败抛 [AylaGroupApplyException]，文案取后端 `detail` 原文（web `e.message`）；
  /// 兜底「发送入群申请失败」由表单自己给（`group_apply.dart:143`）。
  /// ⚠️ 两态都不成立（既非 accepted 也没有申请单）⇒ 显式失败，**不伪造成申请成功**。
  Future<AylaGroupApplyResult> _applyToGroup(
    AylaGroupApplyData group,
    String message,
  ) async {
    final AylaGroupJoinResult result;
    try {
      result = await AylaChatApi.applyToGroup(group.id, message: message);
    } on ApiException catch (e) {
      throw AylaGroupApplyException(e.message);
    }
    if (result.accepted) {
      return AylaGroupApplyResult.accepted(result.conversationId!);
    }
    if (result.request != null) {
      return const AylaGroupApplyResult.pending();
    }
    throw const AylaGroupApplyException('入群申请响应格式不合法');
  }

  Widget _body(bool wide) {
    final AylaSearchResults? results = _resultsScope == _scope ? _results : null;
    final bool single = _filter != 'all';

    if (_q.isEmpty) {
      // tsx 362–373：只有 !q 且历史非空时才渲染（否则内容区为空）
      if (_history.history.isEmpty) return const SizedBox.shrink();
      // 历史 chips：web 的 `useListEntryMotion` selector 只含
      // `.search-row, .typed-result-card, .search-group …, .btn`（tsx 119）
      // —— `.search-chip` / `.search-clear` **不在其中** ⇒ 本分支**不挂** reveal。
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
      // web 的逐条浮入 owner 在**页面根**（`useListEntryMotion(pageRef, selector, …)`，
      // `SearchPage.tsx:119`）—— Flutter 侧 `_body` 即那个 root ⇒ Scope 包在这里，
      // `replayKey = _replayNonce` 对应 web 的第四参（刷新后整批重播浮入，tsx 184）。
      //
      // `revealIndex` 是**跨组连续**的 DOM 顺序位次（见 [_RevealIndex]）。
      final _RevealIndex revealIndex = _RevealIndex();
      Widget resultsBlock = Padding(
        // .search-results（search.css:59–66；≥769 时 padding-top 归零）
        padding: EdgeInsets.only(
          top: wide ? 0 : AylaSpacing.sp3,
          bottom: AylaSpacing.sp4,
        ),
        // ---- 「全部」档宽屏：分组级两列 ----
        //
        // web 事实链：`search.css:501–506`（@media min-width:769）给 `.search-results` 加
        // `display: block; columns: 2; column-gap: sp6`；单元 = 6 个 `.search-group`
        // （`search.css:519–523` 的 `break-inside: avoid; margin-bottom: sp4`）。
        // 实测 1440：左列 = 用户/群聊/帖子/桌游室，右列 = 语音房/直播间，列宽 570、列间距 24。
        //
        // ⚠️ 单元间距 16 = `margin-bottom: sp4`（`search.css:522`）；≥769 时 `.search-results`
        //   被覆写为 `display:block` ⇒ 基样式的 `gap: sp4` **失效** ⇒ 只剩 margin 这一份
        //   （实测分组 y 差 = 301.5 + 16 ≈ 318 ✓）。窄屏档仍走基样式的 `Column + gap sp4`。
        //
        // 组间多列**只在「全部」档**：单类档只有一个组，两列会留空列
        //（web 里单类档由 `.search-content:not([data-search-filter="all"])` 的规则改走组内两列）。
        // ⚠️ **空分组不得进 children**（2026-10-15 用户实报「内容区顶部留空都多了」的根因）：
        // web 的 `ResultGroup` 在 `count === 0` 时 **`return null`**（`SearchPage.tsx:503`）
        // ⇒ 该分组**不产生 DOM 节点**，自然不会占用 flex `gap` / multicol `margin`。
        //
        // Flutter 侧若把「空分组」也放进 `children`（哪怕它渲染成 `SizedBox.shrink()`），
        // 外层 `Column(spacing: sp4)` 与 [AylaCssColumns] 的 `itemGap` **照样给它插间距**
        // ⇒ **前面有几个空分组，首张卡就被推下几个 16px**（实测：前导空 child 数 = 1/2/3/4/5
        //   时顶部留空依次为 16/32/48/64/80）。
        //
        // 搜索七档的分组顺序是「用户→群聊→帖子→桌游室→语音房→直播间」，于是单类档的偏移量
        // 正好逐档递增：群聊 +16 · 帖子 +32 · 桌游室 +48 · 语音房 +64 · 直播间 +80
        // —— 与用户截图里「每个 tab 顶部都多一块、且越靠后越多」完全吻合。
        //
        // 判据用 `count != 0`（= `AylaSearchResultGroup` 自己的「整组不渲染」判据），
        // 保证「进 children 的必然会被渲染出来」，两侧语义一致。
        child: (single || !wide)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp4, // `.search-results { gap: sp4 }`
                children: _nonEmptyGroups(results, single, revealIndex, wide),
              )
            : AylaCssColumns(
                columnCount: 2,
                columnGap: AylaSpacing.sp6, // column-gap: var(--sp-6) = 24
                itemGap: AylaSpacing.sp4, // `.search-group { margin-bottom: sp4 }` = 16
                children: _nonEmptyGroups(results, single, revealIndex, wide),
              ),
      );
      sections.add(AylaRevealScope(replayKey: _replayNonce, child: resultsBlock));
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

  /// 六个结果分组的**非空**列表（web `ResultGroup` 的 `if (count === 0) return null` 等价物）。
  ///
  /// ⚠️ **必须在这里过滤，不能在分组内部返回空件**：外层 `Column(spacing:)` / [AylaCssColumns]
  /// 会给「零高的 child」照样插间距 ⇒ 空分组会把首张卡往下推（见调用点的详细注释）。
  ///
  /// `revealIndex` 的取号**只在真正渲染的分组上推进**（与 web 一致：`useListEntryMotion`
  /// 是遍历**实际 DOM 节点**连续编号，未渲染的空分组不占号）。
  List<Widget> _nonEmptyGroups(
    AylaSearchResults results,
    bool single,
    _RevealIndex idx,
    bool wide,
  ) {
    final List<Widget> groups = <Widget>[];
    if ((results.users?.total ?? 0) != 0) {
      groups.add(_usersGroup(results, single, idx, wide));
    }
    if ((results.groups?.total ?? 0) != 0) {
      groups.add(_groupsGroup(results, single, idx, wide));
    }
    if ((results.posts?.total ?? 0) != 0) {
      groups.add(_postsGroup(results, single, idx, wide));
    }
    if ((results.games?.total ?? 0) != 0) {
      groups.add(_gamesGroup(results, single, idx, wide));
    }
    if ((results.voices?.total ?? 0) != 0) {
      groups.add(_voicesGroup(results, single, idx, wide));
    }
    if ((results.lives?.total ?? 0) != 0) {
      groups.add(_livesGroup(results, single, idx, wide));
    }
    return groups;
  }
  Widget _usersGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaSearchUserItem user in items)
          // 逐条浮入：web `useListEntryMotion(pageRef, ".search-row, …", …)`
          // （`SearchPage.tsx:119`）—— selector 命中 `.search-row`（`tsx 391`）。
          // `index` 用**全局位次**（web 在整棵 root 上从 0 连续编号）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaSearchUserRow(
              nickname: user.nickname ?? '',
              username: user.username ?? '',
              signature: user.signature, // tsx 405：有才渲染
              avatarUrl: (user.avatar ?? '').isEmpty ? null : user.avatar,
              online: user.online,
              // ≥769：min-height 64 + padding sp3 sp4（search.css:490–496，带 .search-page 前缀）
              wide: wide,
              onOpenProfile: () => _openUserProfile(user),
              onTap: () => setState(() => _selectedUser = user),
            ),
          ),
      ],
    );
  }

  Widget _groupsGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaSearchGroupItem item in items)
          // 逐条浮入：selector 命中 `.typed-result-card`（`tsx 417` 的群结果卡外包层）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaGroupResultCard(
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
          ),
      ],
    );
  }

  Widget _postsGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaPost post in items)
          // 逐条浮入：selector 命中 `.typed-result-card`（`tsx 430`）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaPostCard(
              post: post,
              previewOnly: true, // tsx 431
              // tsx 431：`action={null}` => **不渲染收藏键**（web `PostCard.tsx:145` 的
              // `action === undefined ? <FavoriteButton/> : action`；null 走 else 支、什么都不画）。
              // 实测 /search?q=1&type=post 的 `.favorite-toggle` 数量 = 0（对照 /posts = 1）。
              action: null,
              showFavorite: false,
              onOpen: () => _openPost(post),
              // ★ 分享键（2026-10-03 补齐）：`post_card.dart:509` 的转发键**恒渲染**
              // （只要非 detail 档），`onShare == null` ⇒ 共享件判禁用、鼠标变禁止符号。
              onShare: () => unawaited(aylaOpenShareSheet(
                context,
                payload: aylaPostSharePayloadFor(post),
                controller: _share,
                currentUserId: ref.read(authNotifierProvider).user?.id,
              )),
            ),
          ),
      ],
    );
  }

  Widget _gamesGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaGameCardData room in items)
          // 逐条浮入：selector 命中 `.typed-result-card`（`tsx 439`）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaGameRoomCard(
              room: room,
              showFavorite: false, // tsx 440：action={null}
              onEnter: () => _openRoom(room.id),
            ),
          ),
      ],
    );
  }

  Widget _voicesGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaVoiceCardData channel in items)
          // 逐条浮入：selector 命中 `.typed-result-card`（`tsx 447`）。
          // ⚠️ 不传 `AylaVoiceChannelCard.revealDelay`：本页的语义是
          // 「外层 typed 卡入场的位移」，与 `AylaVoiceChannelList` 那种
          // 「grid item 自带 reveal-item」不同（`voice.css:518–520` 的注释只针对大厅列表）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaVoiceChannelCard(
              channel: channel,
              browsing: true, // tsx 448
              onEnter: () => _openChannel('/voice', channel.id),
            ),
          ),
      ],
    );
  }

  Widget _livesGroup(AylaSearchResults results, bool single, _RevealIndex idx, bool wide) {
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
      // 单类视图宽屏档：组内结果项分两列（web `search.css:508–511` 的
      // `.search-content:not([data-search-filter="all"]) .search-group-body { columns: 2 }`，
      // 实测项宽 570 = (1164 − 24) / 2、列间距 24）。
      // ⚠️ 单元间距 24 = `gap: sp3`（typed-result-cards.css:134）与
      //   `> * { margin-bottom: sp3 }`（search.css:513–517）**叠加**
      //   （实测相邻项 top 差 90.6 = 66.6 + 24）。
      // 「全部」档组内仍单列 —— 那是**分组级**多列（见 _body 的 AylaCssColumns）。
      columnCount: single && wide ? 2 : 1,
      itemGap: single && wide ? AylaSpacing.sp6 : AylaSpacing.sp3,
      footerRevealIndex: idx.offset(items.length),
      children: <Widget>[
        for (final AylaLiveCardData channel in items)
          // 逐条浮入：selector 命中 `.typed-result-card`（`tsx 454`）。
          AylaRevealItem(
            fadeGlass: false,
            index: idx.next(),
            child: AylaLiveChannelCard(
              channel: channel,
              showActions: false, // tsx 455：action={null}
              onEnter: () => _openChannel('/live', channel.id),
            ),
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
