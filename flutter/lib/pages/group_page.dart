/// 群聊场景容器页（路由 `/group/:id` 及四个子路由）—— web `pages/GroupPage.tsx`（539 行）
/// 的等价物。
///
/// ## 双形态装配（tsx 405–496）
/// - **宽屏（>768）**：`ServerRail` + `ChannelSidebar` + `group-content` 三列，
///   内容区由 [AylaConversationTransition]（`identity = "group:<id>"`，tsx 429–431）编排；
/// - **窄屏（≤768）**：`GroupTopTabs`（从原底栏位置连续升至顶部，300ms）+ 场景层；
///   壳层在群路由**不出 BottomTabs**（`router/shell_config.dart` 的 `aylaIsGroupScene`），
///   与 tsx 的「底栏本体升上去」等价。
///
/// ## 单一状态源（tsx 215–245）
/// `activeScene` 存 `state/group_state.dart`（= web `stores/group`）；route param 变化时
/// **一处 effect** 同步 store；切场景走 `setActiveScene + go`（store 是交互事实源、URL 是回显）。
/// 宽屏用 [effectiveScene]（新群首帧就按当前路由渲染，避免 effect 同步前把旧群场景挂到新群），
/// 窄屏用 store 的 `activeScene`（tsx 227 `contentScene`）。
///
/// ## 手势（窄屏）
/// - **下拉回主页**（R-G6 / §2.3）：阈值 80px（tsx 64），跟手 1:1 + 内容 scale 1→0.98 /
///   opacity 1→0.6 视差，回弹 200ms `--ease-out`，过阈值退场 250ms `--ease-in` 后 `/group`；
/// - **横滑切场景**（§2.2）：松手判定用 [aylaResolveSwipeCommit]（净位移 ≥ 宽/3 优先，
///   同向甩动 ≥300px/s 且净位移 ≥40px 补充，交叉轴占优让位）；
///   位移层 `dragElastic 0.8`（跟手 80%）；
/// - 场景切换动画：web 的 variants 进/出场**横向位移都是 0**（`GroupPage.tsx:507–511`）
///   ⇒ 只有**淡出**（旧场景 300ms 淡出、新场景直接显示），由 [_AylaSceneFade] 表达。
///
/// ## 与 web 的机制差异（登记）
/// 1. **路由守卫卡片不实现**（用户裁决，见 13 号 B5）：web 在「非成员 + summary 403」时
///    渲染 `GroupApplyGate` 申请卡片（tsx 394–403）；Flutter 侧该组件按裁决未建 ⇒
///    直达未加入群时页面按「加载失败 / 空态」呈现，不做守卫卡。
/// 2. **场景切换重叠**：web 用 `AnimatePresence mode="sync"` 让新旧场景同帧重叠；
///    Flutter 用 [Stack] + 单条淡出曲线表达同一效果（新场景无淡入 —— 与 web 的
///    `enter/center` 变体一致）。
/// 3. `useTouchAxisGuard`（起步 slop 内压制浏览器垂直滚动接管）无 Flutter 等价需求：
///    Flutter 的手势竞技场本身按方向锁定，不存在 `pointercancel` 夺轴问题。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/conversation.dart';
import '../core/models/subgroup.dart';
import '../state/chat_providers.dart' show chatStateProvider;
import '../state/chat_state.dart' show AylaChatState;
import '../state/group_providers.dart';
import '../state/subgroup_state.dart' show AylaSubGroupState;
import '../state/group_state.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart' show liveStateProvider, voiceStateProvider;
import '../state/voice_state.dart';
import '../theme/tokens.dart';
import '../widgets/base/directory_page.dart' show aylaDirectoryIsWide;
import '../widgets/group/group_create_dialog.dart' show AylaGroupCreateDialog;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/motion/gestures.dart' show AylaConversationTransition;
import '../widgets/shell/channel_sidebar.dart';
import '../widgets/shell/group_top_tabs.dart';
import '../widgets/shell/server_rail.dart';
import 'group_chat_page.dart';
import 'group_games_page.dart';
import 'group_info_page.dart';
import 'group_live_page.dart';
import 'group_posts_page.dart';
import 'group_support.dart';
import 'group_voice_page.dart';

/// 下拉回主页阈值与退场时长（web `GroupPage.tsx:64–65`）。
const double kAylaGroupPullExitThreshold = 80;
const int kAylaGroupExitTransitionMs = 250;

/// 甩动阈值（web `hooks/useSwipeCommit.ts:33/36`）。
const double kAylaSwipeFlickVelocity = 300;
const double kAylaSwipeMinFlickDistance = 40;

/// 松手切换判定（web `resolveSwipeCommit`，units: px / px·s⁻¹）。
int aylaResolveSwipeCommit({
  required double net,
  required double cross,
  required double velocity,
  required double size,
  double? threshold,
  double flickVelocity = kAylaSwipeFlickVelocity,
  double minFlickDistance = kAylaSwipeMinFlickDistance,
}) {
  // 方向锁让位：交叉轴净位移占优 ⇒ 本次手势不属于切页。
  if (cross.abs() >= net.abs()) return 0;
  final double distance = net.abs();
  final bool forward = net < 0; // 左滑 → 下一个
  if (distance >= (threshold ?? size / 3)) return forward ? 1 : -1;
  if (velocity.abs() >= flickVelocity &&
      distance >= minFlickDistance &&
      velocity.sign == net.sign) {
    return forward ? 1 : -1;
  }
  return 0;
}

/// 群场景索引（web `useSceneSwipeDirection.ts:17–19`：`info` 按 `chat` 处理）。
int aylaGroupSceneOrderIndex(AylaGroupScene scene) {
  final AylaGroupScene normalized =
      scene == AylaGroupScene.info ? AylaGroupScene.chat : scene;
  return kAylaGroupSceneOrder.indexOf(normalized);
}

/// 场景切换方向（web `sceneDirection`）。
int aylaGroupSceneDirection(AylaGroupScene from, AylaGroupScene to) {
  final int diff = aylaGroupSceneOrderIndex(to) - aylaGroupSceneOrderIndex(from);
  return diff > 0 ? 1 : (diff < 0 ? -1 : 0);
}

class GroupPage extends ConsumerStatefulWidget {
  const GroupPage({
    super.key,
    required this.groupId,
    this.scene,
    this.postId,
    this.voiceChannelId,
    this.liveChannelId,
  });

  final String groupId;
  final String? scene;
  final String? postId;
  final String? voiceChannelId;
  final String? liveChannelId;

  @override
  ConsumerState<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends ConsumerState<GroupPage> {
  AylaGroupDirectory? _directory;
  AylaPagedList<AylaSubGroup>? _subgroups;
  AylaPagedList<AylaDirectoryVoiceEntry>? _voice;
  AylaPagedList<AylaDirectoryLiveEntry>? _live;
  bool _showGroupCreate = false;

  /// 已同步过的 (群, 场景) —— 只在变化时写 store（web tsx 229–245 的 effect）。
  String? _syncedGroupId;
  AylaGroupScene? _syncedScene;

  // ---- 窄屏手势状态 ----
  bool _entered = false;
  bool _leaving = false;
  Timer? _leaveTimer;
  double _pullDy = 0;
  double _pullOpacity = 1;
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    _directory = AylaGroupDirectory(chatState: ref.read(chatStateProvider))
      ..addListener(_onChanged);
    _subgroups = AylaPagedList<AylaSubGroup>(
      // `listSubgroupsPage` 的响应多带一个 `default` 字段（[AylaSubgroupPage]）；
      // 本列表只消费 results/游标/总数 ⇒ 这里投影成通用游标页。
      request: (String? cursor) async {
        final AylaSubgroupPage page = await AylaChatApi.listSubgroupsPage(
          widget.groupId,
          cursor: cursor,
        );
        return AylaDirectoryPage<AylaSubGroup>(
          results: page.results,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          total: page.total,
        );
      },
      keyOf: (AylaSubGroup sg) => sg.id,
    )..addListener(_onChanged);
    _voice = AylaPagedList<AylaDirectoryVoiceEntry>(
      request: (String? cursor) => AylaVoiceApi.listVoiceChannelsPage(
        cursor: cursor,
        groupId: widget.groupId,
      ),
      keyOf: (AylaDirectoryVoiceEntry e) => e.card.id,
    )..addListener(_onChanged);
    _live = AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) => AylaLiveApi.listLiveChannelsPage(
        cursor: cursor,
        groupId: widget.groupId,
      ),
      keyOf: (AylaDirectoryLiveEntry e) => e.card.id,
    )..addListener(_onChanged);
    // 子群列表落库后同步到状态层（默认组兜底，web tsx 265–272）。
    _subgroups!.addListener(_syncSubgroups);
    unawaited(_subgroups!.load());
    unawaited(_voice!.load());
    unawaited(_live!.load());
    // 顶栏从原底栏位置升到顶部（web useEnterGroupAnimation 的「首帧后再进入」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    _subgroups?.removeListener(_syncSubgroups);
    _subgroups?.removeListener(_onChanged);
    _subgroups?.dispose();
    _voice?.removeListener(_onChanged);
    _voice?.dispose();
    _live?.removeListener(_onChanged);
    _live?.dispose();
    _directory?.removeListener(_onChanged);
    _directory?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 子群列表 → 状态层（web `GroupPage.tsx:265–283`）：
  /// 未选中时取服务端标出的默认组（缺席时退回列表里 `is_default` 的第一项）。
  void _syncSubgroups() {
    final AylaPagedList<AylaSubGroup>? pager = _subgroups;
    if (pager == null || !pager.loaded) return;
    final AylaSubGroupState state = ref.read(subgroupStateProvider);
    if (state.subgroupsOf(widget.groupId).isEmpty &&
        pager.items.isNotEmpty) {
      state.setSubgroups(widget.groupId, pager.items);
    }
    if (state.activeSubgroupOf(widget.groupId) != null) return;
    for (final AylaSubGroup sg in state.subgroupsOf(widget.groupId)) {
      if (sg.isDefault) {
        state.setActiveSubgroup(widget.groupId, sg.id);
        return;
      }
    }
  }

  /// route param → store（web tsx 229–245）。只在值变化时写，避免 build 期间通知。
  void _syncRoute(AylaGroupScene effectiveScene) {
    if (_syncedGroupId == widget.groupId && _syncedScene == effectiveScene) {
      return;
    }
    _syncedGroupId = widget.groupId;
    _syncedScene = effectiveScene;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AylaGroupState group = ref.read(groupStateProvider);
      group.setCurrentGroup(widget.groupId);
      group.setActiveScene(effectiveScene);
      // 非 chat 子场景显式关闭会话（web tsx 241–243：只有真的在聊天窗口里才自动已读）。
      if (effectiveScene != AylaGroupScene.chat &&
          ref.read(chatStateProvider).activeConversationId == widget.groupId) {
        ref.read(chatStateProvider).closeConversation();
      }
    });
  }

  /// 切场景：store + URL 回显（web tsx 286–292）。
  void _goScene(AylaGroupScene next) {
    ref.read(groupStateProvider).setActiveScene(next);
    final String id = Uri.encodeComponent(widget.groupId);
    context.go(next == AylaGroupScene.chat ? '/group/$id' : '/group/$id/${next.name}');
  }

  /// 打开群信息（web tsx 294–297）。
  void _openInfo() => _goScene(AylaGroupScene.info);

  /// 群头像两级点击（R-G4，tsx 317–324）：已在聊天 → 群信息；否则 → 回聊天。
  void _onAvatarClick(AylaGroupScene current) {
    if (current == AylaGroupScene.chat) {
      _openInfo();
    } else {
      _goScene(AylaGroupScene.chat);
    }
  }

  /// 下拉回主页（web tsx 120–135）：清 store + 退场 250ms 后回 `/group`。
  void _pullToHome() {
    setState(() {
      _pullDy = 0;
      _pullOpacity = 1;
      _leaving = true;
    });
    ref.read(groupStateProvider).reset();
    _leaveTimer?.cancel();
    _leaveTimer = Timer(
      const Duration(milliseconds: kAylaGroupExitTransitionMs),
      () {
        if (mounted) context.go('/group');
      },
    );
  }

  Widget _renderScene(AylaGroupScene scene) {
    switch (scene) {
      case AylaGroupScene.info:
        return GroupInfoPage(groupId: widget.groupId);
      case AylaGroupScene.chat:
        return GroupChatPage(groupId: widget.groupId);
      case AylaGroupScene.live:
        return GroupLivePage(
          groupId: widget.groupId,
          routeChannelId: widget.liveChannelId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.voice:
        return GroupVoicePage(
          groupId: widget.groupId,
          routeChannelId: widget.voiceChannelId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.posts:
        return GroupPostsPage(
          groupId: widget.groupId,
          postId: widget.postId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.games:
        return GroupGamesPage(
          groupId: widget.groupId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isNarrow = !aylaDirectoryIsWide(context);
    final AylaGroupState groupState = ref.watch(groupStateProvider);
    final AylaChatState chat = ref.watch(chatStateProvider);
    final AylaSubGroupState subgroups = ref.watch(subgroupStateProvider);
    final AylaVoiceState voice = ref.watch(voiceStateProvider);
    final AylaLiveState live = ref.watch(liveStateProvider);
    final AylaGroupScene effectiveScene = aylaGroupSceneFromRoute(
      scene: widget.scene,
      postId: widget.postId,
      voiceChannelId: widget.voiceChannelId,
      liveChannelId: widget.liveChannelId,
    );
    _syncRoute(effectiveScene);
    // 宽屏渲染路由场景（新群首帧即正确），窄屏用 store（tsx 227）。
    final AylaGroupScene contentScene =
        isNarrow ? groupState.activeScene : effectiveScene;
    final AylaConversationSummary? currentGroup =
        chat.byId(widget.groupId);
    final String groupName = currentGroup?.title ?? '群聊';

    if (isNarrow) {
      return _buildNarrow(context, groupState, contentScene, groupName, currentGroup);
    }
    return _buildWide(
      context,
      chat,
      subgroups,
      voice,
      live,
      contentScene,
      groupName,
      currentGroup,
    );
  }

  // ======================= 宽屏三列（tsx 405–436）=======================

  Widget _buildWide(
    BuildContext context,
    AylaChatState chat,
    AylaSubGroupState subgroups,
    AylaVoiceState voice,
    AylaLiveState live,
    AylaGroupScene contentScene,
    String groupName,
    AylaConversationSummary? currentGroup,
  ) {
    final List<AylaConversationSummary> groups =
        _directory?.groupsWith(widget.groupId) ??
            const <AylaConversationSummary>[];
    // 排序按「新内容」事件（web tsx 205–209 + groupActivity.ts:238–259）。
    final List<AylaConversationSummary> sorted =
        aylaSortGroupsByActivity(
      groups,
      (AylaConversationSummary c) => aylaGroupActivityOf(
        groupId: c.id,
        lastMessage: c.lastMessage,
        liveChannels: live.channels.values,
        voiceChannels: voice.channels.values,
        groupActivityAt: chat.groupActivityAt,
      ),
    );
    return Stack(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AylaServerRail(
              groups: aylaServerRailGroups(
                groups: sorted,
                liveChannels: live.channels.values,
                voiceChannels: voice.channels.values,
              ),
              currentGroupId: widget.groupId,
              onSelectGroup: (String gid) =>
                  context.go('/group/${Uri.encodeComponent(gid)}'),
              onCreateGroup: () => setState(() => _showGroupCreate = true),
              loadMore: () => _directory?.loadMore() ?? Future<void>.value(),
              refresh: () => _directory?.refresh() ?? Future<void>.value(),
              loading: _directory?.loading ?? false,
              error: _directory?.error,
              hasMore: _directory?.hasMore ?? false,
              invalidated: _directory?.invalidated ?? false,
            ),
            AylaChannelSidebar(
              groupId: widget.groupId,
              groupName: groupName,
              activeScene: contentScene,
              onSelectScene: _goScene,
              onOpenInfo: _openInfo,
              subgroups: <AylaChannelSubgroup>[
                for (final AylaSubGroup sg
                    in subgroups.subgroupsOf(widget.groupId))
                  AylaChannelSubgroup(
                    id: sg.id,
                    name: sg.name,
                    isDefault: sg.isDefault,
                    muted: sg.muted ?? false,
                    unreadCount: sg.unreadCount,
                    lastMessageSeq: sg.lastMessageSeq ?? 0,
                  ),
              ],
              activeSubgroupId: subgroups.activeSubgroupOf(widget.groupId),
              onSelectSubgroup: (String sgId) => ref
                  .read(subgroupStateProvider)
                  .setActiveSubgroup(widget.groupId, sgId),
              subgroupDirectory: _channelDirectory(_subgroups),
              // 子群编辑入口 = 群主/管理员（web `ChannelSidebar.tsx:139` 同源）。
              canManageSubgroups: _canManage(currentGroup),
              voiceRooms: <AylaChannelVoiceRoom>[
                for (final AylaDirectoryVoiceEntry entry
                    in _voice?.items ?? const <AylaDirectoryVoiceEntry>[])
                  AylaChannelVoiceRoom(
                    id: entry.card.id,
                    name: entry.card.name,
                    memberCount: entry.card.memberCount ?? 0,
                  ),
              ],
              activeVoiceChannelId: widget.voiceChannelId,
              onSelectVoiceChannel: _openVoiceChannel,
              voiceMemberCount: _voiceMemberCount(voice),
              voiceDirectory: _channelDirectory(_voice),
              liveRooms: <AylaChannelLiveRoom>[
                for (final AylaDirectoryLiveEntry entry
                    in _live?.items ?? const <AylaDirectoryLiveEntry>[])
                  AylaChannelLiveRoom(
                    id: int.tryParse(entry.card.id) ?? 0,
                    title: entry.card.title,
                    cover: entry.card.cover,
                    isLive: entry.card.status == AylaLiveStatus.live,
                  ),
              ],
              activeLiveChannelId: widget.liveChannelId,
              onSelectLiveChannel: (int id) => _openLiveChannel('$id'),
              liveDirectory: _channelDirectory(_live),
              postUnread: currentGroup?.postUnreadCount ?? 0,
              playing: false,
            ),
            Expanded(
              child: AylaConversationTransition(
                identity: 'group:${widget.groupId}',
                builder: (BuildContext context, String identity) =>
                    _renderScene(contentScene),
              ),
            ),
          ],
        ),
        if (_showGroupCreate)
          Positioned.fill(
            child: AylaGroupCreateDialog(
              onClose: () => setState(() => _showGroupCreate = false),
            ),
          ),
        if (_directory?.error != null && (_directory?.raw.isEmpty ?? true))
          const SizedBox.shrink(),
      ],
    );
  }

  static bool _canManage(AylaConversationSummary? conv) =>
      conv?.myRole == AylaConversationMemberRole.owner ||
      conv?.myRole == AylaConversationMemberRole.admin;

  /// 「语音在麦人数」——web 侧栏场景项的状态文本（`ChannelSidebar.tsx:271`）；
  /// 取**当前群下有人房间**的在麦总数（无人 = 0 ⇒ 不显示裸文本，`voiceMemberCount > 0` 才渲染）。
  int _voiceMemberCount(AylaVoiceState voice) => voice.channels.values
      .where((AylaVoiceChannelSnapshot c) =>
          c.allowedGroupIds.contains(widget.groupId))
      .fold<int>(0, (int sum, AylaVoiceChannelSnapshot c) =>
          sum + (c.memberCount ?? 0));

  AylaChannelDirectory _channelDirectory<T>(AylaPagedList<T>? pager) {
    if (pager == null) return AylaChannelDirectory.none;
    return AylaChannelDirectory(
      total: pager.total,
      loading: pager.loading,
      error: pager.error,
      hasMore: pager.hasMore,
      invalidated: pager.invalidated,
      loadMore: pager.loadMore,
      refresh: pager.refresh,
    );
  }

  void _openVoiceChannel(String channelId) {
    ref.read(groupStateProvider).setActiveScene(AylaGroupScene.voice);
    context.go(
      '/group/${Uri.encodeComponent(widget.groupId)}/voice/'
      '${Uri.encodeComponent(channelId)}',
    );
  }

  void _openLiveChannel(String channelId) {
    ref.read(groupStateProvider).setActiveScene(AylaGroupScene.live);
    context.go(
      '/group/${Uri.encodeComponent(widget.groupId)}/live/'
      '${Uri.encodeComponent(channelId)}',
    );
  }

  // ======================= 窄屏（tsx 438–496）=======================

  Widget _buildNarrow(
    BuildContext context,
    AylaGroupState groupState,
    AylaGroupScene contentScene,
    String groupName,
    AylaConversationSummary? currentGroup,
  ) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final double viewportHeight = MediaQuery.sizeOf(context).height;
    final double safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    // 首帧的顶栏位置 = 原底栏位置（web tsx 455：`100dvh - 64px - safe-area`）。
    final double hiddenDy = viewportHeight - 64 - safeBottom;
    final double progress =
        (_pullDy / kAylaGroupPullExitThreshold).clamp(0.0, 1.0);

    double tabsDy;
    Duration tabsDuration;
    Curve tabsCurve;
    if (reduced) {
      tabsDy = 0;
      tabsDuration = Duration.zero;
      tabsCurve = Curves.linear;
    } else if (_leaving) {
      tabsDy = hiddenDy;
      tabsDuration = const Duration(milliseconds: kAylaGroupExitTransitionMs);
      tabsCurve = AylaCurves.easeIn;
    } else if (_pullDy > 0) {
      tabsDy = _pullDy;
      tabsDuration = Duration.zero;
      tabsCurve = Curves.linear;
    } else {
      tabsDy = _entered ? 0 : hiddenDy;
      tabsDuration = AylaDurations.auroraqua;
      tabsCurve = AylaCurves.auroraquaEaseOut;
    }

    return Column(
      children: <Widget>[
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: tabsDy),
          duration: tabsDuration,
          curve: tabsCurve,
          builder: (BuildContext context, double value, Widget? child) =>
              AylaGroupTopTabs(
            groupName: groupName,
            activeScene: contentScene,
            avatarUrl: (currentGroup?.avatar.isEmpty ?? true)
                ? null
                : currentGroup!.avatar,
            onSelectScene: _goScene,
            onAvatarClick: () => _onAvatarClick(groupState.activeScene),
            postUnread: currentGroup?.postUnreadCount ?? 0,
            offset: Offset(0, value),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (DragUpdateDetails details) =>
                _onPullUpdate(details, reduced),
            onVerticalDragEnd: (DragEndDetails details) =>
                _onPullEnd(details, reduced),
            onVerticalDragCancel: _resetPull,
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (reduced || _leaving) return;
              setState(() {
                _dragDx += details.delta.dx;
                _dragDy += details.delta.dy;
              });
            },
            onHorizontalDragEnd: (DragEndDetails details) =>
                _onSceneDragEnd(details, contentScene, reduced),
            onHorizontalDragCancel: () => setState(() {
              _dragDx = 0;
              _dragDy = 0;
            }),
            child: ClipRect(
              child: Transform.translate(
                offset: Offset(reduced ? 0 : _dragDx * 0.8, _pullDy),
                child: Transform.scale(
                  scale: 1 - 0.02 * progress,
                  child: Opacity(
                    opacity: _pullOpacity,
                    child: _AylaSceneFade(
                      scene: contentScene,
                      builder: _renderScene,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 下拉跟手（web tsx 145–152）：只在向下拉时位移，上推不跟手。
  void _onPullUpdate(DragUpdateDetails details, bool reduced) {
    if (reduced || _leaving) return;
    final double next = _pullDy + details.delta.dy;
    if (details.delta.dy <= 0 && next <= 0) return;
    setState(() {
      _pullDy = next < 0 ? 0 : next;
      final double p =
          (_pullDy / kAylaGroupPullExitThreshold).clamp(0.0, 1.0);
      _pullOpacity = 1 - 0.4 * p;
    });
  }

  /// 松手：过阈值且向下 ⇒ 回主页；否则 200ms `--ease-out` 回弹（web tsx 153–169）。
  void _onPullEnd(DragEndDetails details, bool reduced) {
    if (reduced || _leaving) return;
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity > 0 && _pullDy >= kAylaGroupPullExitThreshold) {
      _pullToHome();
      return;
    }
    _resetPull();
  }

  void _resetPull() {
    if (_pullDy == 0 && _pullOpacity == 1) return;
    setState(() {
      _pullDy = 0;
      _pullOpacity = 1;
    });
  }

  /// 横滑切场景（web tsx 355–372）：松手判定走 [aylaResolveSwipeCommit]。
  void _onSceneDragEnd(
    DragEndDetails details,
    AylaGroupScene contentScene,
    bool reduced,
  ) {
    final double width = MediaQuery.sizeOf(context).width;
    final double net = _dragDx;
    final double cross = _dragDy;
    setState(() {
      _dragDx = 0;
      _dragDy = 0;
    });
    if (reduced || _leaving) return;
    final int commit = aylaResolveSwipeCommit(
      net: net,
      cross: cross,
      velocity: details.velocity.pixelsPerSecond.dx,
      size: width,
    );
    if (commit == 0) return;
    final int base = aylaGroupSceneOrderIndex(contentScene);
    final int next = (base + commit + kAylaGroupSceneOrder.length) %
        kAylaGroupSceneOrder.length;
    _goScene(kAylaGroupSceneOrder[next]);
  }
}

/// 窄屏场景切换的**淡出层** —— web `GroupPage.tsx:499–539` 的 `GroupSceneSurface`
/// + `AnimatePresence mode="sync"` 的等价物。
///
/// web 的 variants：`enter/center` 都是 `{x:0, opacity:1}`、`exit` 是 `{x:0, opacity:0}`
/// ⇒ **新场景无淡入、旧场景 300ms 淡出**（横向位移由 drag 层单独拥有，切场景时归零）。
/// 本件用「保留旧场景一帧 + 淡出」表达：`Stack` 里按 `ValueKey(scene)` 匹配 Element，
/// 旧场景的 State（会话历史/滚动位置）在淡出期间**继续存活**，动画结束才卸载
/// —— 与 `AnimatePresence` 保管退出实例同一语义。
class _AylaSceneFade extends StatefulWidget {
  const _AylaSceneFade({required this.scene, required this.builder});

  final AylaGroupScene scene;
  final Widget Function(AylaGroupScene scene) builder;

  @override
  State<_AylaSceneFade> createState() => _AylaSceneFadeState();
}

class _AylaSceneFadeState extends State<_AylaSceneFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AylaDurations.auroraqua,
    value: 1,
  );

  /// 正在退场的旧场景（null = 无）。
  AylaGroupScene? _outgoing;

  @override
  void didUpdateWidget(covariant _AylaSceneFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene == widget.scene) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _outgoing = null);
      return;
    }
    setState(() => _outgoing = oldWidget.scene);
    _fade.value = 1;
    _fade.reverse().whenComplete(() {
      if (mounted) setState(() => _outgoing = null);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaGroupScene? outgoing = _outgoing;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        KeyedSubtree(
          key: ValueKey<AylaGroupScene>(widget.scene),
          child: widget.builder(widget.scene),
        ),
        if (outgoing != null)
          FadeTransition(
            opacity: _fade,
            child: ExcludeFocus(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: KeyedSubtree(
                    key: ValueKey<AylaGroupScene>(outgoing),
                    child: widget.builder(outgoing),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
