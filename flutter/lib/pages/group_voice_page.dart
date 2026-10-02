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
/// 2. **`fromShare` 分支未接**：web 从分享消息点进时带 `location.state.fromShare`
///    以**免白名单校验**（tsx 36–38 / 94–96）。Flutter 侧路由不带 state ⇒ 一律走
///    严格白名单路径（即 web 的默认分支）；从分享进入他群语音房时页面保持加载态
///    （**不伪造可见**）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/voice_api.dart';
import '../state/paged_list.dart';
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
    this.onExit,
  });

  final String groupId;

  /// 路由 `:voiceChannelId`（存在 ⇒ 房内分支）。
  final String? routeChannelId;

  /// 「返回聊天」（空态键；web tsx 225–227）。
  final VoidCallback? onExit;

  @override
  ConsumerState<GroupVoicePage> createState() => _GroupVoicePageState();
}

class _GroupVoicePageState extends ConsumerState<GroupVoicePage> {
  AylaPagedList<AylaDirectoryVoiceEntry>? _pager;
  final ScrollController _scroll = ScrollController();
  ShellUiNotifier? _shell;
  Future<void> Function()? _refreshCallback;
  int _replayNonce = 0;

  @override
  void initState() {
    super.initState();
    _pager = AylaPagedList<AylaDirectoryVoiceEntry>(
      request: (String? cursor) => AylaVoiceApi.listVoiceChannelsPage(
        cursor: cursor,
        groupId: widget.groupId,
      ),
      keyOf: (AylaDirectoryVoiceEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    // 房内态不取大厅数据（web tsx 40 的 enabled 参数）。
    if (widget.routeChannelId == null) unawaited(_pager!.load());
    _registerRefresh();
    _ensureRouteChannel();
  }

  @override
  void didUpdateWidget(covariant GroupVoicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeChannelId != widget.routeChannelId) {
      if (widget.routeChannelId == null && !(_pager?.loaded ?? false)) {
        unawaited(_pager?.load());
      }
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

  /// 直达频道详情补拉（web tsx 88–100）：本地未命中时拉一次，**白名单不含本群则不注入**。
  void _ensureRouteChannel() {
    final String? id = widget.routeChannelId;
    if (id == null) return;
    if (ref.read(voiceStateProvider).channelOf(id) != null) return;
    unawaited(() async {
      try {
        final AylaVoiceChannelSnapshot channel =
            await AylaVoiceApi.getVoiceChannel(id);
        if (!mounted) return;
        if (!channel.allowedGroupIds.contains(widget.groupId)) return;
        ref.read(voiceStateProvider).upsertChannel(channel);
      } catch (_) {
        // 拉不到：界面保持加载态（**不伪造房间**）。
      }
    }());
  }

  /// 房内频道（web tsx 121–129）：必须是本群可见的频道。
  AylaVoiceChannelSnapshot? _roomChannel() {
    final String? id = widget.routeChannelId;
    if (id == null) return null;
    final AylaVoiceChannelSnapshot? channel =
        ref.watch(voiceStateProvider).channelOf(id);
    if (channel == null) return null;
    if (!channel.allowedGroupIds.contains(widget.groupId)) return null;
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
    final AylaPagedList<AylaDirectoryVoiceEntry>? pager = _pager;
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
                onJoin: (String channelId) => context.go(
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
