/// live 域最后一批（B2-6）之三：直播间核心装配（`LiveRoomBody.tsx` 566 行）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// tsx 405–435          进房错误态：仍保留**侧栏与弹幕区**（宽屏 + 非 hideRail），
///                      主区换 `.live-room-error`（`<p>error</p>` + `.btn.btn-glow`「返回」）
/// tsx 441–481          **窄屏沉浸式**（isNarrow && !showOwnerPanel）：
///                      head（窄屏头）→ `.live-room-swipe`（**上下滑切台**，dragElastic 0.8、
///                      位移 > 1/3 高优先 + 同向甩动补充）→ `.live-room-swipe-item`
///                      （`data-live-scene-owner`）= stage(player) + viewerStrip + danmakuList
///                      → 输入框（`.live-room-input`）→ 侧栏覆盖层
/// tsx 484–538          宽屏观看 + 开播控制台：三栏 `.live-room-body.is-wide`
///                      = `.live-rail`（!hideRail，可收起）+ `.live-room-main`
///                      （head + 控制台资料栏 + `.live-room-stage > .live-room-player-wrap`(player)
///                      + viewerStrip + 推流地址）+ `.live-room-side`（弹幕列表 + 输入框）
///                      + 窄屏侧栏覆盖层
/// tsx 132–134          railCollapsed（宽屏默认展开）/ railOpen（窄屏覆盖层默认关闭）
/// tsx 205–224          player 槽：LivePlayer + **仅 `!loading && srsStatus==="live"` 才挂
///                      DanmakuOverlay**（避免未就绪时挂播放器投影）
/// tsx 234–283          窄屏头：返回(icon-btn-40) + 主播头像(32) + 标题滚动（loading→「加载中…」）
///                      + 来源标签滚动 + 收藏(compact) + 转发 + `.live-room-rail-toggle`(40×40)
/// tsx 285–342          宽屏头：hideRail → 只留返回；railCollapsed → 返回 + 展开键
///                      （IconChevronRight 20）；头像 + 标题 + 来源标签 + 收藏 + 转发
/// tsx 382–403          窄屏侧栏覆盖层：`.live-room-rail-overlay`（z 60）
///                      = `.live-room-rail-mask`（点关闭）+ `LiveChannelRail(enterFromRight,
///                      showBack=false, onToggle=关闭)`
/// tsx 96–111           **全屏期间冻结 isNarrow**：手机全屏会锁横屏 → viewport 变宽 →
///                      窄↔宽布局切换会让播放器重建（黑屏）⇒ 冻结进入全屏前的形态
/// live.css 10–12/23    `.live-room-body.is-wide > .live-rail` sidebar-in · 主区 side from-right
///                      · head from-top（reduced-motion 关闭）
/// live.css 704–760     宽屏非控制台：`.live-player { width: min(100%, 100cqh*1.7778) }`
///                      （stage 按容器高定尺寸，避免播放器把弹幕列挤没）
/// live.css 747–755     沉浸式内：`.live-room-swipe-item .live-player` 去圆角去边框（由 stage 裁剪）
/// live.css 526–528     窄屏：`.live-room-body.is-narrow .live-player { max-height: 100% }`
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - **数据全部由页面注入**（[AylaLiveRoomData] + 回调）：web 的 `useLiveRoom` / `useDanmaku` /
///   live store 属数据层与运行时（HLS、WS、轮询），不进 `lib/widgets`；
/// - video 由页面持有（`HlsPlaybackController`），本件只把它交给 [AylaLivePlayer]；
/// - 侧栏 = 复用 [AylaLiveChannelRail]；弹幕三件 = 复用 [AylaDanmakuList] / [AylaDanmakuInput] /
///   [AylaDanmakuOverlay]；观众条 = 复用 [AylaLiveViewerStrip]；控制台 = 复用
///   [AylaLiveOwnerPanel] + [AylaLiveStreamAddresses]；头部来源标签 = 复用 **AylaSourceTag** 的滚动容器。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'danmaku.dart'
    show
        AylaDanmakuEntry,
        AylaDanmakuInput,
        AylaDanmakuInputMaterial,
        AylaDanmakuList,
        AylaDanmakuOverlay;
import 'directory_controls.dart'
    show AylaFavoriteButton, AylaHistoryControlsData, FavoriteState;
import 'live_channel_snapshot.dart';
import 'live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import 'live_owner_panel.dart' show AylaLiveOwnerPanel, AylaLiveOwnerSaveRequest;
import 'live_player.dart' show AylaLivePlayer, AylaLiveSrsStatus;
import 'live_rail.dart' show AylaLiveChannelRail;
import 'live_studio.dart' show AylaLiveHostAvatar, AylaLiveStreamAddresses;
import 'live_viewers.dart'
    show AylaLiveViewerItem, AylaLiveViewerSheetData, AylaLiveViewerStrip;
import 'primitives.dart' show AylaSourceTag;
import 'share.dart' show AylaShareButton;

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
    this.favoriteState,
    this.onShare,
    this.videoView,
    this.directoryFooter,
    this.onOpenProfile,
    this.onSaveOwner,
    this.onStartLive,
    this.onStopLive,
    this.railDirectoryFooter,
    this.groups = const <({String id, String title})>[],
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
  final bool? favoriteState;
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

  /// 头部**容器材质**（用户 2026-09-22 实报「顶栏漏了背景」）。
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
    return GlassSurface(
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
        // 收起侧栏后多出 40 高的返回/展开键会让顶栏从 53 长到 56（用户 2026-09-22 指出
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
            // 来源标签：三域统一的共享件 AylaSourceTag
            Row(
              spacing: AylaSpacing.sp1,
              children: <Widget>[
                // 窄屏只留 1 个标签（web 靠 ScrollingTags 滚动承担；Flutter 侧避免窄屏头部溢出）
                for (final String tag in tags.take(narrow ? 1 : 2))
                  AylaSourceTag(tag),
              ],
            ),
          if (channel != null)
            // 头部收藏 = **compact 32×32**（web `FavoriteButton compact`；
            // ⚠️ 别用带文字的 GlassButton——它的横向 padding sp6 会让头部在窄屏溢出，实测 67px）
            AylaFavoriteButton(
              state: (widget.favoriteState ?? false)
                  ? FavoriteState.favorited
                  : FavoriteState.notFavorited,
              compact: true,
              onToggle: (bool next) => widget.onToggleFavorite?.call(next),
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _railOpen = false),
            // ⚠️ 必须 `SizedBox.expand`：无子级的 `ColoredBox` 在 Stack 的 loose 约束下会**塌成 0×0**
            //    ⇒ 遮罩收不到点击（实测：点遮罩关不掉覆盖层）。
            child: const SizedBox.expand(
              child: ColoredBox(color: Color(0x40465B92)), // rgba(70,91,146,.25)
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
                  GlassButton(
                    label: '返回',
                    variant: GlassButtonVariant.glow,
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
        children: <Widget>[
          // ⚠️ 头部/滑切/输入框必须装在**一个 Expanded 的纵向列**里再交给外层 Row：
          //    直接作为 Row 的子级会拿到**无界宽度**，列内的 `Expanded` 会报
          //    「non-zero flex but incoming width constraints are unbounded」（实测）。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _headMaterial(narrow: true, child: _head(narrow: true)),
                Expanded(
                  child: Padding(
                    // `.live-room-body.is-narrow .live-room-swipe { margin: var(--sp-2) }`
                    // （live.css 715–724）⇒ 顶栏↔视频、视频↔输入框各留 **8px**；
                    // 左右也不贴边（用户 2026-09-22：「顶栏与画面、画面与观众区紧贴」）。
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
                            // `.live-room-stage`：窄屏 `flex: none` + 四角收 `--radius-input`
                            // （live.css 825–828；播放器自身圆角/边框已由 flat 档去掉）
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AylaRadii.rInput,
                              ),
                              child: _stage(clipRadius: false),
                            ),
                            // `.live-room-body.is-narrow .live-room-swipe-item > .live-viewer-strip`
                            // `{ margin-top: var(--sp-2) }`（live.css 1187–1191）
                            Padding(
                              padding: const EdgeInsets.only(
                                top: AylaSpacing.sp2,
                              ),
                              child: _viewerStrip,
                            ),
                            Expanded(child: _danmakuList),
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
    return _shell(
      modifier: '$modifier has-media-panel-motion',
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
              if (_isNarrow || !widget.showOwnerPanel)
                _headMaterial(narrow: _isNarrow, child: _head(narrow: _isNarrow)),
              if (!widget.showOwnerPanel) ...<Widget>[
                // **观看态（宽屏非控制台）**：stage 占住主区剩余高 ⇒ 播放器按 container query
                // 语义取宽（`.live-room-player-wrap { container-type: size }` +
                // `.live-player { width: min(100%, 100cqh * 1.7778) }`，live.css 700–760）
                // ⇒ **侧栏收起/展开只改变宽度，播放器高度不变**（用户 2026-09-22 明确）。
                Expanded(child: _stageFitted()),
                _viewerStrip,
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
                      _stage(clipRadius: true),
                      _viewerStrip,
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
        _side(),
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
  /// 于是左侧栏收起/展开时**只改变宽度、高度不变**（用户 2026-09-22 指出的正是这一点）。
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

  /// `.live-room-side`：弹幕列表 + 输入框（用户 2026-09-22 实报「弹幕区也弄错了，有现成的卡片」）。
  ///
  /// 事实源：app.css 3648–3657（`width 340` / column / `--glass-bg` / `border-left` /
  /// `blur(12px)`）+ **auroraqua 392–400（≥769，后加载覆盖）**：`margin 12` / 1px 亮边 /
  /// `radius 16` / `--glass-shadow` / `blur24 sat1.4` ⇒ 实渲染是**一张卡片**，宽度 **340**。
  /// 列内的输入条被 auroraqua 555–567 清成透明（材质归本卡片）⇒ 输入用 `sideCard` 档。
  Widget _side() => Padding(
    padding: const EdgeInsets.all(AylaSpacing.sidebarGutter), // margin: var(--sidebar-gutter)
    child: SizedBox(
      width: 340,
      child: GlassSurface(
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
  }) {
    return Stack(
      children: <Widget>[
        Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ?overlay,
      ],
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

/// 直播间核心装配。
@Preview(
  group: 'Widgets',
  name: '直播间装配',
  size: Size(1160, 1800),
  wrapper: previewTheme,
)
Widget aylaLiveRoomBodyPreview() => aylaLiveRoomBodySamples();
