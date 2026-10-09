/// 直播间核心装配（`LiveRoomBody.tsx` 566 行）。
///
/// ## 事实源
/// ```
/// tsx 405–435          进房错误态：仍保留**侧栏与弹幕区**（宽屏 + 非 hideRail），
///                      主区换 `.live-room-error`（`<p>error</p>` + `.btn.btn-glow`「返回」）
/// tsx 441–481          **窄屏沉浸式**（isNarrow && !showOwnerPanel）：
/// tsx 139–151          切台**面板重播**的 target 表（`mediaPanels`）+ hooks/usePanelReplayMotion.ts
///                      全文（identity 变化 ⇒ WAAPI `opacity 0→1` + `translate ±20→0`，
///                      300ms `cubic-bezier(0,0,.58,1)`；`!enabled || reduced` 直接 return）
/// tsx 542–565          `LiveRoomHeader` 的**头部进退场**（`AnimatePresence mode="wait"` +
///                      `panelVariants(reduced,"top")` + inert / aria-hidden / pointer-events）
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/live/live_room_body.dart` 一节）
/// ```
///
/// ## 机制差异
/// - **数据全部由页面注入**（[AylaLiveRoomData] + 回调）：web 的 `useLiveRoom` / `useDanmaku` /
///   live store 属数据层与运行时（HLS、WS、轮询），不进 `lib/widgets`；
/// - video 由页面持有（`HlsPlaybackController`），本件只把它交给 [AylaLivePlayer]；
/// - 侧栏 = 复用 [AylaLiveChannelRail]；弹幕三件 = 复用 [AylaDanmakuList] / [AylaDanmakuInput] /
///   [AylaDanmakuOverlay]；观众条 = 复用 [AylaLiveViewerStrip]；控制台 = 复用
///   [AylaLiveOwnerPanel] + [AylaLiveStreamAddresses]；头部来源标签 = 复用 **AylaSourceTag** 的滚动容器。
/// - **切台动效（2026-09-28 补）**：web 上 `has-media-panel-motion` / `is-panel-motion` 只做
///   **取消 CSS 挂载入场**（auroraqua.css 202–211 · 316–321 · 437–445 全是
///   `animation: none` / `opacity: 1` / `transform: none`；live.css 零命中）——位移与透明度
///   全部由 JS owner 持有（面板 = WAAPI `usePanelReplayMotion`，头部 = framer `panelVariants`）。
///   Flutter 无 CSS 可取消，故等价物 = **直接挂两个 owner**：三块面板走
///   `AylaRevealScope(replayKey: channelId)` + `AylaRevealItem`（重播入场、不重挂），头部走
///   `_LiveRoomHeaderSwap`（退出 → 进入串行，见该类头注与 `AylaPanelTransition` 的关系登记）。
///
/// ## 公开面
/// `AylaLiveRoomData` · `AylaLiveRoomBody` · 样张 `aylaLiveRoomBodySamples()`

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/favorite_status.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'danmaku.dart'
    show
        AylaDanmakuEntry,
        AylaDanmakuInput,
        AylaDanmakuInputMaterial,
        AylaDanmakuList,
        AylaDanmakuOverlay;
import '../base/directory_controls.dart'
    show AylaFavoriteButton, AylaHistoryControlsData, AylaFavoriteState;
import 'live_channel_snapshot.dart';
import 'live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import 'live_owner_panel.dart' show AylaLiveOwnerPanel, AylaLiveOwnerSaveRequest;
import 'live_player.dart' show AylaLivePlayer, AylaLiveSrsStatus;
import 'live_rail.dart' show AylaLiveChannelRail;
import 'live_studio.dart' show AylaLiveHostAvatar, AylaLiveStreamAddresses;
import 'live_viewers.dart'
    show AylaLiveViewerItem, AylaLiveViewerSheetData, AylaLiveViewerStrip;
import '../base/primitives.dart' show AylaSourceTag;
import '../base/reveal.dart'
    show AylaRevealItem, AylaRevealMotion, AylaRevealScope;
import '../base/share.dart' show AylaShareButton;
import '../base/tooltip.dart';
import '../motion/gestures.dart' show kAylaPanelDistance, kAylaPanelDuration;

/// 直播间数据投影（web `useLiveRoom` + `useDanmaku` + live store 的等价物 —— 全部由页面给出）。
class AylaLiveRoomData {
  const AylaLiveRoomData({
    this.channel,
    this.srsStatus,
    this.loading = false,
    this.error,
    this.playerError,
    this.viewerCount,
    this.viewers = const <AylaLiveViewerItem>[],
    this.danmaku = const <AylaDanmakuEntry>[],
    this.sending = false,
    this.sendError,
    this.hasNewBelow = false,
    this.history,
    this.viewerSheet = const AylaLiveViewerSheetData(),
    this.onOpenViewerSheet,
  });

  /// 当前频道描述符（null = 尚未到达）。
  final AylaLiveChannelSnapshot? channel;

  /// SRS 状态（null = 查询中）。
  final AylaLiveSrsStatus? srsStatus;

  /// 进房加载中（头部标题显示「加载中…」；飘弹幕层延后挂载）。
  final bool loading;

  /// 进房错误（非空 ⇒ 错误态布局）。
  final String? error;

  /// 播放致命错误。
  final String? playerError;

  /// 在看人数（null = 未知；0 是真实读数）。
  final int? viewerCount;

  /// 预览名单（WS 最近活跃）。
  final List<AylaLiveViewerItem> viewers;

  /// 弹幕（列表 + 飘层共用）。
  final List<AylaDanmakuEntry> danmaku;

  /// 发送中（输入框禁用发送键）。
  final bool sending;

  /// 发送错误文案。
  final String? sendError;

  /// 列表下方有新弹幕（显示「新弹幕」提示）。
  final bool hasNewBelow;

  /// 历史分页状态（复用 `AylaHistoryControlsData`）。
  final AylaHistoryControlsData? history;

  /// 观众名单弹层的数据投影。
  final AylaLiveViewerSheetData viewerSheet;

  /// 名单弹层**即将打开**（页面借此发起权威名单拉取）。
  ///
  /// 事实源：web 由弹层自己在打开时拉（`LiveViewerSheet.tsx:44–79` 的
  /// `getLiveChannelViewers` + `getElysiaProfile`）；Flutter 的网络层不进 `lib/widgets`
  /// ⇒ 同一次拉取由页面承接（`live_support.dart` 的 `AylaLiveViewerSheetController`）。
  /// 默认 null ⇒ 行为不变。
  final VoidCallback? onOpenViewerSheet;
}

/// 直播间核心装配（`LiveRoomBody.tsx`）。
class AylaLiveRoomBody extends StatefulWidget {
  const AylaLiveRoomBody({
    super.key,
    required this.channelId,
    required this.data,
    required this.channels,
    required this.isNarrow,
    this.onSelect,
    this.onBack,
    this.showOwnerPanel = false,
    this.hideRail = false,
    this.onDeleteChannel,
    this.onCreateNewChannel,
    this.deletingChannelId,
    this.onRetryPlayer,
    this.onRefreshPlayer,
    this.onSendDanmaku,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.favoriteState = AylaFavoriteState.unknown,
    this.favoriteTargetType,
    this.favoriteTargetId,
    this.favoriteController,
    this.onShare,
    this.videoView,
    this.directoryFooter,
    this.onOpenProfile,
    this.onSaveOwner,
    this.onStartLive,
    this.onStopLive,
    this.railDirectoryFooter,
    this.groups = const <({String id, String title})>[],
    this.onOpenViewerSheet,
  });

  /// 当前频道 id。
  final String channelId;

  /// 数据投影（页面注入）。
  final AylaLiveRoomData data;

  /// 有序频道列表（切换范围；一级 = 全部可见，群内 = 仅该群）。
  final List<AylaLiveCardData> channels;

  /// 是否窄屏（web `isNarrow`；全屏期间由本件冻结）。
  final bool isNarrow;

  /// 点击封面/滑切切换直播间。
  final ValueChanged<String>? onSelect;

  /// 返回。
  final VoidCallback? onBack;

  /// 仅开播控制台显示主播面板。
  final bool showOwnerPanel;

  /// 隐藏宽屏频道封面侧栏（群内直播：侧栏已移到左侧 ChannelSidebar）。
  final bool hideRail;

  /// 侧栏每项删除直播间（仅控制台提供）。
  final ValueChanged<String>? onDeleteChannel;

  /// 侧栏底部加号：新建直播间。
  final VoidCallback? onCreateNewChannel;

  /// 正在删除的频道 id。
  final String? deletingChannelId;

  /// 播放重试 / 跳最新。
  final VoidCallback? onRetryPlayer;
  final VoidCallback? onRefreshPlayer;

  /// 发送弹幕（全屏输入框也走它）；第二参 = 图片 mediaId（null = 纯文本）。
  final Future<bool> Function(String content, String? mediaId)? onSendDanmaku;

  /// 头部收藏 / 转发。
  final ValueChanged<bool>? onToggleFavorite;

  /// 收藏状态加载失败 → 重新拉取（web `FavoriteButton.tsx:35–38`）。
  final VoidCallback? onRetryFavoriteStatus;

  /// 收藏状态（**三态 + 错误态**）。
  ///
  /// ⚠️ 2026-10-08 修正：原为 `bool?`，而 web `FavoriteButton`
  /// 的 `state.favoriteId` 是 `undefined | null | number` **三档**
  /// （`stores/favoriteStatus.ts:1–2`：未知 ≠ 未收藏）。bool 档把
  /// 「加载中/失败」强行折成「未收藏」⇒ `FavoriteButton.tsx:69` 的
  /// `disabled={busy || state.loading || (unknown && !state.error)}`
  /// 在该处**永不生效**：头部会显示一个「看起来能点」的未收藏键（用户实报「样式/行为
  /// 与别处不一致」）。改回枚举后，unknown 档自动禁用 + 显示「正在加载收藏状态」。
  /// 默认 `unknown`（不传 = 保持既有「未收藏」渲染的安全超集：见 build 内说明）。
  final AylaFavoriteState favoriteState;

  // ---- 自给自足档（对齐 web：`LiveRoomBody.tsx:260/328` 只给 targetType/targetId）----

  /// 收藏目标类型（web `targetType`；给定时头部收藏键**自己加载自己**）。
  ///
  /// 与 [favoriteTargetId] 同时给出 ⇒ 忽略 [favoriteState]/[onToggleFavorite]/
  /// [onRetryFavoriteStatus]，由 `AylaFavoriteButton` 自持状态（web 架构）。
  final String? favoriteTargetType;

  /// 收藏目标 id（web `targetId`）。
  final String? favoriteTargetId;

  /// 共享收藏控制器（不传 ⇒ 收藏键自建私有实例）。
  final AylaFavoriteStatusController? favoriteController;

  final VoidCallback? onShare;

  /// 视频视图（页面注入同一 `HlsPlaybackController.videoView`）。
  final Widget? videoView;

  /// 侧栏目录分页槽。
  final Widget? directoryFooter;
  final Widget? railDirectoryFooter;

  /// 观众行跳个人主页。
  final ValueChanged<AylaLiveViewerItem>? onOpenProfile;

  /// 控制台：保存资料 / 开播 / 下播。
  final Future<AylaLiveChannelSnapshot?> Function(
    AylaLiveOwnerSaveRequest request,
  )? onSaveOwner;
  final Future<void> Function()? onStartLive;
  final Future<void> Function()? onStopLive;

  /// 可见范围用的群列表（透传控制台）。
  final List<({String id, String title})> groups;

  /// 名单弹层**即将打开**（等价 web 弹层自身在打开时的拉取，
  /// `LiveViewerSheet.tsx:44–79`；默认 null ⇒ 不变）。
  final VoidCallback? onOpenViewerSheet;

  @override
  State<AylaLiveRoomBody> createState() => _AylaLiveRoomBodyState();
}

class _AylaLiveRoomBodyState extends State<AylaLiveRoomBody> {
  bool _railCollapsed = false; // 宽屏侧栏默认展开（tsx 133）
  bool _railOpen = false; // 窄屏覆盖层默认关闭（tsx 134）
  bool _fullscreen = false; // 由 AylaLivePlayer.onFullscreenChanged 驱动（web 监听 fullscreenchange）

  /// 全屏期间冻结的 isNarrow（tsx 96–111：防锁横屏导致窄↔宽切换、播放器重建黑屏）。
  bool _frozenNarrow = false;

  // ---- 窄屏上下滑切台（tsx 136–203）----
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _frozenNarrow = widget.isNarrow;
  }

  bool get _isNarrow => _fullscreen ? _frozenNarrow : widget.isNarrow;

  int get _currentIndex =>
      widget.channels.indexWhere((AylaLiveCardData c) => c.id == widget.channelId);

  AylaLiveCardData? get _prevChannel =>
      _currentIndex > 0 ? widget.channels[_currentIndex - 1] : null;
  AylaLiveCardData? get _nextChannel =>
      (_currentIndex >= 0 && _currentIndex < widget.channels.length - 1)
      ? widget.channels[_currentIndex + 1]
      : null;

  /// 松手判定（tsx 177–193 `resolveSwipeCommit` 的等价）：
  /// 净位移 > 1/3 高优先；否则同向甩动补充（阈值 500px/s）。
  void _handleSwipeEnd(double velocity) {
    final double height = _stageHeight(context);
    final double net = _dragOffset;
    final double threshold = height / 3;
    int commit = 0;
    if (net.abs() > threshold) {
      commit = net < 0 ? 1 : -1; // 上滑 = 下一场
    } else if (velocity.abs() > 500) {
      commit = velocity < 0 ? 1 : -1;
    }
    setState(() => _dragOffset = 0);
    if (commit == 1 && _nextChannel != null) {
      widget.onSelect?.call(_nextChannel!.id);
    } else if (commit == -1 && _prevChannel != null) {
      widget.onSelect?.call(_prevChannel!.id);
    }
  }

  double _stageHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).height * 0.6;

  /// 视频视图（页面注入；控制台/窄屏/宽屏共用同一实例）。
  Widget get _player => AylaLivePlayer(
    // 窄屏沉浸式：圆角/边框交给 stage（web `.live-room-swipe-item .live-player`）
    flat: _isNarrow && !widget.showOwnerPanel,
    srsStatus: widget.data.srsStatus,
    optimisticStatus: _statusOf(widget.data.channel),
    playerError: widget.data.playerError,
    videoView: widget.videoView,
    onRetry: widget.onRetryPlayer,
    onRefresh: widget.onRefreshPlayer,
    onSendDanmaku: widget.onSendDanmaku == null
        ? null
        : (String content) => widget.onSendDanmaku!(content, null),
    danmakuOwner: widget.channelId,
    // 全屏期间冻结 isNarrow（tsx 96–111）：防锁横屏导致窄↔宽切换、播放器重建黑屏
    onFullscreenChanged: (bool fullscreen) => setState(() {
      if (fullscreen) _frozenNarrow = widget.isNarrow;
      _fullscreen = fullscreen;
    }),
    danmakuError: widget.data.sendError,
    // 飘弹幕层：**仅 `!loading && srsStatus === "live"`** 才挂（tsx 222）
    children: (!widget.data.loading &&
            widget.data.srsStatus == AylaLiveSrsStatus.live)
        ? AylaDanmakuOverlay(items: widget.data.danmaku)
        : null,
  );

  AylaLiveStatus? _statusOf(AylaLiveChannelSnapshot? c) => c?.status;

  Widget get _viewerStrip => AylaLiveViewerStrip(
    count: widget.data.viewerCount,
    viewers: widget.data.viewers,
    sheet: widget.data.viewerSheet,
    onOpen: widget.onOpenViewerSheet,
  );

  Widget get _danmakuList => AylaDanmakuList(
    items: widget.data.danmaku,
    hasNewBelow: widget.data.hasNewBelow,
    history: widget.data.history,
  );

  Widget get _danmakuInput => AylaDanmakuInput(
    // `.live-room-input` 在宽屏是卡内元素、窄屏自带玻璃底（B2-1 已按 web 定档）
    material: _isNarrow
        ? AylaDanmakuInputMaterial.narrowCard
        : AylaDanmakuInputMaterial.sideCard,
    sending: widget.data.sending,
    error: widget.data.sendError,
    onSend: widget.onSendDanmaku ?? (String _, String? _) async => false,
  );

  /// 头部**容器材质**（实测「顶栏漏了背景」）。
  ///
  /// - 宽屏（≥769）：**卡片** —— auroraqua 402–408：`margin 12` / 1px 亮边 / `radius 16` /
  ///   `--glass-shadow-compact` / `--glass-filter(blur24 sat1.4)`；app.css 3495–3507 给
  ///   `padding sp2 sp3` + `gap sp3`；
  /// - 窄屏（≤768）：**通栏方角条**（auroraqua 412–454 **不**做卡片化）—— app.css 的
  ///   `--glass-bg` + `blur(18px) saturate(1.4)` + 下边框；live.css 659 把 `margin: 0`、
  ///   `gap sp2`（贴顶铺满，无圆角）。
  Widget _headMaterial({required bool narrow, required Widget child}) {
    if (narrow) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: AylaSpacing.sp2,
        ),
        decoration: const BoxDecoration(
          color: AylaColors.glassBg,
          border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
        ),
        child: child,
      );
    }
    // ⚠️ margin：auroraqua 402 给 `margin: 12`（0-1-0），但 live.css 689–691 的
    //    `.live-room-body.is-wide .live-room-head { margin: 0 }`（**0-2-0**）胜出
    //    ⇒ 宽屏头部的实渲染 margin 是 **0**（与主区内沿对齐、与 stage 同宽）；
    //    材质（底/边/radius/阴影/blur）仍来自 auroraqua。
    return AylaGlassSurface(
      radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
      blur: AylaGlass.blurCard, // --glass-filter = blur(24px) saturate(1.4)
      shadow: AylaShadows.compact, // --glass-shadow-compact（auroraqua 405）
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      child: ConstrainedBox(
        // **顶栏高度恒定**：web 顶栏里恒有 40×40 的键（`.icon-btn-40` 的返回/展开/分享）
        // ⇒ 卡片高恒为 `padding sp2×2 + 40 = 56`；Flutter 侧若不兜这一句，
        // 收起侧栏后多出 40 高的返回/展开键会让顶栏从 53 长到 56（指出
        // 「顶栏高度不变、仅宽度扩展」）。
        constraints: const BoxConstraints(minHeight: 40),
        child: child,
      ),
    );
  }

  /// 头部：窄屏 / 宽屏两档（tsx 234–342）。
  Widget _head({required bool narrow}) {
    final AylaLiveChannelSnapshot? channel = widget.data.channel;
    final String title = widget.data.loading
        ? '加载中…'
        : (channel?.title ?? '直播间');
    final List<String> tags = channel == null
        ? const <String>[]
        : aylaVisibilityLabelsOf(channel);
    return Row(
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        if (narrow || widget.hideRail || _railCollapsed)
          AylaIconButton(
            icon: AylaIcon(aylaIconByName('iconBack')!, size: 20),
            size: 40,
            semanticLabel: '返回',
            onPressed: widget.onBack,
          ),
        if (!narrow && !widget.hideRail && _railCollapsed)
          AylaIconButton(
            icon: AylaIcon(aylaIconByName('iconChevronRight')!, size: 20),
            size: 40,
            semanticLabel: '展开直播间列表',
            onPressed: () => setState(() => _railCollapsed = false),
          ),
        if (!widget.showOwnerPanel && channel != null)
          AylaLiveHostAvatar(
            hostNickname: channel.ownerNickname,
            ownerNickname: channel.ownerNickname,
            size: 32,
          ),
        if (!widget.showOwnerPanel) ...<Widget>[
          Expanded(
            child: Text(
              title, // `.live-room-title`（web 用 ScrollingText 单行滚动）
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AylaTextStyles.of(context).body.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          if (tags.isNotEmpty)
            // 来源标签：三域统一的共享件 AylaSourceTag。
            // web «LiveRoomBody.tsx:257» 把可见范围列表交给 ScrollingTags 的 «title»（悬停读全列表）；
            // Flutter 侧头部不用滚动容器（窄屏只留 1–2 个标签）⇒ 用 AylaTooltip 表达同一提示。
            AylaTooltip(
              message: tags.join('、'),
              child: Row(
                spacing: AylaSpacing.sp1,
                children: <Widget>[
                  // 窄屏只留 1 个标签（web 靠 ScrollingTags 滚动承担；Flutter 侧避免窄屏头部溢出）
                  for (final String tag in tags.take(narrow ? 1 : 2))
                    AylaSourceTag(tag),
                ],
              ),
            ),
          if (channel != null)
            // 头部收藏 = **compact 32×32**（web `FavoriteButton compact`，
            // `LiveRoomBody.tsx:260 / 328`；⚠️ 别用带文字的 AylaGlassButton——
            // 它的横向 padding sp6 会让头部在窄屏溢出，实测 67px）。
            //
            // 状态档**原样透传三态**（web `tsx:69` 的禁用语义：unknown 且无 error ⇒ 禁用 +
            // 「正在加载收藏状态」）；2026-10-08 修正前是 `bool?` 把 unknown 折成未收藏。
            if (widget.favoriteTargetType != null &&
                widget.favoriteTargetId != null)
              // **自给自足档**（web 架构）：只给 targetType/targetId，
              // 状态/加载/切换全部由收藏键自己承担（`FavoriteButton.tsx:20–60`）⇒
              // 调用方漏接线也不会坏在这里。
              AylaFavoriteButton(
                targetType: widget.favoriteTargetType!,
                targetId: widget.favoriteTargetId!,
                controller: widget.favoriteController,
                compact: true,
              )
            else
              // **注入档**（既有调用点零影响）：状态档原样透传三态。
              AylaFavoriteButton(
                state: widget.favoriteState,
                compact: true,
                onToggle: (bool next) => widget.onToggleFavorite?.call(next),
                onRetryStatus: widget.onRetryFavoriteStatus,
              ),
          if (channel != null)
            AylaShareButton(
              label: '分享直播间',
              onPressed: widget.onShare,
            ),
        ],
        if (narrow)
          AylaIconButton(
            // `.live-room-rail-toggle`：40×40 玻璃圆钮（打开直播间列表）
            icon: AylaIcon(aylaIconByName('iconList')!, size: 20),
            size: 40,
            semanticLabel: '打开直播间列表',
            onPressed: () => setState(() => _railOpen = true),
          ),
      ],
    );
  }

  /// 头部槽位（切台时的「退出 → 进入」）。
  ///
  /// web 把头部从面板重播里**排除**：`mediaPanels` 三条 target 都不含 `.live-room-head`，
  /// 头部由 `LiveRoomHeader`（tsx 542–565）在 `AnimatePresence mode="wait"` 下单独编排
  /// ⇒ Flutter 侧同样两套 owner：[AylaRevealScope] 管三块面板，本件管头部。
  Widget _headerSwap({required bool narrow}) => _LiveRoomHeaderSwap(
    identity: widget.channelId,
    child: _headMaterial(narrow: narrow, child: _head(narrow: narrow)),
  );

  /// 面板重播包装（web `usePanelReplayMotion` 的 target）：切台时**不重挂**、只重播入场。
  ///
  /// [AylaRevealScope] 的 `replayKey` 换成新 channelId ⇒ 已入场项整批重播一次
  /// （对应 hook 的 `identity` 依赖）；两帧关键帧与 hook 的 WAAPI 完全一致
  /// （`{opacity:0, translate:±20}` → `{opacity:1, translate:0}`，300ms
  /// `cubic-bezier(0,0,.58,1)` = `--auroraqua-ease-out`）。[AylaRevealItem] 自带
  /// reduced-motion 与 `enabled` 开关，对应 hook 的 `if (!enabled || reduced) return;`
  /// （错误态整支不挂重播 —— 见 [build] 的错误分支：那条路径没有 [AylaRevealScope]）。
  Widget _replay(Offset offset, Widget child) => AylaRevealItem(
    fadeGlass: false,
    offset: offset,
    delay: Duration.zero, // web 三块同时播（hook 里没有 stagger）
    child: child,
  );

  /// 侧栏（宽屏常驻 / 窄屏覆盖层共用）。
  Widget _rail({required bool overlay}) => AylaLiveChannelRail(
    channels: widget.channels,
    currentId: widget.channelId,
    // 宽屏收起态交给侧栏自身表达（`collapsed` ⇒ 侧栏不渲染，展开键回到头部，tsx 292–308）
    collapsed: overlay ? false : _railCollapsed,
    enterFromRight: overlay,
    showBack: !overlay,
    onSelect: (String id) {
      widget.onSelect?.call(id);
      if (overlay) setState(() => _railOpen = false);
    },
    onToggle: () {
      if (overlay) {
        setState(() => _railOpen = false);
      } else {
        setState(() => _railCollapsed = true);
      }
    },
    onBack: overlay
        ? () => setState(() => _railOpen = false)
        : widget.onBack,
    onDeleteChannel: widget.showOwnerPanel ? widget.onDeleteChannel : null,
    onCreateNewChannel: widget.onCreateNewChannel,
    deletingChannelId: widget.deletingChannelId,
    directoryFooter: overlay ? widget.directoryFooter : widget.railDirectoryFooter,
  );

  /// 窄屏覆盖层：`.live-room-rail-overlay`（z 60）+ 遮罩（点关闭，tsx 382–403）。
  Widget? get _railOverlay {
    if (!(_isNarrow && _railOpen)) return null;
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          // 指针：`.live-room-rail-mask`（`LiveRoomBody.tsx:384` + `live.css:472–475`）
          // 是 `<div>`、**无 cursor 声明** ⇒ 浏览器默认箭头。
          // Flutter 侧不声明时 `defer` 会继续往外找（命中页面可点件即假显手型）。
          MouseRegion(
            cursor: SystemMouseCursors.basic,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _railOpen = false),
            // ⚠️ 必须 `SizedBox.expand`：无子级的 `ColoredBox` 在 Stack 的 loose 约束下会**塌成 0×0**
            //    ⇒ 遮罩收不到点击（实测：点遮罩关不掉覆盖层）。
            child: const SizedBox.expand(
              child: ColoredBox(color: Color(0x40465B92)), // rgba(70,91,146,.25)
            ),
          ),
          ),
          Align(alignment: Alignment.centerRight, child: _rail(overlay: true)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String modifier =
        '${widget.showOwnerPanel ? "is-studio" : ""} ${_isNarrow ? "is-narrow" : "is-wide"}';

    // ---- 进房错误态（tsx 405–435）：仍保留侧栏与弹幕区 ----
    if (widget.data.error case final String message) {
      return _shell(
        modifier: modifier,
        children: <Widget>[
          if (!_isNarrow && !widget.hideRail) _rail(overlay: false),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp3,
                children: <Widget>[
                  Text(
                    message,
                    style: AylaTextStyles.of(context).body.copyWith(
                      color: AylaColors.destructive,
                    ),
                  ),
                  AylaGlassButton(
                    label: '返回',
                    variant: AylaGlassButtonVariant.glow,
                    onPressed: widget.onBack,
                  ),
                ],
              ),
            ),
          ),
          _side(),
        ],
        overlay: _railOverlay,
      );
    }

    // ---- 窄屏沉浸式：上下滑切台（tsx 441–481）----
    if (_isNarrow && !widget.showOwnerPanel) {
      return _shell(
        modifier: '$modifier has-media-panel-motion',
        replayKey: widget.channelId,
        children: <Widget>[
          // ⚠️ 头部/滑切/输入框必须装在**一个 Expanded 的纵向列**里再交给外层 Row：
          //    直接作为 Row 的子级会拿到**无界宽度**，列内的 `Expanded` 会报
          //    「non-zero flex but incoming width constraints are unbounded」（实测）。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _headerSwap(narrow: true),
                Expanded(
                  child: Padding(
                    // `.live-room-body.is-narrow .live-room-swipe { margin: var(--sp-2) }`
                    // （live.css 715–724）⇒ 顶栏↔视频、视频↔输入框各留 **8px**；
                    // 左右也不贴边。
                    padding: const EdgeInsets.all(AylaSpacing.sp2),
                    child: GestureDetector(
                      onVerticalDragStart: (_) => setState(() {}),
                      onVerticalDragUpdate: (DragUpdateDetails d) => setState(() {
                        // dragElastic 0.8（tsx 52）：80% 跟手 + 20% 阻尼
                        _dragOffset += d.delta.dy * 0.8;
                      }),
                      onVerticalDragEnd: (DragEndDetails d) =>
                          _handleSwipeEnd(d.velocity.pixelsPerSecond.dy),
                      child: AnimatedContainer(
                        // 松手回弹：`_dragOffset` 归零后由隐式动画收回（300ms auroraqua）
                        duration: AylaDurations.auroraqua,
                        curve: AylaCurves.auroraquaEaseOut,
                        transform: Matrix4.translationValues(0, _dragOffset, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            // web target ① `{scene} > .live-room-stage`（edge bottom）
                            // `.live-room-stage`：窄屏 `flex: none` + 四角收 `--radius-input`
                            // （live.css 825–828；播放器自身圆角/边框已由 flat 档去掉）
                            _replay(
                              const Offset(0, AylaRevealMotion.distance),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AylaRadii.rInput,
                                ),
                                child: _stage(clipRadius: false),
                              ),
                            ),
                            // web target ② `{scene} > .live-viewer-strip`（edge bottom）
                            // `.live-room-body.is-narrow .live-room-swipe-item > .live-viewer-strip`
                            // `{ margin-top: var(--sp-2) }`（live.css 1187–1191）
                            _replay(
                              const Offset(0, AylaRevealMotion.distance),
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: AylaSpacing.sp2,
                                ),
                                child: _viewerStrip,
                              ),
                            ),
                            // web target ③ `{scene} > .danmaku-wrap`（edge right）
                            Expanded(
                              child: _replay(
                                const Offset(AylaRevealMotion.distance, 0),
                                _danmakuList,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _danmakuInput,
              ],
            ),
          ),
        ],
        overlay: _railOverlay,
      );
    }

    // ---- 宽屏观看 + 开播控制台（tsx 484–538）----
    // 切台 ⇒ `.live-room-main > .live-room-stage` / `> .live-viewer-strip` / `.live-room-side`
    // 三块重播入场（web mediaPanels 的宽屏/控制台档选择器）。
    return _shell(
      modifier: '$modifier has-media-panel-motion',
      replayKey: widget.channelId,
      children: <Widget>[
        if (!_isNarrow && !widget.hideRail) _rail(overlay: false),
        Expanded(
          child: Padding(
            // `.live-room-main { gap sp3; padding sp4 }`（app.css 3486–3493）
            // + live.css 681–687（宽屏：`padding-top/bottom: var(--sidebar-gutter)` = 12）
            padding: EdgeInsets.fromLTRB(
              AylaSpacing.sp4,
              _isNarrow ? AylaSpacing.sp3 : AylaSpacing.sidebarGutter,
              AylaSpacing.sp4,
              _isNarrow
                  ? AylaSpacing.sp3
                  : AylaSpacing.sidebarGutter,
            ),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              // 头部自带进退场（web 把头部从面板重播里**排除**，由 LiveRoomHeader 单独编排）
              if (_isNarrow || !widget.showOwnerPanel) _headerSwap(narrow: _isNarrow),
              if (!widget.showOwnerPanel) ...<Widget>[
                // **观看态（宽屏非控制台）**：stage 占住主区剩余高 ⇒ 播放器按 container query
                // 语义取宽（`.live-room-player-wrap { container-type: size }` +
                // `.live-player { width: min(100%, 100cqh * 1.7778) }`，live.css 700–760）
                // ⇒ **侧栏收起/展开只改变宽度，播放器高度不变**（明确）。
                // web target ① `:scope > .live-room-main > .live-room-stage`（edge bottom）
                Expanded(
                  child: _replay(
                    const Offset(0, AylaRevealMotion.distance),
                    _stageFitted(),
                  ),
                ),
                // web target ② `:scope > .live-room-main > .live-viewer-strip`（edge bottom）
                _replay(const Offset(0, AylaRevealMotion.distance), _viewerStrip),
              ] else
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: AylaSpacing.sp3,
                    children: <Widget>[
                      if (widget.data.channel?.isOwner ?? false)
                        AylaLiveOwnerPanel(
                          channel: widget.data.channel!,
                          onStart: widget.onStartLive,
                          onStop: widget.onStopLive,
                          onSave: widget.onSaveOwner,
                          groups: widget.groups,
                        ),
                      // 控制台同样是 `.live-room-main > .live-room-stage` + 观众条（target ①②）
                      _replay(
                        const Offset(0, AylaRevealMotion.distance),
                        _stage(clipRadius: true),
                      ),
                      _replay(
                        const Offset(0, AylaRevealMotion.distance),
                        _viewerStrip,
                      ),
                      if (widget.data.channel?.isOwner ?? false)
                        AylaLiveStreamAddresses(
                          rtmpUrl: widget.data.channel!.rtmpUrl,
                          streamKey: widget.data.channel!.streamKey,
                          flvUrl: widget.data.channel!.flvUrl,
                        ),
                    ],
                  ),
                ),
              ),
            ],
            ),
          ),
        ),
        // web target ③ `:scope > .live-room-side`（edge right）
        _replay(const Offset(AylaRevealMotion.distance, 0), _side()),
      ],
      // 覆盖层必须是 Stack 直接子级（见 _shell 说明）
      overlay: _railOverlay,
    );
  }

  /// 观看态（宽屏非控制台）的 stage：**container-query 等价**。
  ///
  /// 事实源：live.css 700–760（`.live-room-body.is-wide:not(.is-studio) .live-room-player-wrap
  /// { align-self: stretch; min-height: 0; display: flex; align-items: center; container-type: size }`
  /// + `.live-player { aspect-ratio: 16/9; width: min(100%, 100cqh * 1.7778); max-height: 100% }`）
  /// ⇒ 播放器**高度由容器高决定**，宽度取「可用宽」与「可用高 × 16/9」的较小者。
  /// 于是左侧栏收起/展开时**只改变宽度、高度不变**（指出的正是这一点）。
  Widget _stageFitted() => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final double maxH = c.maxHeight.isFinite ? c.maxHeight : c.maxWidth * 9 / 16;
      final double w = math.min(c.maxWidth, maxH * 16 / 9);
      return Center(
        child: SizedBox(width: w, height: w * 9 / 16, child: _player),
      );
    },
  );

  /// `.live-room-stage`（开播控制台：内容高由 16:9 决定，整页可滚）。
  Widget _stage({required bool clipRadius}) {
    final Widget player = _player;
    if (!clipRadius) return player; // 沉浸式：播放器自身去圆角由调用方裁剪
    return Center(child: player);
  }

  /// `.live-room-side`：弹幕列表 + 输入框（实测「弹幕区也弄错了，有现成的卡片」）。
  ///
  /// 事实源：app.css 3648–3657（`width 340` / column / `--glass-bg` / `border-left` /
  /// `blur(12px)`）+ **auroraqua 392–400（≥769，后加载覆盖）**：`margin 12` / 1px 亮边 /
  /// `radius 16` / `--glass-shadow` / `blur24 sat1.4` ⇒ 实渲染是**一张卡片**，宽度 **340**。
  /// 列内的输入条被 auroraqua 555–567 清成透明（材质归本卡片）⇒ 输入用 `sideCard` 档。
  Widget _side() => Padding(
    padding: const EdgeInsets.all(AylaSpacing.sidebarGutter), // margin: var(--sidebar-gutter)
    child: SizedBox(
      width: 340,
      child: AylaGlassSurface(
        radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard,
        shadow: AylaShadows.glass,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[Expanded(child: _danmakuList), _danmakuInput],
        ),
      ),
    ),
  );

  /// 房间根：`.live-room.live-room-body`（相对定位 + Stack 承载侧栏覆盖层）。
  ///
  /// ⚠️ 覆盖层是 [Positioned] ⇒ 必须是 **Stack 的直接子级**（放进 Row 会触发
  /// ParentDataWidget 断言，实测）⇒ 单独一个槽位，不混在 `children` 里。
  Widget _shell({
    required String modifier,
    required List<Widget> children,
    Widget? overlay,
    Object? replayKey,
  }) {
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    return Stack(
      children: <Widget>[
        // 切台 ⇒ `replayKey` 换新 channelId，面板**整批重播入场**
        // （web `usePanelReplayMotion(String(channelId), mediaPanels, !error)`）。
        // ⚠️ 只包**内容行**：窄屏列表覆盖层是常驻 owner（`AylaRevealItem` 只在挂载时入场），
        //    不能跟着切台重播 ⇒ overlay 槽留在 scope 之外。
        replayKey == null
            ? row
            : AylaRevealScope(replayKey: replayKey, child: row),
        ?overlay,
      ],
    );
  }
}

/// 切台时头部「退出 → 进入」（web `LiveRoomHeader`，tsx 541–565）。
///
/// ## 事实源
/// ```
/// tsx 444–446 / 506–508   <AnimatePresence mode="wait" propagate><LiveRoomHeader key={channelId}>
/// tsx 546–548             useLayoutEffect → ref.toggleAttribute("inert", !present)
/// tsx 553–561             aria-hidden={!present} · pointer-events:none · initial={reduced ? false : "enter"}
/// tsx 561                 variants = panelVariants(reduced, "top")（auroraquaMotion 37–51）
/// auroraquaMotion 11–19   distance 20 · duration 0.3s · easeInOut [.42,0,.58,1]
/// auroraquaMotion 45      reduced ⇒ transition { duration: 0 }
/// ```
/// `mode="wait"` ⇒ 旧头**先播完 300ms 退出**（期间 inert / aria-hidden / pointer-events:none），
/// 才挂新头并播入场；两段合计 600ms。退出边 = 进场边（`panelVariants` 默认 `exitEdge = edge`）。
///
/// ## 与 [AylaPanelTransition] 的关系（登记；本件不改它）
/// 位移（±[kAylaPanelDistance]）/ 时长（[kAylaPanelDuration]）/ 缓动
/// （[AylaCurves.auroraquaEaseInOut]）与 [AylaPanelTransition] 同源 —— 它就是
/// `panelVariants` 的 Flutter owner，`show: false` 走的正是这条退场曲线。
/// 本件没有直接复用它只有一个原因：它只持**一支**件的 enter/exit（`show` 驱动），
/// 而这里要的是**新旧两支件串行**（web 由 `AnimatePresence mode="wait"` 提供）
/// 与退出期的 inert/aria 语义（web 由 `useIsPresent()` 提供）；它不暴露「已退场」回调，
/// 串行只能靠外部计时。若将来 [AylaPanelTransition] 带上 `identity`/`onExited` 能力，
/// 本件可整体替换为它（常量与曲线已对齐，库内不出现第二套配方）。
class _LiveRoomHeaderSwap extends StatefulWidget {
  const _LiveRoomHeaderSwap({required this.identity, required this.child});

  /// 头部身份（web `key={channelId}`）：变化 ⇒ 旧头退出，播完再挂新头。
  final String identity;

  /// 当前 identity 的头部内容。
  final Widget child;

  @override
  State<_LiveRoomHeaderSwap> createState() => _LiveRoomHeaderSwapState();
}

class _LiveRoomHeaderSwapState extends State<_LiveRoomHeaderSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaPanelDuration,
    value: 1,
  );

  /// `easeInOut [.42,0,.58,1]`（`auroraquaRouteTransition`）。
  late final CurvedAnimation _t = CurvedAnimation(
    parent: _c,
    curve: AylaCurves.auroraquaEaseInOut,
  );

  /// 当前挂在树上的 identity 与它的内容（退出期间仍是**旧**的）。
  late String _current = widget.identity;
  late Widget _child = widget.child;

  /// 正在退出的旧头内容（null ⇒ 不在退出中）。
  ///
  /// 快照的是**旧 widget 实例**（旧 props）：对应 React 在退出期保留旧 element 的行为
  /// —— 直接读 `widget.data` 会拿到新频道的数据，退出动画就会「内容已变、只播位移」。
  Widget? _leavingChild;

  bool _started = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 首帧挂载即入场（web `initial={reduced ? false : "enter"}`）
    if (!MediaQuery.disableAnimationsOf(context)) _c.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed ||
        !mounted ||
        _leavingChild == null) {
      return;
    }
    // 旧头播完 ⇒ 挂**最新**请求的 identity（快速连切时中间态不挂载）
    setState(() {
      _current = widget.identity;
      _child = widget.child;
      _leavingChild = null;
    });
    _c.forward(from: 0); // 新头入场
  }

  @override
  void didUpdateWidget(_LiveRoomHeaderSwap old) {
    super.didUpdateWidget(old);
    // identity 未变：内容跟随刷新（不重播）
    if (old.identity == widget.identity) {
      if (_leavingChild == null) _child = widget.child;
      return;
    }
    if (!MediaQuery.disableAnimationsOf(context)) {
      if (_leavingChild != null) return; // 已在退出中 ⇒ 只更新 identity
      _leavingChild = _child; // 退出期渲染旧头
      _c.reverse();
      return;
    }
    // reduced-motion：`panelVariants` 过渡 duration 0 + `initial=false` ⇒ 两段都瞬时
    setState(() {
      _current = widget.identity;
      _child = widget.child;
      _leavingChild = null;
    });
  }

  @override
  void dispose() {
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final Widget? leaving = reduced ? null : _leavingChild;
    final Widget animated = AnimatedBuilder(
      animation: _t,
      builder: (BuildContext context, Widget? child) {
        // ±20 / 300ms / easeInOut —— 进场与退场共用同一公式（退出边 = 进场边）
        final double v = reduced ? 1 : _t.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, -kAylaPanelDistance * (1 - v)),
            child: child,
          ),
        );
      },
      // key = 已挂载的 identity：退出期保持不动，播完换新 identity ⇒ 新头**重挂**
      // （web AnimatePresence mode="wait" 是旧件 unmount + 新件 mount，React 状态不残留）
      child: KeyedSubtree(
        key: ValueKey<String>(_current),
        child: leaving ?? _child,
      ),
    );
    if (leaving == null) return animated;
    // 退出中的旧头：web `inert` + `aria-hidden` + `pointer-events: none`（tsx 547–556）
    // （Flutter 等价：ExcludeFocus = inert 的不可聚焦 · ExcludeSemantics = aria-hidden ·
    //  IgnorePointer = pointer-events:none）
    return ExcludeFocus(
      child: ExcludeSemantics(child: IgnorePointer(child: animated)),
    );
  }
}

/// 频道可见性标签（web `getVisibilityLabels` 的等价；`visibility` 缺失 ⇒ 空）。
List<String> aylaVisibilityLabelsOf(AylaLiveChannelSnapshot channel) {
  final String? visibility = channel.visibility;
  if (visibility == null || visibility.isEmpty) return const <String>[];
  return switch (visibility) {
    'public' => const <String>['公开'],
    'friends' => const <String>['好友可见'],
    _ => <String>[
      if (channel.group != null && channel.group!.isNotEmpty) '群可见',
    ],
  };
}

// ======================= 预览样张 =======================

/// 直播间装配样张（宽屏三栏 / 窄屏沉浸式 / 错误态）。
Widget aylaLiveRoomBodySamples() {
  final List<AylaLiveCardData> channels = <AylaLiveCardData>[
    const AylaLiveCardData(
      id: 'lc1',
      title: '深夜电台 · 爱莉陪你写代码',
      status: AylaLiveStatus.live,
      viewerCount: 12,
    ),
    const AylaLiveCardData(
      id: 'lc2',
      title: '第二场直播',
      status: AylaLiveStatus.live,
      viewerCount: 3,
    ),
  ];
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(1100, 620),
        label:
            '宽屏直播间（`.live-room-body.is-wide`）· 三栏 = 侧栏 240 + 主区（头部 + stage(player 16:9) + 观众条）+ 弹幕侧列（列表 + 输入框）· 可交互：点侧栏切台 / 收起侧栏 / 悬停播放器显控件',
        child: AylaLiveRoomBody(
          channelId: 'lc1',
          isNarrow: false,
          channels: channels,
          data: AylaLiveRoomData(
            channel: const AylaLiveChannelSnapshot(
              id: 'lc1',
              title: '深夜电台 · 爱莉陪你写代码',
              status: AylaLiveStatus.live,
              visibility: 'public',
              ownerNickname: '爱莉',
            ),
            srsStatus: AylaLiveSrsStatus.live,
            viewerCount: 12,
            danmaku: const <AylaDanmakuEntry>[
              AylaDanmakuEntry(id: 'd1', senderNickname: '小樱', content: '来了来了'),
            ],
          ),
          videoView: const ColoredBox(
            color: Color(0xFF2A3550),
            child: SizedBox(width: 160, height: 90),
          ),
          onSendDanmaku: (String content, String? mediaId) async => true,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 700),
        label:
            '窄屏沉浸式（`.live-room-body.is-narrow`）· 头部固定 + **视频与弹幕区整体上下滑切台**（松手判定：位移 > 1/3 高优先 / 同向甩动补充）+ 输入框固定 + 右下列表键打开覆盖层',
        child: AylaLiveRoomBody(
          channelId: 'lc1',
          isNarrow: true,
          channels: channels,
          data: const AylaLiveRoomData(
            channel: AylaLiveChannelSnapshot(
              id: 'lc1',
              title: '深夜电台',
              status: AylaLiveStatus.live,
              visibility: 'friends',
            ),
            srsStatus: AylaLiveSrsStatus.live,
            viewerCount: 5,
          ),
          videoView: const ColoredBox(color: Color(0xFF2A3550)),
          onSendDanmaku: (String content, String? mediaId) async => true,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(900, 300),
        label: '进房错误态：**仍保留侧栏与弹幕区**，主区显示错误 + `.btn-glow`「返回」（tsx 408 注释：避免卡在只有返回键的死页面）',
        child: AylaLiveRoomBody(
          channelId: 'lc1',
          isNarrow: false,
          channels: channels,
          data: const AylaLiveRoomData(error: '进房失败：网络异常'),
          videoView: null,
        ),
      ),
    ],
  );
}

/// 固定视口的样张舞台。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.child,
  });

  final Size viewport;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}
