/// 群内语音子界面 —— web `pages/group/GroupVoice.tsx`（243 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内语音房目录（服务端 `group_id` 过滤 + 游标分页） | 40（`useDirectoryPage('voice', {groupId})`） |
/// | 刷新后已入场卡片整批重播浮入 | 46–48 + 69–73 |
/// | RefreshFAB 注册（引用守卫） | 75–83 |
/// | 上拉刷新只在容器已到顶时响应 | 86 |
/// | 直达频道详情补拉 + **白名单校验**（不在本群可见范围则不注入） | 88–100 |
/// | 路由频道命中本地列表且白名单含本群 ⇒ 渲染房内 | 121–138 |
/// | 顶部返回 / 离开频道 / 删除房间都回 `/group/:id/voice` | 139–151 |
/// | 列表三态（加载 3 根 64 骨架 / 空态 / 卡片列表） | 205–242 |
///
/// ## 机制差异（登记）
/// 1. **房内编排整块复用** [AylaVoiceRoomHost]（一级语音同款，`backPath` 参数化）——
///    web 的 `VoiceRoomBody` 自带「加入/静音/音量/成员/房内聊天/删除确认」全部逻辑，
///    Flutter 侧这些在宿主里（`pages/voice_support.dart` 文件头有逐条对账），
///    群内只需换退出落点 ⇒ 不再复制一份。
/// 2. **`fromShare` 已接（2026-10-21）**：web 从分享消息点进时带
///    `location.state.fromShare` 以**免白名单校验**（`GroupVoice.tsx:25` + 判据
///    `:90` / `:96` / `:127`）。Flutter 路由无 state ⇒ 分享卡把 `?fromShare=1` 写进 URL，
///    由 `app_router.dart` 读出 → `GroupPage.fromShare` → 本页 [fromShare]。
///    判据与 web 逐条同义：`fromShare || allowedGroupIds.contains(groupId)`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/voice_api.dart';
import '../state/directory_store.dart'
    show aylaDirectoryStore, AylaDirectoryController, AylaDirectoryOptions;
import '../state/directory_events.dart' show AylaDirectoryKind;
import '../state/room_providers.dart' show voiceStateProvider;
import '../state/shell_state.dart' show ShellUiNotifier, shellUiProvider;
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart' show AylaRadii, AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/reveal.dart' show AylaRevealScope;
import '../widgets/group/group_scene.dart'
    show
        AylaGroupSceneHead,
        AylaGroupScenePlaceholder,
        AylaGroupScenePlaceholderRole,
        AylaGroupSceneStickyHead;
import '../widgets/voice/voice_channels.dart'
    show AylaVoiceCardData, AylaVoiceChannelList;
import 'voice_support.dart' show AylaVoiceRoomHost;

class GroupVoicePage extends ConsumerStatefulWidget {
  const GroupVoicePage({
    super.key,
    required this.groupId,
    this.routeChannelId,
    this.fromShare = false,
    this.onExit,
  });

  final String groupId;

  /// 路由 `:voiceChannelId`（存在 ⇒ 房内分支）。
  final String? routeChannelId;

  /// 「从分享消息点进来」（web `location.state.fromShare`，`GroupVoice.tsx:25`）
  /// ⇒ 免白名单校验（判据见 tsx `:90` / `:96` / `:127`）。
  final bool fromShare;

  /// 「返回聊天」（空态键；web tsx 225–227）。
  final VoidCallback? onExit;

  @override
  ConsumerState<GroupVoicePage> createState() => _GroupVoicePageState();
}

class _GroupVoicePageState extends ConsumerState<GroupVoicePage> {
  /// 群内语音目录 —— **读共享目录缓存**（web `GroupVoice.tsx:40` 的
  /// `useDirectoryPage("voice", {groupId})`），不是页面私有分页。
  ///
  /// ⚠️ **2026-10-20 热更新审计 R2 修复**：原实现用私有 `AylaPagedList`，
  /// 只在 `initState` 取一次 + 自己的分页回调，**完全不读 `AylaDirectoryStore`**
  /// ⇒ 目录帧（`voice.channel.created/updated/deleted/member_count_changed`）
  /// 落库后本页毫无反应，表现为「群内语音列表必须手动刷新/重进页面」。
  /// 换成共享缓存后，帧 → 域 store → `updateCachedItems` → 本 controller 通知 → 重建，
  /// 与群外大厅页 / 宽屏侧栏走**同一条通路**（web 三处也是同一个 store 投影）。
  AylaDirectoryController<AylaDirectoryVoiceEntry>? _pager;
  final ScrollController _scroll = ScrollController();
  ShellUiNotifier? _shell;
  Future<void> Function()? _refreshCallback;
  int _replayNonce = 0;

  /// **粘性 fromShare**（web `location.state.fromShare` 在这一次进群会话内的生命周期）。
  ///
  /// ## 为什么 State 要自己记（2026-10-21 边界修复）
  /// web 的 `fromShare` 读的是 `useLocation().state`：React Router 的 state 挂在**这一条
  /// history entry** 上，`GroupVoice` 组件自身不重挂就不会丢。Flutter 侧把它搬到了
  /// URL query（`?fromShare=1`），而**本页的 State 会在 URL 变化时被复用** ——
  /// `GroupPage` 的五个场景槽位由 [AylaSceneFade] 保管（切场景不重挂 `initState`），
  /// 且 `_goScene` / `_popScene` 用 `context.go('/group/<id>/<scene>')` **不带 query**
  /// ⇒ 切走再切回时 `widget.fromShare` 会翻回 false ⇒ `_roomChannel()` 变 null ⇒
  /// 从分享进入的房间被踢回骨架。
  ///
  /// 语义上与 web 对齐：**一次进群会话内 fromShare 一旦为真就保持为真**，
  /// 直到换群（[didUpdateWidget] 里 groupId 变化）才重置。
  bool _stickyFromShare = false;

  /// 生效的 fromShare（构造参数 or 本会话内粘住的）。
  bool get _fromShare => _stickyFromShare || widget.fromShare;

  @override
  void initState() {
    super.initState();
    _stickyFromShare = widget.fromShare;
    _bindDirectoryController();
    _registerRefresh();
    _ensureRouteChannel();
  }

  @override
  void didUpdateWidget(covariant GroupVoicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换群 ⇒ 这是**另一次**进群会话，粘性标记重置（web 换群也是新的 history entry）。
    if (oldWidget.groupId != widget.groupId) {
      _stickyFromShare = widget.fromShare;
    } else if (widget.fromShare) {
      // 同群内 URL 丢了 query（切场景/返回键回退）⇒ 沿用本会话已粘住的 true。
      _stickyFromShare = true;
    }
    if (oldWidget.routeChannelId != widget.routeChannelId) {
      if (widget.routeChannelId == null) unawaited(_pager?.load());
      _ensureRouteChannel();
    }
    // 换群不换频道时也要重新校验（粘性标记已按新群重置）。
    if (oldWidget.groupId != widget.groupId &&
        oldWidget.routeChannelId == widget.routeChannelId) {
      _ensureRouteChannel();
    }
  }

  @override
  void dispose() {
    final ShellUiNotifier? notifier = _shell;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _pager?.removeListener(_onChanged);
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 绑定群语音目录 controller（web `GroupVoice.tsx:40`，options 只有 `{groupId}`）。
  ///
  /// ⚠️ **必须帧后 `load()`**（库里既有五处同源纪律，见 `group_page.dart:316–352`）：
  /// `AylaDirectoryStore.load` 的同步段会立刻 `notifyListeners` 全局 store，
  /// 而其它已挂载页面（HomePage / GroupPage）的监听是裸 `setState` ⇒ 在 build 期发起会抛
  /// "setState() or markNeedsBuild() called during build"。
  void _bindDirectoryController() {
    final AylaDirectoryController<AylaDirectoryVoiceEntry> pager =
        AylaDirectoryController<AylaDirectoryVoiceEntry>(
      store: aylaDirectoryStore,
      kind: AylaDirectoryKind.voice,
      // 房内态不取大厅数据（web tsx 40 的 enabled 参数）。
      enabled: widget.routeChannelId == null,
      options: AylaDirectoryOptions(groupId: widget.groupId),
    )..addListener(_onChanged);
    _pager?.removeListener(_onChanged);
    _pager?.dispose();
    _pager = pager;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(pager.load());
    });
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      await _pager?.refresh();
      if (mounted) setState(() => _replayNonce += 1);
    }

    _shell = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  Future<void> _refresh() async {
    await _pager?.refresh();
    if (mounted) setState(() => _replayNonce += 1);
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// 直达频道详情补拉（web `GroupVoice.tsx:88–100`）：本地未命中时拉一次，
  /// **白名单不含本群则不注入**（界面保持加载态、静默）。
  ///
  /// ⚠️ 跳过条件必须与 web **逐字同义**：web 写道
  /// ```tsx
  /// if (!routeChannelId || channels.some((item) => item.id === routeChannelId
  ///   && (fromShare || (item.allowed_group_ids ?? []).some((id) => String(id) === String(groupId))))) return;
  /// ```
  /// ⇒ 是「**本地已有且本群可见**」才跳过，**不是**「本地存在就跳过」。
  /// 只判存在会让「存在但白名单不含本群」的频道**永远停在骨架**（补拉被跳过、
  /// 房内命中判据又为假）—— 这正是用户实报「进不去语音房」的第二条路径。
  /// 判据与 web 逐条同义：`fromShare || allowedGroupIds.contains(groupId)`
  /// （`GroupVoice.tsx:90`；从分享进入免校验，见文件头「机制差异 2」）。
  void _ensureRouteChannel() {
    final String? id = widget.routeChannelId;
    if (id == null) return;
    final AylaVoiceChannelSnapshot? local =
        ref.read(voiceStateProvider).channelOf(id);
    if (local != null && _visibleInGroup(local)) return;
    unawaited(() async {
      try {
        final AylaVoiceChannelSnapshot channel =
            await AylaVoiceApi.getVoiceChannel(id);
        if (!mounted) return;
        // tsx 96：`if (!fromShare && !allowed.contains(groupId)) return;`
        if (!_visibleInGroup(channel)) return;
        ref.read(voiceStateProvider).upsertChannel(channel);
      } catch (_) {
        // 拉不到：界面保持加载态（**不伪造房间**）。
      }
    }());
  }

  /// 本群可见判据（web `GroupVoice.tsx:90/96/127` 的同一表达式）：
  /// `fromShare || (channel.allowed_group_ids ?? []).some(id => String(id) === groupId)`。
  ///
  /// 分享进入（`fromShare`）免白名单 —— 任何人点进分享目标都能看到
  /// （`shareRoutes.ts:15` 的注释「对 fromShare 免白名单校验」）。
  bool _visibleInGroup(AylaVoiceChannelSnapshot channel) =>
      _fromShare || channel.allowedGroupIds.contains(widget.groupId);

  /// 房内频道（web `GroupVoice.tsx:121–129`）：必须是本群可见的频道。
  ///
  /// 这是「进不去房」的唯一命中判据：`allowed_group_ids` 含本群（或 fromShare）
  /// 才渲染房内界面，否则一路落到骨架（`routeChannelId != null` 分支）。
  AylaVoiceChannelSnapshot? _roomChannel() {
    final String? id = widget.routeChannelId;
    if (id == null) return null;
    final AylaVoiceChannelSnapshot? channel =
        ref.watch(voiceStateProvider).channelOf(id);
    if (channel == null) return null;
    if (!_visibleInGroup(channel)) return null;
    return channel;
  }

  @override
  Widget build(BuildContext context) {
    final AylaVoiceChannelSnapshot? room = _roomChannel();
    if (room != null) {
      return AylaVoiceRoomHost(
        key: ValueKey<String>(room.id),
        channelId: room.id,
        backPath: '/group/${Uri.encodeComponent(widget.groupId)}/voice',
      );
    }
    // 路由给了频道但还没就绪（web tsx 201–203）：骨架 + 「正在加载语音房…」。
    if (widget.routeChannelId != null) {
      return AylaGroupScenePlaceholder(
        role: AylaGroupScenePlaceholderRole.status,
        children: <Widget>[
          const SizedBox(
            width: 240,
            child: AylaSkeleton(height: 96, radius: AylaRadii.rInput),
          ),
          const SizedBox(height: AylaSpacing.sp2),
          Text('正在加载语音房…', style: AylaTextStyles.of(context).body),
        ],
      );
    }
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    final AylaTextStyles t = AylaTextStyles.of(context);

    Widget content;
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 213–219：三根 64 高骨架（圆角 12）+ 文案。
      content = Column(
        children: <Widget>[
          for (int i = 0; i < 3; i += 1)
            const Padding(
              padding: EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: AylaSkeleton(height: 64, radius: AylaRadii.rInput),
            ),
          Text(
            '正在加载语音房…',
            style: t.timestamp.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    } else if (pager.items.isEmpty) {
      // tsx 220–229：空态 + ghost「返回聊天」。
      content = AylaGroupScenePlaceholder(
        title: '群内还没有语音房',
        description: '建一个群内语音房，一起连麦',
        expandHeight: false,
        actions: <Widget>[
          AylaGlassButton(
            label: '返回聊天',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: widget.onExit,
          ),
        ],
      );
    } else {
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AylaRevealScope(
              replayKey: _replayNonce,
              // 卡片留白口径（问题 6 真根因）：web 群内用的是
              // `.group-voice .voice-channel-list`（voice.css:690–695）——
              // **`padding: 0` 显式归零**（:694）且**恒 2 列**（:692 的 `repeat(2, 1fr)`；
              // voice.css:647–659 的两条媒体查询只作用于 `.voice-hub`）。
              // 左右留白只由外层 `.group-page .group-voice`（group.css:411–417 的 `sp4`）给。
              // ⇒ 不传时吃基样式 `sp3 sp4`，群内左右各多 16（实测 32，用户实报）。
              child: AylaVoiceChannelList(
                padding: EdgeInsets.zero,
                columns: 2,
                channels: <AylaVoiceCardData>[
                  for (final AylaDirectoryVoiceEntry entry in pager.items)
                    entry.card,
                ],
                revealItems: true,
                // 进群内语音房：**push**（返回回本页）。
                onJoin: (String channelId) => context.push(
                  '/group/${Uri.encodeComponent(widget.groupId)}/voice/'
                  '${Uri.encodeComponent(channelId)}',
                ),
              ),
            ),
            AylaDirectoryLoadMore(
              loading: pager.loading,
              error: pager.error,
              hasMore: pager.hasMore,
              invalidated: pager.invalidated,
              loadMore: pager.loadMore,
              refresh: pager.refresh,
            ),
          ],
        ),
      );
    }

    return AylaGroupSceneStickyHead(
      controller: _scroll,
      // .group-voice：padding sp4 + 底部 68（避让右下角 FAB，group.css 414/422）。
      padding: const EdgeInsets.fromLTRB(
        AylaSpacing.sp4,
        AylaSpacing.sp4,
        AylaSpacing.sp4,
        68,
      ),
      gap: AylaSpacing.sp4,
      head: const AylaGroupSceneHead(
        title: '群内语音房',
        description: '选择一个房间加入，或点击右下角创建新的群内语音房',
      ),
      child: content,
    );
  }
}
