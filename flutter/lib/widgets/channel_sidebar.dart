/// AylaChannelSidebar —— 宽屏频道/场景侧栏（重做版）。
///
/// ## 事实源（逐条标注，禁自由发挥）
/// - 结构/行为：`Ayla/web/src/layout/ChannelSidebar.tsx`（627 行）
/// - 样式：`Ayla/web/src/styles/group.css` 680–1370（`.channel-sidebar*` /
///   `.channel-scene*` / `.channel-subgroup*` / `.channel-voice-room*` /
///   `.channel-live-room*`）+ 318–331（`.channel-subgroup-muted`）
/// - 覆写：`Ayla/web/src/styles/auroraqua.css` 54–94（按钮组 200ms + hover1.02 +
///   active .98，**含三个三角展开键**）、142–166（扫光 600ms）、175–197（导航胶囊 +
///   选中自身底取消）、187（胶囊扫光 700ms）、236–249（导航组 300ms transition +
///   `:active .98`）、288–291（子列表选中行自身底取消）、310–313（≥769 关 CSS 入场）、
///   527–545（`@supports not backdrop-filter` → `--surface`）、655–676（reduced-motion）
/// - 动态裁剪语义：`Ayla/web/src/hooks/useSidebarContentClip.ts`（paint-only `clip-path`）
/// - 动画配方：`Ayla/web/src/components/motion/auroraquaMotion.ts`
/// - 数据契约：`hooks/useDirectoryPage.ts` / `hooks/useSocialPage.ts` /
///   `stores/subgroup.ts` 19–23（排序）/ `api/types.ts`（SubGroup 416、
///   VoiceChannelDescriptor 863、LiveChannelDescriptor 1035）
/// - 设计：`Ayla/docs/design.md` §12.4；推导表 `Ayla/docs/flutter/16-频道侧栏推导表.md`
///
/// ## 本轮边界（用户 2026-09-21 裁决）
/// - 弹窗接线**不做**（CreateSheet / VoiceChannelCreate / LiveStartSheet /
///   SubGroupDialog / ConfirmDialog 属后续批次）→「＋ / 笔」照 web 渲染、点击暂无副作用；
/// - `.channel-scene-status` 在 web **零样式**（grep 全目录无命中）→ 语音在麦人数与
///   LIVE 是**继承父级样式的裸文本**，不做胶囊；
/// - 自建 CSS `position: sticky`：三行依次吸顶（chat 0 / voice 44+吸底52 / live 88+吸底8）
///   + 下拉内容随列滚动 + 动态裁剪。
///
/// ## 自建 sticky 的实现纪律（`13-*` §6.8/§6.10/§6.11 的完整落地）
/// - 滚动内容里只放**行占位**（`SizedBox(height: 40)`），行本体画在顶层浮层；
/// - 位置的 clamp 公式 = `max(top, min(follow, viewportBottom − 40 − bottom))`
///   （**top 优先**；写成 `min(max(...))` 在视口不足时会越过 top）；
/// - 定位在 **paint**（`_SidebarStickyRow`）与**同一帧**的 `localToGlobal` 上做，
///   零滞后；`performLayout` 自写、`applyPaintTransform` 必须同偏移；
/// - 追踪窗口：展开/收起等隐式动画期间由 `Ticker` 每帧 `markNeedsPaint`
///   （`AnimatedSize` 只重绘自身、不触发父级 build）；
/// - 动态裁剪：`_SidebarDropdownClip` 在 paint 里按「本行吸顶后的底 + gap」到
///   「下一行吸顶后的顶 − gap」裁剪，等价 `useSidebarContentClip` 的 `inset()`。
library;

import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'directory_controls.dart';
import 'primitives.dart';
import 'resource_image.dart';
import 'reveal.dart';
import 'tab_badge.dart';

// ======================= 尺寸常量（逐条对应 web 行号） =======================

/// 侧栏几何常量。**每个数值都来自 web 源码行号**（见各行注释）。
abstract final class _SidebarMetrics {
  /// `.channel-sidebar { width: 260px }`（group.css 691）。
  static const double cardWidth = 260;

  /// `.channel-sidebar { margin: var(--sidebar-gutter) }` = 12（group.css 700）。
  static const double gutter = AylaSpacing.sidebarGutter;

  /// `.channel-sidebar-slot { width: calc(260px + 2 * gutter) }`（group.css 684）。
  static const double slotWidth = cardWidth + gutter * 2;

  /// `.channel-sidebar { border: 1px solid … }`（group.css 698）——CSS 里 border
  /// 占布局（内容区 258），Flutter 的 `BoxDecoration(border:)` 不占 → 必须用
  /// 1px padding 补位（`13-*` §6.5）。
  static const double borderWidth = 1;

  /// `.channel-sidebar-list { padding: 0 var(--sp-2) }`（group.css 728）。
  static const double listPaddingH = AylaSpacing.sp2;

  /// `.channel-sidebar-list { gap: var(--sp-1) }`（group.css 727）。
  static const double listGap = AylaSpacing.sp1;

  /// `.channel-scene { height: 40px }`（group.css 753）。
  static const double rowHeight = 40;

  /// 卡片内容区宽 = 260 − 2×1（边框）= 258。
  static const double cardContentWidth = cardWidth - borderWidth * 2;

  /// 列表内容轨道宽 = 258 − 2×8 = **242**（行/下拉的可用宽）。
  static const double trackWidth = cardContentWidth - listPaddingH * 2;

  /// `.channel-subgroup-list / .channel-voice-room-list / .channel-live-room-list
  /// { padding-left: 40px }`（group.css 1019 / 1160 / 1255）。
  static const double indent = 40;

  /// `.channel-*-item { padding-right: 2px }`（group.css 1027 / 1168 / 1262）
  /// ⇒ 行内按钮宽 = (242 − 40) − 2 = 200（**胶囊尺寸不按此推算**：照范本用实测矩形）。

  /// `.channel-subgroup-item / .channel-voice-room-item { height: 30px }`
  /// （group.css 1026 / 1167）。
  static const double childHeight = 30;

  /// `.channel-subgroup-list / .channel-voice-room-list { gap: 1px }`
  /// （group.css 1017 / 1159）→ 折叠高度公式 `min(3,n)×31 − 1`（tsx 297）。
  static const double childGap = 1;

  /// 子列表「行距」= 30 + 1 = 31（折叠高度与重排定位用）。
  static const double childPitch = childHeight + childGap;

  /// `.channel-live-rooms / .channel-live-room-list { gap: 4px }`
  /// （group.css 1245 / 1254）。
  static const double liveGap = AylaSpacing.sp1;

  /// `.channel-live-room { padding: 6px var(--sp-2) }` + 封面 36 高
  /// （group.css 1285 / 1301）⇒ 行高 48。
  static const double liveRowHeight = 48;

  /// 三个场景行的吸顶位（group.css 814–816）。
  static const double stickyChatTop = 0;
  static const double stickyVoiceTop = 44;
  static const double stickyVoiceBottom = 52;
  static const double stickyLiveTop = 88;
  static const double stickyLiveBottom = 8;

  /// 行内浮层钮：`-add / -edit { right: 38px }`、`-toggle { right: 6px }`，
  /// 均 28×28（group.css 836–843 / 859–866 / 894–901 / 917–924 / 949–956 / 973–980）。
  static const double overlayButtonSize = 28;
  static const double overlayButtonRight = 6;
  static const double overlayButtonSecondaryRight = 38;

  /// `.channel-scene-row .channel-scene { padding-right: 40px }`（group.css 822）；
  /// 有 ＋/笔 时 76（826–828 / 831–833 / 889–891）。
  static const double rowPaddingRight = 40;
  static const double rowPaddingRightDouble = 76;

  /// `.channel-sidebar-list-bottom { padding: var(--sp-2) var(--sp-2) var(--sp-3) }`
  /// + `border-top: 1px`（group.css 745–746）→ 顶部内容起点 = 1 + 8 = 9。
  static const double bottomPaddingTop = AylaSpacing.sp2 + borderWidth;
  static const double bottomPaddingBottom = AylaSpacing.sp3;

  /// 直播间封面：`width: 64px; aspect-ratio: 16/9`（group.css 1300–1301）。
  static const double liveCoverWidth = 64;
  static const double liveCoverHeight = 36;

  /// `.channel-live-dot { top: 4px; right: 4px; width/height: 8px }`
  /// （group.css 1327–1332）；relative 于 padding box ⇒ 距外框 1+4。
  static const double liveDotSize = 8;
  static const double liveDotInset = 4 + borderWidth;
}

/// 下拉容器内边距（web 三处不同）。
abstract final class _SidebarDropdownBox {
  /// `.channel-subgroups / .channel-voice-rooms { gap:2px; padding: 2px 0 4px }`
  /// （group.css 1004–1008 / 1147–1151）。
  static const double childGap = 2;
  static const double childPaddingTop = 2;
  static const double childPaddingBottom = 4;

  /// `.channel-live-rooms { gap:4px; padding: 4px 0 6px }`（group.css 1242–1246）。
  static const double liveGap = AylaSpacing.sp1;
  static const double livePaddingTop = AylaSpacing.sp1;
  static const double livePaddingBottom = 6;
}

/// 「展开更多 / ＋添加」按钮（`.channel-subgroup-more` 1102–1144 等四处同规格）。
abstract final class _SidebarMoreButton {
  static const double height = 28;
  static const double marginTop = AylaSpacing.sp1;
  static const double paddingH = AylaSpacing.sp3;
  static const double fontSize = 12;
}

/// 行 hover / 选中底色（group.css 756 / 766 / 1033 / 1174 / 1268）。
abstract final class _SidebarTints {
  /// `.channel-scene { background: rgba(255,250,251,.4) }`（group.css 756）。
  static const Color rowBase = Color(0x66FFFAFB);

  /// `rgba(157,191,230,.18)`（hover）。
  static const Color hover = Color(0x2E9DBFE6);

  /// 浮层钮 hover 底 `rgba(157,191,230,.3)`（group.css 853 等）。
  static const Color overlayHover = Color(0x4D9DBFE6);

  /// 「展开更多」按钮底 `rgba(255,250,251,.5)`（group.css 1111 等）。
  static const Color moreButtonBg = Color(0x80FFFAFB);
}

/// **同色相的零透明**（alpha = 0，色相与 [_SidebarTints.hover] 一致）。
///
/// ⚠️ 颜色过渡的「零值」**不能**写 `Colors.transparent`：那是 `0x00000000`（**透明黑**），
/// 从 `.18 冰蓝` 插值到它会**经过中性灰** —— 视觉上就是那层「很脏的灰」
/// （库内同款教训见 `menu_item.dart` / `profile_and_filters.dart` 的注释）。
/// 用同色相透明则插值全程保持冰蓝色相，不会闪灰。
abstract final class _SidebarZeroTint {
  /// 与 [_SidebarTints.hover] 同色相的 alpha 0。
  static const Color hover = Color(0x009DBFE6);
}

// ======================= 数据模型 =======================

/// 群内场景（`stores/group.ts` 的 `GroupScene`；tsx 39–45 的顺序）。
enum AylaGroupScene {
  /// 聊天（含子群下拉）。
  chat,

  /// 语音（含语音房下拉）。
  voice,

  /// 直播（含直播间下拉）。
  live,

  /// 帖子（锁定置底）。
  posts,

  /// 桌游（锁定置底）。
  games,
}

/// 子群（`api/types.ts` 416–431 `SubGroup` 的侧栏投影）。
@immutable
class AylaChannelSubgroup {
  const AylaChannelSubgroup({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.muted = false,
    this.unreadCount = 0,
    this.lastMessageSeq = 0,
  });

  /// 子群 id（`SubGroup.id`）。
  final String id;

  /// 名称。
  final String name;

  /// 默认组（固定排第一，tsx 427 / stores/subgroup.ts 21）。
  final bool isDefault;

  /// 禁言开关（`muted === true` 才渲染标签，tsx 437）。
  final bool muted;

  /// 本人未读数（tsx 438：>0 渲染徽标，>99 显示 `99+`）。
  final int unreadCount;

  /// 最近消息序号（`last_message_seq`，排序用）。
  final int lastMessageSeq;
}

/// 语音房（`api/types.ts` 863 `VoiceChannelDescriptor` 的侧栏投影）。
@immutable
class AylaChannelVoiceRoom {
  const AylaChannelVoiceRoom({
    required this.id,
    required this.name,
    this.memberCount = 0,
  });

  /// 频道 id。
  final String id;

  /// 名称。
  final String name;

  /// 在麦人数（tsx 320：>0 才渲染 `channel-voice-room-count`）。
  final int memberCount;
}

/// 直播间（`api/types.ts` 1035 `LiveChannelDescriptor` 的侧栏投影）。
@immutable
class AylaChannelLiveRoom {
  const AylaChannelLiveRoom({
    required this.id,
    required this.title,
    this.cover,
    this.isLive = false,
  });

  /// 直播间 id。
  final int id;

  /// 标题（`channel-live-room-title`，两行 clamp）。
  final String title;

  /// 封面 URL（空 = 纯图标占位，tsx 375）。
  final String? cover;

  /// `status === "live"`（右上角粉点 + 场景项 LIVE 文本）。
  final bool isLive;
}

/// 目录分页三态（`useDirectoryPage` / `useSocialPage` 的返回值投影）。
///
/// 组件**不取数**：数据与分页状态由页面层传入（与 `AylaServerRail` 同做法）。
@immutable
class AylaChannelDirectory {
  const AylaChannelDirectory({
    this.total = 0,
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.invalidated = false,
    required this.loadMore,
    required this.refresh,
  });

  /// 服务端总数（「展开更多（N）」的 N 用 `max(本地条数, total)`，tsx 328）。
  final int total;

  /// 是否加载中。
  final bool loading;

  /// 错误文案（非 null 时 `AylaDirectoryLoadMore` 不渲染）。
  final String? error;

  /// 是否还有更多。
  final bool hasMore;

  /// 加载中数据被更新（自动 refresh）。
  final bool invalidated;

  /// 加载更多。
  final Future<void> Function() loadMore;

  /// 重新拉取。
  final Future<void> Function() refresh;

  static Future<void> _noop() async {}

  /// 无目录接线时的空实现（分页三态全空）。
  static const AylaChannelDirectory none = AylaChannelDirectory(
    loadMore: _noop,
    refresh: _noop,
  );
}

/// `stores/subgroup.ts` 19–23 的排序投影：默认组固定第一，其余按最近消息降序，
/// **并列保持列表原序**。
///
/// ⚠️ Dart 的 `List.sort` **不稳定**（web 的 `Array.sort` 稳定）→ 必须显式带原索引
/// 做二级比较，否则并列项顺序漂移（`13-*` §6.12）。
List<AylaChannelSubgroup> sortSubgroupsByActivity(
  List<AylaChannelSubgroup> list,
) {
  final List<int> order = List<int>.generate(list.length, (int i) => i)
    ..sort((int a, int b) {
      final AylaChannelSubgroup x = list[a];
      final AylaChannelSubgroup y = list[b];
      // is_default 降序 → last_message_seq 降序 → 原索引升序（并列保持原序）
      final int byDefault = (y.isDefault ? 1 : 0) - (x.isDefault ? 1 : 0);
      if (byDefault != 0) return byDefault;
      final int bySeq = y.lastMessageSeq - x.lastMessageSeq;
      if (bySeq != 0) return bySeq;
      return a - b;
    });
  return <AylaChannelSubgroup>[for (final int i in order) list[i]];
}

// ======================= 主组件 =======================

/// 宽屏频道侧栏（`ChannelSidebar.tsx`）。
///
/// 外层负责**切群编排**：`AnimatePresence mode="wait"`（tsx 74–76）——
/// 旧面板先退场（−20px / opacity 0，300ms easeInOut）再挂新面板（左入 20 / 300ms）。
class AylaChannelSidebar extends StatefulWidget {
  const AylaChannelSidebar({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.activeScene,
    this.onSelectScene,
    this.onOpenInfo,
    this.subgroups = const <AylaChannelSubgroup>[],
    this.activeSubgroupId,
    this.onSelectSubgroup,
    this.subgroupDirectory = AylaChannelDirectory.none,
    this.canManageSubgroups = false,
    this.voiceRooms = const <AylaChannelVoiceRoom>[],
    this.activeVoiceChannelId,
    this.onSelectVoiceChannel,
    this.voiceMemberCount = 0,
    this.voiceDirectory = AylaChannelDirectory.none,
    this.liveRooms = const <AylaChannelLiveRoom>[],
    this.activeLiveChannelId,
    this.onSelectLiveChannel,
    this.liveDirectory = AylaChannelDirectory.none,
    this.postUnread = 0,
    this.animateEntrance = true,
    this.playing = true,
    this.previewEditing = false,
    this.previewExpanded = false,
  });

  /// 当前群 id（`key={groupId}` 驱动面板重挂与切群编排，tsx 71–76）。
  final String? groupId;

  /// 群名（`channel-sidebar-title`）。
  final String groupName;

  /// 当前场景（选中项）。
  final AylaGroupScene activeScene;

  /// 点场景项。
  final ValueChanged<AylaGroupScene>? onSelectScene;

  /// 点群名头（进群信息，tsx 527）。
  final VoidCallback? onOpenInfo;

  /// 子群列表（组件内部按 [sortSubgroupsByActivity] 排序，tsx 137）。
  final List<AylaChannelSubgroup> subgroups;

  /// 当前选中子群 id（`activeByGroup[groupId]`）。
  final String? activeSubgroupId;

  /// 点子群行。
  final ValueChanged<String>? onSelectSubgroup;

  /// 子群目录（`useSocialPage("subgroups")`）。
  final AylaChannelDirectory subgroupDirectory;

  /// `my_role` 是 owner/admin（tsx 142：`canManage` 才渲染编辑笔与 ＋）。
  final bool canManageSubgroups;

  /// 语音房列表（`useDirectoryPage("voice")`）。
  final List<AylaChannelVoiceRoom> voiceRooms;

  /// 当前语音房 id（高亮用）。
  final String? activeVoiceChannelId;

  /// 点语音房行（tsx 315：同时 `onSelectScene("voice")`）。
  final ValueChanged<String>? onSelectVoiceChannel;

  /// 群内在麦总人数（`totalMemberCount`，tsx 127：>0 才渲染状态文本）。
  final int voiceMemberCount;

  /// 语音目录。
  final AylaChannelDirectory voiceDirectory;

  /// 直播间列表。
  final List<AylaChannelLiveRoom> liveRooms;

  /// 当前直播间 id（高亮用）。
  final String? activeLiveChannelId;

  /// 点直播间行。
  final ValueChanged<int>? onSelectLiveChannel;

  /// 直播目录。
  final AylaChannelDirectory liveDirectory;

  /// 群内未读帖子数（`post_unread_count`，tsx 131：帖子项粉徽标）。
  final int postUnread;

  /// 是否播放入场动画（`panelVariants(reduced,"left")`）。
  final bool animateEntrance;

  /// 面板是否在场（false = 退场中 → `inert`：禁指针 + 排除语义，tsx 85–97）。
  final bool playing;

  /// **只用于预览/画布样张**：初始进入子群编辑态（样张里无法点击笔）。
  final bool previewEditing;

  /// **只用于预览/画布样张**：初始展开三个下拉的「展开更多」。
  final bool previewExpanded;

  @override
  State<AylaChannelSidebar> createState() => _AylaChannelSidebarState();
}

class _AylaChannelSidebarState extends State<AylaChannelSidebar>
    with SingleTickerProviderStateMixin {
  /// 当前**已挂载**的面板数据（退场期间保持旧群内容，等价 framer 对 exiting
  /// 元素保留原 props 的语义）。
  late _PanelData _data = _PanelData.of(widget);

  /// 待切入的群 id（退场结束后才挂载）。
  String? _pending;

  /// 退场进度（0 = 正常；1 = 完全退出）。`mode="wait"` 用它串行化。
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: AylaDurations.auroraqua, // 300ms
  );

  @override
  void initState() {
    super.initState();
    _exit.addStatusListener(_onExitStatus);
  }

  @override
  void didUpdateWidget(covariant AylaChannelSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupId != oldWidget.groupId) {
      // 切群：旧面板退场（tsx 74–76 `AnimatePresence mode="wait"`）。
      _pending = widget.groupId;
      if (_reduceMotion) {
        _data = _PanelData.of(widget);
        _pending = null;
        _exit.value = 0;
      } else {
        _exit.forward(from: 0);
      }
    } else if (_pending == null) {
      // 同群内数据刷新：直接同步（同一 key 不重挂状态）。
      _data = _PanelData.of(widget);
    }
  }

  void _onExitStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _pending == null) return;
    setState(() {
      _data = _PanelData.of(widget);
      _pending = null;
      _exit.value = 0; // 新面板入场由 AylaRevealItem 负责
    });
  }

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void dispose() {
    _exit.removeStatusListener(_onExitStatus);
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 退场：panelVariants(reduced,"left").exit = x −20 / opacity 0（300ms easeInOut）。
    final Widget panel = AnimatedBuilder(
      animation: _exit,
      builder: (BuildContext context, Widget? child) {
        final double t = AylaCurves.auroraquaEaseInOut.transform(_exit.value);
        final bool inactive = t > 0 || !widget.playing;
        return Transform.translate(
          offset: Offset(-20 * t, 0),
          child: Opacity(
            opacity: 1 - t,
            child: IgnorePointer(
              ignoring: inactive,
              child: ExcludeSemantics(excluding: inactive, child: child),
            ),
          ),
        );
      },
      child: AylaRevealItem(
        // 入场：auroraqua-sidebar-in（−20px 0 → 0,0）；≥769px 由 JS 编排
        // （auroraqua 310–313 关掉 CSS 入场）→ 用 panelVariants 的 300ms easeInOut。
        enabled: widget.animateEntrance && !_reduceMotion,
        offset: const Offset(-20, 0),
        duration: AylaDurations.auroraqua,
        curve: AylaCurves.auroraquaEaseInOut,
        // key = groupId：切群重挂面板状态（等价 React `key={groupId}`）。
        child: _ChannelSidebarPanel(
          key: ValueKey<String?>(_data.groupId),
          data: _data,
          activeScene: widget.activeScene,
          onSelectScene: widget.onSelectScene,
          onOpenInfo: widget.onOpenInfo,
          onSelectSubgroup: widget.onSelectSubgroup,
          onSelectVoiceChannel: widget.onSelectVoiceChannel,
          onSelectLiveChannel: widget.onSelectLiveChannel,
          playing: widget.playing && _pending == null,
          previewEditing: widget.previewEditing,
          previewExpanded: widget.previewExpanded,
        ),
      ),
    );

    // `.channel-sidebar-slot { width: calc(260px + 2 * 12) }`（group.css 684）。
    return SizedBox(width: _SidebarMetrics.slotWidth, child: panel);
  }
}

/// 面板渲染数据快照（退场期间冻结旧群内容用）。
@immutable
class _PanelData {
  const _PanelData({
    required this.groupId,
    required this.groupName,
    required this.subgroups,
    required this.activeSubgroupId,
    required this.subgroupDirectory,
    required this.canManageSubgroups,
    required this.voiceRooms,
    required this.activeVoiceChannelId,
    required this.voiceMemberCount,
    required this.voiceDirectory,
    required this.liveRooms,
    required this.activeLiveChannelId,
    required this.liveDirectory,
    required this.postUnread,
  });

  factory _PanelData.of(AylaChannelSidebar w) => _PanelData(
    groupId: w.groupId,
    groupName: w.groupName,
    subgroups: w.subgroups,
    activeSubgroupId: w.activeSubgroupId,
    subgroupDirectory: w.subgroupDirectory,
    canManageSubgroups: w.canManageSubgroups,
    voiceRooms: w.voiceRooms,
    activeVoiceChannelId: w.activeVoiceChannelId,
    voiceMemberCount: w.voiceMemberCount,
    voiceDirectory: w.voiceDirectory,
    liveRooms: w.liveRooms,
    activeLiveChannelId: w.activeLiveChannelId,
    liveDirectory: w.liveDirectory,
    postUnread: w.postUnread,
  );

  final String? groupId;
  final String groupName;
  final List<AylaChannelSubgroup> subgroups;
  final String? activeSubgroupId;
  final AylaChannelDirectory subgroupDirectory;
  final bool canManageSubgroups;
  final List<AylaChannelVoiceRoom> voiceRooms;
  final String? activeVoiceChannelId;
  final int voiceMemberCount;
  final AylaChannelDirectory voiceDirectory;
  final List<AylaChannelLiveRoom> liveRooms;
  final String? activeLiveChannelId;
  final AylaChannelDirectory liveDirectory;
  final int postUnread;

  /// 场景项展示顺序（tsx 39–45）。
  static const List<({AylaGroupScene scene, String label, String icon})>
  scenes = <({AylaGroupScene scene, String label, String icon})>[
    (scene: AylaGroupScene.chat, label: '聊天', icon: 'iconChat'),
    (scene: AylaGroupScene.voice, label: '语音', icon: 'iconMic'),
    (scene: AylaGroupScene.live, label: '直播', icon: 'iconVideo'),
    (scene: AylaGroupScene.posts, label: '帖子', icon: 'iconPost'),
    (scene: AylaGroupScene.games, label: '桌游', icon: 'iconGame'),
  ];
}

/// 选中项身份（驱动共享胶囊的迁移与尺寸）。
@immutable
class _Selection {
  const _Selection(this.kind, this.id);

  /// 组：scene / subgroup / voice / live。
  final String kind;

  /// 组内 id（场景项用 `scene.name`）。
  final String id;

  @override
  bool operator ==(Object other) =>
      other is _Selection && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

// ======================= 面板（含全部交互状态） =======================

class _ChannelSidebarPanel extends StatefulWidget {
  const _ChannelSidebarPanel({
    super.key,
    required this.data,
    required this.activeScene,
    required this.playing,
    this.previewEditing = false,
    this.previewExpanded = false,
    this.onSelectScene,
    this.onOpenInfo,
    this.onSelectSubgroup,
    this.onSelectVoiceChannel,
    this.onSelectLiveChannel,
  });

  final _PanelData data;
  final AylaGroupScene activeScene;
  final bool playing;
  final bool previewEditing;
  final bool previewExpanded;
  final ValueChanged<AylaGroupScene>? onSelectScene;
  final VoidCallback? onOpenInfo;
  final ValueChanged<String>? onSelectSubgroup;
  final ValueChanged<String>? onSelectVoiceChannel;
  final ValueChanged<int>? onSelectLiveChannel;

  @override
  State<_ChannelSidebarPanel> createState() => _ChannelSidebarPanelState();
}

class _ChannelSidebarPanelState extends State<_ChannelSidebarPanel>
    with SingleTickerProviderStateMixin {
  // ---- 几何 key（全部实测，禁推算） ----

  /// 卡片内容层（`GlassSurface` 的 child）——所有 `localToGlobal` 的共同祖先。
  final GlobalKey _cardKey = GlobalKey();

  /// 列表视口（`.channel-sidebar-list`，滚动区）。
  final GlobalKey _viewportKey = GlobalKey();

  /// 主列三个行占位（`.channel-scene-row` 的自然流位置）。
  final Map<AylaGroupScene, GlobalKey> _slotKeys = <AylaGroupScene, GlobalKey>{
    AylaGroupScene.chat: GlobalKey(),
    AylaGroupScene.voice: GlobalKey(),
    AylaGroupScene.live: GlobalKey(),
  };

  /// 所有可被选中的按钮（胶囊目标 rect 用）。
  final Map<_Selection, GlobalKey> _buttonKeys = <_Selection, GlobalKey>{};

  /// 主列三行的浮层（paint 定位）。
  final Map<AylaGroupScene, GlobalKey> _rowLayerKeys =
      <AylaGroupScene, GlobalKey>{
        AylaGroupScene.chat: GlobalKey(),
        AylaGroupScene.voice: GlobalKey(),
        AylaGroupScene.live: GlobalKey(),
      };

  /// 三个下拉容器（paint 动态裁剪）。
  final Map<AylaGroupScene, GlobalKey> _dropdownKeys =
      <AylaGroupScene, GlobalKey>{
        AylaGroupScene.chat: GlobalKey(),
        AylaGroupScene.voice: GlobalKey(),
        AylaGroupScene.live: GlobalKey(),
      };

  /// 共享胶囊的**组**：web 里是三个互相独立的 `layoutId`
  /// （`selectionId-scene` / `-subgroup` / `-live`）——**它们可以同时存在**。
  ///
  /// ⚠️ 语音房行**不在**其中：web 给该行传 `sharedLayout={false}`（tsx 316–318，
  /// 行有自己的排序位移）→ 行内独立胶囊（[_voiceHighlightKeys]）。
  static const List<String> _capsuleKinds = <String>[
    'scene',
    'subgroup',
    'live',
  ];

  /// 各组共享胶囊（容器级**每组一个**；组内跨项迁移）——**照范本**
  /// `AylaDirectoryFilters`（`widgets/profile_and_filters.dart` 405–424 + 555–587）：
  /// 位置 = `GlobalKey` 实测选中项按钮矩形 + `AnimatedPositioned`（300ms），
  /// 按压 `.98` 由容器级 `AnimatedScale` 同步（胶囊不在按钮内，拿不到 `:active`）。
  ///
  /// 此前做成「全组件单实例」是错的：选「聊天」时该实例被**子群**占用 →
  /// 父级（场景组）永远没有胶囊，子项收起时旧矩形还被误用（用户 2026-09-21 实报
  /// 「父级选项卡没有，二级选项卡还窜到父级去了」）。
  final Map<String, GlobalKey<AylaNavHighlightState>> _highlightKeys =
      <String, GlobalKey<AylaNavHighlightState>>{
        for (final String k in <String>['scene', 'subgroup', 'live'])
          k: GlobalKey<AylaNavHighlightState>(),
      };

  /// 各组选中项按钮的**实测矩形**（相对卡片 Stack）——胶囊按它定位与定尺寸。
  final Map<String, Rect?> _capsuleRects = <String, Rect?>{};

  /// 首帧 element 未就绪时的测量重试计数（自愈，避免永久不画）。
  int _measureRetries = 0;

  /// 语音房行的**行内独立**胶囊（web `sharedLayout={false}`，tsx 316–318）。
  final Map<String, GlobalKey<AylaNavHighlightState>> _voiceHighlightKeys =
      <String, GlobalKey<AylaNavHighlightState>>{};

  final ScrollController _scroll = ScrollController();

  /// 追踪窗口（`13-*` §6.10）：动画期间每帧 `markNeedsPaint` 各浮层。
  late final Ticker _tracker = createTicker(_onTick);
  int _remaining = 0;

  // ---- 交互状态（tsx 144–184） ----
  bool _subgroupsOpen = true;
  bool _subgroupsExpanded = false;
  bool _editing = false;
  bool _voiceOpen = true;
  bool _voiceExpanded = false;
  bool _liveOpen = true;
  bool _liveExpanded = false;

  /// 行级 hover（含行内浮层钮）→ **只驱动底色**（group.css 878–881 等）。
  _Selection? _hoveredRow;

  /// 按钮级 hover → 驱动底色**与扫光**（auroraqua 163）。
  _Selection? _hoveredButton;

  /// **单个浮层钮**的 hover 身份（`＋` / 笔 / 三角各自独立）。
  ///
  /// web 里每个钮有自己的 `:hover`（`.channel-scene-voice-add:hover` 852、
  /// `.channel-scene-voice-toggle:hover` 883）；而 `_hoveredRow` 是**行级**、
  /// 任一钮 hover 都要联动词条底色（878–881）⇒ 两者必须分开，否则同行的
  /// 两个钮会一起亮（用户 2026-09-21 实报）。
  _Selection? _hoveredOverlay;

  /// 按压中的行（导航组 `:active { scale: .98 }`，auroraqua 245–249）。
  _Selection? _pressed;

  @override
  void initState() {
    super.initState();
    // 预览/画布样张的初始态（样张不可交互，只能由参数给初值）。
    _editing = widget.previewEditing;
    _subgroupsExpanded = widget.previewExpanded;
    _voiceExpanded = widget.previewExpanded;
    _liveExpanded = widget.previewExpanded;
    _scroll.addListener(_markLayersDirty);
    // 首帧 layout 完成后补一次重绘：浮层几何依赖**同帧 layout 结果**，
    // 而首帧 paint 可能早于兄弟子树 layout（此时读到 null → 不裁剪/不定位）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _markLayersDirty();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_markLayersDirty);
    _scroll.dispose();
    _tracker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) => _markLayersDirty();

  /// 打开 30 帧追踪窗口（≈300ms，覆盖展开/收起等隐式动画）。
  void _startTracking({int frames = 30}) {
    _tracker.stop();
    _remaining = frames;
    _tracker.start();
  }

  /// 浮层（行 / 下拉裁剪 / 胶囊）的位置取决于**外部**（占位、滚动、展开动画）
  /// → 滚动与追踪窗口里主动让它们重绘（paint 阶段重算几何）。
  void _markLayersDirty() {
    for (final GlobalKey k in <GlobalKey>[
      ..._rowLayerKeys.values,
      ..._dropdownKeys.values,
    ]) {
      k.currentContext?.findRenderObject()?.markNeedsPaint();
    }
    // 胶囊几何也要跟着滚动/动画重测（范本同样每帧排队测量）
    _measureCapsule();
    if (_remaining > 0) {
      _remaining -= 1;
      if (_remaining == 0) _tracker.stop();
    }
  }

  // ---- 几何辅助 ----

  RenderBox? get _cardBox => _renderObjectOf(_cardKey) as RenderBox?;

  RenderBox? get _viewportBox => _renderObjectOf(_viewportKey) as RenderBox?;

  /// 安全取 RenderObject：GlobalKey 指向的行可能刚被移除（折叠/收起）→
  /// element 处于 inactive/DEFUNCT，`findRenderObject()` 会抛错。
  RenderObject? _renderObjectOf(GlobalKey key) {
    final BuildContext? ctx = key.currentContext;
    if (ctx == null) return null;
    // ⚠️ 折叠/收起会移除下拉里的行 → 该 GlobalKey 的 element 变 inactive/DEFUNCT，
    // `findRenderObject()` 会抛 'Cannot get renderObject of inactive element'
    // （实测：收起子群时胶囊层 paint 崩）。失活即视为「该行当前不存在」。
    if (ctx is Element && !ctx.mounted) return null;
    try {
      return ctx.findRenderObject();
    } catch (_) {
      return null;
    }
  }

  Rect? _rectInCard(GlobalKey key) => _rectIn(_cardKey, key);

  /// 相对任意祖先（RenderBox）求 rect。
  Rect? _rectIn(GlobalKey ancestorKey, GlobalKey key) {
    final RenderObject? anc = _renderObjectOf(ancestorKey);
    final RenderObject? ro = _renderObjectOf(key);
    if (anc is! RenderBox || ro is! RenderBox || !ro.hasSize) return null;
    return ro.localToGlobal(Offset.zero, ancestor: anc) & ro.size;
  }

  /// 各组胶囊的测量基准：**统一用卡片 Stack**（三组胶囊都画在卡片级 Stack 里；
  /// 子群/直播间那两组额外套一层与各自下拉**同参数的裁剪**，见卡片级渲染 ——
  /// 这样它们既与行同坐标系，又继承下拉裁剪，不会超出视口。
  Rect? _rectOfGroup(String kind, GlobalKey key) => _rectInCard(key);

  /// 主列场景行的**吸附后**顶部（卡片坐标系）。
  ///
  /// CSS `position: sticky; top: T; bottom: B` 的等价：
  /// `y = max(viewportTop + T, min(follow, viewportBottom − 40 − B))`
  /// —— **top 优先**（`13-*` §6.8 第 2 条：写成 `min(max(...))` 在视口不足时会越过 top）。
  double? _stickyRowTop(AylaGroupScene scene) {
    final Rect? slot = _rectInCard(_slotKeys[scene]!);
    final RenderBox? viewport = _viewportBox;
    final RenderBox? card = _cardBox;
    if (slot == null || viewport == null || card == null) return null;
    final Offset vp = viewport.localToGlobal(Offset.zero, ancestor: card);
    final double vpTop = vp.dy;
    final double vpBottom = vpTop + viewport.size.height;
    final double follow = slot.top;
    final double top = vpTop + _stickyTopOf(scene);
    final double? bottom = _stickyBottomOf(scene);
    final double y = bottom == null
        ? follow
        : math.min(follow, vpBottom - _SidebarMetrics.rowHeight - bottom);
    return math.max(y, top);
  }

  double _stickyTopOf(AylaGroupScene scene) => switch (scene) {
    AylaGroupScene.chat => _SidebarMetrics.stickyChatTop,
    AylaGroupScene.voice => _SidebarMetrics.stickyVoiceTop,
    AylaGroupScene.live => _SidebarMetrics.stickyLiveTop,
    _ => 0,
  };

  double? _stickyBottomOf(AylaGroupScene scene) => switch (scene) {
    AylaGroupScene.voice => _SidebarMetrics.stickyVoiceBottom,
    AylaGroupScene.live => _SidebarMetrics.stickyLiveBottom,
    _ => null,
  };

  /// 列表内容轨道左缘（卡片坐标系）：列表 padding 8。
  double get _trackLeft => _SidebarMetrics.listPaddingH;

  /// 某组当前的选中项（**每组各自一个**共享胶囊）。
  ///
  /// - `scene`：**总是有**（五个场景项之一）—— 与 web 一致，父级选项卡在任何场景下
  ///   都有自己的胶囊；
  /// - `subgroup` / `live`：只有当前场景与组匹配、且该组有选中项时才存在
  ///   （否则该组不画胶囊）；
  /// - `voice`：不在共享组内（行内独立，见 [_voiceHighlightKeys]）。
  _Selection? _selectionOf(String kind) => switch (kind) {
    'scene' => _Selection('scene', widget.activeScene.name),
    'subgroup' =>
      widget.activeScene == AylaGroupScene.chat &&
              widget.data.activeSubgroupId != null
          ? _Selection('subgroup', widget.data.activeSubgroupId!)
          : null,
    'live' =>
      widget.activeScene == AylaGroupScene.live &&
              widget.data.activeLiveChannelId != null
          ? _Selection('live', widget.data.activeLiveChannelId!)
          : null,
    _ => null,
  };

  /// 单组胶囊（位置 = 该组选中项按钮的实测矩形，坐标系 = 该胶囊**所在层**）。
  ///
  /// - scene：画在**卡片级** Stack（在内容之下 = web 的 z-index:-1）；
  /// - subgroup / live：画在**各自下拉的 Stack 内** → 继承下拉裁剪（web 的胶囊
  ///   是按钮子元素，同样被 .channel-subgroups 的 overflow:hidden 裁住）。
  Widget? _capsuleFor(String kind) {
    final Rect? rect = _capsuleRects[kind];
    if (rect == null) return null;
    final _Selection? sel = _selectionOf(kind);
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedPositioned(
      duration: reduce ? Duration.zero : AylaDurations.auroraqua,
      curve: AylaCurves.auroraquaEaseOut,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: AnimatedScale(
        duration: reduce ? Duration.zero : AylaDurations.button,
        curve: AylaCurves.auroraqua,
        scale: _pressed != null && _pressed == sel ? 0.98 : 1.0,
        // **不加入场动画**（照 web `AuroraquaNavHighlight.tsx`：`initial={false}`
        // → 胶囊挂载时直接到位）。组内跨项迁移由外层 `AnimatedPositioned` 的 300ms
        // 负责，与 Framer 的 `layoutId` 迁移一一对应 ⇒ 三组行为天然**统一**。
        child: AylaNavHighlight(
          key: _highlightKeys[kind],
          // web：只有**按钮本体**命中才扫光（.has-auroraqua-highlight:hover）；
          // 行级 :has() 只驱动底色 ⇒ 两套 hover 必须分开。
          sweep: true,
          sweepActive: _hoveredButton != null && _hoveredButton == sel,
        ),
      ),
    );
  }

  /// 布局后测量「选中项按钮」矩形（胶囊按它定位与定尺寸）。
  ///
  /// **照范本** `AylaDirectoryFilters._measureCapsule`（405–424）：每次 build 都排一次
  /// 测量（字体加载、滚动、展开动画都会改变几何）；滚动与 disclosure 动画期间由
  /// 追踪窗口（[Ticker]）每帧再排一次 —— 否则几何会停在旧值（`13-*` §6.10）。
  ///
  /// 语音房行的胶囊由该行**自己**持有（web `sharedLayout={false}`，tsx 316–318）
  /// → 不进共享胶囊，测量结果为 null。
  void _measureCapsule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      bool changed = false;
      bool pending = false;
      for (final String kind in _capsuleKinds) {
        final _Selection? sel = _selectionOf(kind);
        final GlobalKey? key = sel == null ? null : _buttonKeys[sel];
        final Rect? next = key == null ? null : _rectOfGroup(kind, key);
        // 有选中项却测不到 rect（首帧 element 未就绪）→ 待重试
        if (next == null && key != null) pending = true;
        if (_capsuleRects[kind] != next) {
          _capsuleRects[kind] = next;
          changed = true;
        }
      }
      if (pending && _measureRetries < 3) {
        _measureRetries += 1;
        _measureCapsule();
        return;
      }
      if (!pending) _measureRetries = 0;
      if (changed) setState(() {});
    });
  }

  GlobalKey _keyFor(_Selection s) =>
      _buttonKeys.putIfAbsent(s, () => GlobalKey());

  // ---- hover / 按压 ----

  void _setHovered({_Selection? row, _Selection? button}) {
    if (row == _hoveredRow && button == _hoveredButton) return;
    setState(() {
      _hoveredRow = row;
      _hoveredButton = button;
    });
  }

  /// **只**改行级 hover（底色）—— 行容器用。
  ///
  /// 与按钮级分开是必须的：web 里
  /// `.channel-scene-row:has(.channel-scene-*-toggle:hover) .channel-scene { background: .18 }`
  /// （group.css 878–881）让「浮层钮 hover」也联动词条底色；而扫光只看**按钮本体**
  /// （auroraqua 163）。若行与按钮共用一次 `_setHovered(row:…, button:…)`，
  /// 指针在浮层钮上时会把 button 也点亮 → 扫光误触发。
  void _setHoveredRow(_Selection? s) {
    if (s == _hoveredRow) return;
    setState(() => _hoveredRow = s);
  }

  /// **只**改按钮级 hover（扫光 + 按钮底色）。
  void _setHoveredButton(_Selection? s) {
    if (s == _hoveredButton) return;
    setState(() => _hoveredButton = s);
  }

  /// **只**改浮层钮自身的 hover（不影响行底；行底由 [_setHoveredRow] 管）。
  void _setHoveredOverlay(_Selection? s) {
    if (s == _hoveredOverlay) return;
    setState(() => _hoveredOverlay = s);
  }

  void _setPressed(_Selection? s) {
    if (s == _pressed) return;
    setState(() => _pressed = s);
  }

  /// 「挂载即命中」：点击选中后让该组胶囊**立即停在扫光终点**
  /// （web 上该帧的 computed style 已是 `translateX(120%)`，不存在 transition；
  /// 之后指针移开才跑出完整的一次从右往左扫）。
  ///
  /// ⚠️ 必须排到**下一帧**：点击回调执行时选中态刚变、胶囊可能尚未挂载
  /// （`if (active)` 分支），此刻 `currentState` 是 null，直接调用会打在空气上 ——
  /// 那样就只能等 `sweepActive` 变 true 触发 `forward()`，于是**从左往右重播一次**
  /// 才反向（用户 2026-09-21 实报：底部两项「过一会才从左往右扫」）。
  void _jumpSweep(String kind) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _highlightKeys[kind]?.currentState?.setSweep(true, jump: true);
    });
  }

  // ---- 点击场景项：滚到该行自身的吸顶位（tsx 161–172） ----

  Future<void> _scrollSceneRowToPin(AylaGroupScene scene) async {
    if (!_scroll.hasClients) return;
    final Rect? slot = _rectInCard(_slotKeys[scene]!);
    final RenderBox? viewport = _viewportBox;
    final RenderBox? card = _cardBox;
    if (slot == null || viewport == null || card == null) return;
    final Offset vp = viewport.localToGlobal(Offset.zero, ancestor: card);
    // web：临时取消 sticky 量真实文档流位置，再 `scrollTo({ top: flowTop − pinTop })`。
    // Flutter 侧占位就在流里 → 流位置 = 当前视口位置 + 已滚动量。
    final double flow = slot.top + _scroll.offset - vp.dy;
    final double target = (flow - _stickyTopOf(scene)).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: AylaDurations.auroraqua, // scrollTo({ behavior: "smooth" })
      curve: AylaCurves.auroraquaEaseOut,
    );
  }

  // ======================= build =======================

  static const List<AylaGroupScene> _rowScenes = <AylaGroupScene>[
    AylaGroupScene.chat,
    AylaGroupScene.voice,
    AylaGroupScene.live,
  ];

  @override
  Widget build(BuildContext context) {
    final _PanelData d = widget.data;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration disclosure = reduceMotion
        ? Duration.zero
        : AylaDurations.auroraqua;

    // 每次 build 都排一次胶囊测量（范本 `AylaDirectoryFilters` 497 行同做法）：
    // 字体加载、滚动、展开动画、切选中项都会改变几何。
    _measureCapsule();

    return Padding(
      // `.channel-sidebar { margin: var(--sidebar-gutter) }`（group.css 700）
      padding: const EdgeInsets.all(_SidebarMetrics.gutter),
      child: GlassSurface(
        // `.channel-sidebar { background: var(--glass-bg); backdrop-filter:
        //   var(--glass-filter); box-shadow: var(--glass-shadow);
        //   border: 1px solid var(--glass-border); border-radius: 16px }`
        // （group.css 694–699）
        radius: AylaRadii.rCard,
        blur: AylaGlass.blurCard,
        shadow: AylaShadows.glass,
        // 1px 补位：CSS 的 border 占布局（内容区 258）、Flutter 的不占（§6.5）
        padding: const EdgeInsets.all(_SidebarMetrics.borderWidth),
        child: Stack(
          key: _cardKey,
          children: <Widget>[
            // 场景组胶囊（**卡片级**：5 个场景项跨中部三行与底部两行迁移）。
            // 子群 / 直播间胶囊各自画在**其下拉的 Stack 内**（继承下拉裁剪，见
            // [_capsuleFor]）—— 画在卡片级会逃出裁剪、超出视口（用户实报）。
            // 照范本 `AylaDirectoryFilters` 555–587：
            // · 位置/尺寸 = 选中项按钮的**实测矩形**；
            // · `AnimatedPositioned` 300ms `--auroraqua-ease-out` 等价 Framer `layoutId`
            //   的组内跨项迁移（同一个实体滑过去，而不是旧底消失/新底出现）；
            // · `AnimatedScale(.98, 200ms)` 同步按压（胶囊不在按钮内，拿不到按钮自身的
            //   `:active { scale: .98 }`，范本 568–578 的同一处理）。
            // ⚠️ **必须画在内容之下**（本 Stack 的第一个子）：web 的胶囊是
            // `.auroraqua-nav-highlight { z-index: -1 }`（auroraqua.css 178）——在按钮
            // 内容（图标/文字）之下、玻璃面之上。画在内容之上会让图标与文字被半透明
            // 渐变盖住（视觉发糊）。
            ?_capsuleFor('scene'),
            // 子群 / 直播间胶囊：**再套一层与各自下拉同参数的裁剪**。
            // web 里胶囊是按钮的子元素 → 被 .channel-subgroups /
            // .channel-live-rooms 的 overflow:hidden 裁住；卡片级单画会逃出裁剪
            // → 高亮块跑到视口外/别的区域（用户 2026-09-21 实报）。
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  children: <Widget>[
                    _SidebarDropdownClip(
                      cardKey: _cardKey,
                      viewportKey: _viewportKey,
                      gap: _SidebarMetrics.listGap,
                      rowTop: () => _stickyRowTop(AylaGroupScene.chat),
                      nextRowTop: () => _stickyRowTop(AylaGroupScene.voice),
                      child: Stack(children: <Widget>[?_capsuleFor('subgroup')]),
                    ),
                    _SidebarDropdownClip(
                      cardKey: _cardKey,
                      viewportKey: _viewportKey,
                      gap: _SidebarMetrics.listGap,
                      rowTop: () => _stickyRowTop(AylaGroupScene.live),
                      nextRowTop: null,
                      child: Stack(children: <Widget>[?_capsuleFor('live')]),
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Column(
                children: <Widget>[
                  _buildHead(d),
                  Expanded(child: _buildScrollList(d, disclosure)),
                  _buildBottomList(d),
                ],
              ),
            ),
            // 三行浮层（paint 定位；在内容之上 —— web 的行 `z-index: 2`）
            for (final AylaGroupScene scene in _rowScenes)
              Positioned.fill(
                child: _SidebarStickyRow(
                  key: _rowLayerKeys[scene],
                  topOf: () => _stickyRowTop(scene),
                  left: _trackLeft,
                  width: _SidebarMetrics.trackWidth,
                  height: _SidebarMetrics.rowHeight,
                  child: _buildSceneRow(scene, d, disclosure),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- 群名头（tsx 527–530；group.css 705–721） ----

  Widget _buildHead(_PanelData d) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpenInfo,
      child: Padding(
        // `.channel-sidebar-head { padding: var(--sp-4) }`（group.css 709）
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                d.groupName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis, // group.css 718–720
                style: TextStyle(
                  fontFamily: AylaFonts.display,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 20, // font-size: 20px
                  fontWeight: FontWeight.w500, // font-weight: 500
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
            // tsx 605–611 的内联 SVG（不在 icons.tsx）→ 私有 glyph
            const _SidebarGlyph(_SidebarGlyphKind.chevronRight, size: 16),
          ],
        ),
      ),
    );
  }

  // ---- 主滚动列（tsx 531–536） ----

  Widget _buildScrollList(_PanelData d, Duration disclosure) {
    // `.channel-sidebar-list { padding: 0 var(--sp-2); overflow-y: auto }`（group.css 728–729）
    // → 滚动视口宽 258 − 2×8 = 242（行/下拉的轨道宽）
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _SidebarMetrics.listPaddingH,
      ),
      child: ScrollConfiguration(
        // web base.css 372–383 全局隐藏原生滚动条（同 ServerRail 处置）
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          key: _viewportKey,
          controller: _scroll,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing:
                _SidebarMetrics.listGap, // `.channel-sidebar-list { gap: 4px }`
            children: <Widget>[
              _buildSlot(AylaGroupScene.chat),
              _buildDropdown(
                AylaGroupScene.chat,
                _buildSubgroupsDropdown(d, disclosure),
              ),
              _buildSlot(AylaGroupScene.voice),
              _buildDropdown(
                AylaGroupScene.voice,
                _buildVoiceDropdown(d, disclosure),
              ),
              _buildSlot(AylaGroupScene.live),
              _buildDropdown(
                AylaGroupScene.live,
                _buildLiveDropdown(d, disclosure),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 行占位（与行同高；行本体画在浮层 → 占位只负责自然流位置与滚动范围）。
  Widget _buildSlot(AylaGroupScene scene) =>
      SizedBox(key: _slotKeys[scene], height: _SidebarMetrics.rowHeight);

  Widget _buildDropdown(AylaGroupScene scene, Widget child) {
    return _SidebarDropdownClip(
      key: _dropdownKeys[scene],
      cardKey: _cardKey,
      viewportKey: _viewportKey,
      gap: _SidebarMetrics.listGap,
      rowTop: () => _stickyRowTop(scene),
      nextRowTop: switch (scene) {
        AylaGroupScene.chat => () => _stickyRowTop(AylaGroupScene.voice),
        AylaGroupScene.voice => () => _stickyRowTop(AylaGroupScene.live),
        _ => null,
      },
      child: child,
    );
  }

  // ---- 底部列（tsx 537–539） ----

  Widget _buildBottomList(_PanelData d) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        // `.channel-sidebar-list-bottom { border-top: 1px solid var(--glass-border) }`
        border: Border(top: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _SidebarMetrics.listPaddingH,
          _SidebarMetrics.bottomPaddingTop,
          _SidebarMetrics.listPaddingH,
          _SidebarMetrics.bottomPaddingBottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: _SidebarMetrics.listGap,
          children: <Widget>[
            _buildBottomItem(AylaGroupScene.posts, d),
            _buildBottomItem(AylaGroupScene.games, d),
          ],
        ),
      ),
    );
  }

  /// 帖子/桌游项（tsx 511–522：`li.channel-scene-item` + 选项卡按钮）。
  Widget _buildBottomItem(AylaGroupScene scene, _PanelData d) {
    final ({AylaGroupScene scene, String label, String icon}) meta = _PanelData
        .scenes
        .firstWhere(
          (({AylaGroupScene scene, String label, String icon}) m) =>
              m.scene == scene,
        );
    final int unread = scene == AylaGroupScene.posts ? d.postUnread : 0;
    return _buildSceneButton(
      scene: scene,
      meta: meta,
      active: widget.activeScene == scene,
      // tsx 517–519：帖子未读徽标（`.channel-scene-status.channel-scene-posts-badge`）
      trailing: unread > 0
          ? TabBadge(
              count: unread,
              metrics: TabBadgeMetrics.channelBadge,
              placement: TabBadgePlacement.inline,
            )
          : null,
      trailingPushedRight: unread > 0, // `margin-left: auto`（group.css 779）
      onTap: () {
        widget.onSelectScene?.call(scene);
        // 与中部三行**同款**的「挂载即命中」——此前只有 `_buildSceneRow` 里有，
        // 底部两项漏掉 ⇒ 点击后扫光会从左往右重播一次才反向（用户实报的差异）。
        _jumpSweep('scene');
      },
    );
  }

  // ======================= 场景行（选项卡按钮 + 浮层钮） =======================

  /// 主列场景行（tsx 264–464）：按钮 + 可选 ＋/笔 + 三角展开键。
  Widget _buildSceneRow(
    AylaGroupScene scene,
    _PanelData d,
    Duration disclosure,
  ) {
    final ({AylaGroupScene scene, String label, String icon}) meta = _PanelData
        .scenes
        .firstWhere(
          (({AylaGroupScene scene, String label, String icon}) m) =>
              m.scene == scene,
        );
    final bool active = widget.activeScene == scene;
    final bool open = switch (scene) {
      AylaGroupScene.chat => _subgroupsOpen,
      AylaGroupScene.voice => _voiceOpen,
      _ => _liveOpen,
    };

    // 状态标识（tsx 271 / 346）：web 里 `.channel-scene-status` **零样式**
    // → 语音在麦人数与 LIVE 都是**继承父级样式的裸文本**（15px/600/secondary），
    // 紧跟标签右侧 12px（无 margin-left:auto）。
    final String? statusText = switch (scene) {
      AylaGroupScene.voice when d.voiceMemberCount > 0 =>
        '${d.voiceMemberCount}',
      AylaGroupScene.live
          when d.liveRooms.any((AylaChannelLiveRoom r) => r.isLive) =>
        'LIVE',
      _ => null,
    };

    final bool hasSecondary = switch (scene) {
      // tsx 456：`subgroupsOpen && canManage` 才有编辑笔
      AylaGroupScene.chat => open && d.canManageSubgroups,
      // tsx 273 / 348：展开时才渲染 ＋
      AylaGroupScene.voice || AylaGroupScene.live => open,
      // ⚠️ tsx 511–522：**帖子 / 桌游两项没有任何浮层钮**（只有按钮 + 未读徽标）。
      // 之前写成 `_ => open`，使底部两项也渲染 ＋/三角：钮会盖住按钮右端，鼠标落在
      // 右侧时命中的是「钮」（只点亮**行级** hover）→ **扫光不触发**，且 padding
      // 被撑成 76（用户 2026-09-21 实报「帖子、桌游的扫光还是有问题」）。
      _ => false,
    };

    final _Selection sel = _Selection('scene', scene.name);

    return Stack(
      children: <Widget>[
        _buildSceneButton(
          scene: scene,
          meta: meta,
          active: active,
          statusText: statusText,
          paddingRight: hasSecondary
              ? _SidebarMetrics
                    .rowPaddingRightDouble // `.channel-scene { padding-right: 76 }`
              : _SidebarMetrics.rowPaddingRight, // 40
          onTap: () {
            switch (scene) {
              case AylaGroupScene.chat:
                widget.onSelectScene?.call(scene);
                // tsx 451：点聊天同时选中默认子群
                final List<AylaChannelSubgroup> sorted = _sortedSubgroups(d);
                if (sorted.isNotEmpty) {
                  widget.onSelectSubgroup?.call(sorted.first.id);
                }
                _scrollSceneRowToPin(scene);
              case AylaGroupScene.voice:
                widget.onSelectScene?.call(scene);
                _scrollSceneRowToPin(scene);
              case AylaGroupScene.live:
                widget.onSelectScene?.call(scene);
                // 用户 2026-09-21：点直播默认选中**第一个直播间**
                // （与「点聊天自动选中默认子群」同一交互意图，tsx 451 同款）。
                if (d.liveRooms.isNotEmpty) {
                  widget.onSelectLiveChannel?.call(d.liveRooms.first.id);
                }
                _scrollSceneRowToPin(scene);
              case AylaGroupScene.posts:
              case AylaGroupScene.games:
                widget.onSelectScene?.call(scene);
            }
            // 「挂载即命中」：点击选中时胶囊迁到指针所在项，web 该帧 computed style
            // 已是 translateX(120%)、**不产生过渡** → 直达 jump（范本 544–548）。
            _jumpSweep('scene');
          },
        ),
        if (hasSecondary)
          Positioned(
            // `.channel-scene-*-add / -edit { right: 38px }`（group.css 837/895/950）
            right: _SidebarMetrics.overlayButtonSecondaryRight,
            top: 0,
            bottom: 0,
            child: Center(
              child: scene == AylaGroupScene.chat
                  ? _buildOverlayButton(
                      sel: sel,
                      slot: 'edit',
                      inButtonGroup: false, // 笔不在 auroraqua 任何一组 → 无缩放
                      activeState: _editing, // tsx 457：编辑态 is-active
                      semanticLabel: _editing ? '退出编辑' : '编辑',
                      glyph: _SidebarGlyphKind.pencil,
                      glyphSize: 14,
                      onTap: () {
                        setState(() => _editing = !_editing);
                        _startTracking();
                      },
                    )
                  : _buildOverlayButton(
                      sel: sel,
                      slot: 'add',
                      inButtonGroup: false, // ＋同上
                      semanticLabel: scene == AylaGroupScene.voice
                          ? '创建语音房'
                          : '创建直播',
                      // tsx 274 / 349：本轮不接弹窗 → 点击暂无副作用
                      onTap: () {},
                      glyph: _SidebarGlyphKind.plus,
                      glyphSize: 14,
                    ),
            ),
          ),
        Positioned(
          // `.channel-scene-*-toggle { right: 6px }`（group.css 860/918/974）
          right: _SidebarMetrics.overlayButtonRight,
          top: 0,
          bottom: 0,
          child: Center(
            child: _buildOverlayButton(
              sel: sel,
              slot: 'toggle',
              // 三个三角键在 auroraqua 按钮组内（60/78/90）→ hover 1.02 + active .98
              inButtonGroup: true,
              // `.is-open` **只旋转**（874–876）；底色/字色只有 `:hover` 才给（883–886）
              // ⇒ 常态（未 hover）时三角键必须是透明的（用户实报）
              rotated: open,
              semanticLabel: open ? '收起' : '展开',
              glyph: _SidebarGlyphKind.chevronDown,
              glyphSize: 14,
              onTap: () {
                setState(() {
                  switch (scene) {
                    case AylaGroupScene.chat:
                      _subgroupsOpen = !_subgroupsOpen;
                    case AylaGroupScene.voice:
                      _voiceOpen = !_voiceOpen;
                    default:
                      _liveOpen = !_liveOpen;
                  }
                });
                _startTracking();
              },
            ),
          ),
        ),
      ],
    );
  }

  List<AylaChannelSubgroup> _sortedSubgroups(_PanelData d) =>
      sortSubgroupsByActivity(d.subgroups);

  /// 选项卡按钮（`.channel-scene`，group.css 749–763 + auroraqua 194–197/236–249）。
  Widget _buildSceneButton({
    required AylaGroupScene scene,
    required ({AylaGroupScene scene, String label, String icon}) meta,
    required bool active,
    String? statusText,
    Widget? trailing,
    bool trailingPushedRight = false,
    required VoidCallback onTap,
    double paddingRight = _SidebarMetrics.rowPaddingRight,
  }) {
    final _Selection sel = _Selection('scene', scene.name);
    final bool hoveredButton = _hoveredButton == sel;
    final bool hoveredRow = _hoveredRow == sel;
    // `.channel-scene:hover`（765）与 `.channel-scene-row:has(...:hover) .channel-scene`
    // （878–881）都是 .18；但 auroraqua 194–197 把**选中项自身底**取消 → 选中且只
    // hover 按钮本体时底色透明（交给胶囊）。`:has()` 那条特异性更高（0,4,0 > 0,2,0）
    // → 浮层钮 hover 时即便选中也仍是 .18。
    final Color bg = active
        ? (hoveredRow ? _SidebarTints.hover : _SidebarZeroTint.hover)
        : ((hoveredButton || hoveredRow)
              ? _SidebarTints.hover
              : _SidebarTints.rowBase);
    final Color fg = active ? AylaColors.textPrimary : AylaColors.textSecondary;
    final TextStyle labelStyle = TextStyle(
      fontFamily: AylaFonts.body,
      fontFamilyFallback: AylaFonts.cjkFallback,
      fontSize: 15, // font-size: 15px
      fontWeight: FontWeight.w600, // font-weight: 600
      color: fg,
    );

    return MouseRegion(
      // 只点亮**按钮级**（扫光判定）；行级由 [_buildSceneRow] 的整行 MouseRegion 负责
      // （浮层钮 hover 也要联动词条底色 —— group.css 878–881）。
      onEnter: (_) => _setHoveredButton(sel),
      onExit: (_) => _setHoveredButton(null),
      child: AylaPressScale(
        // 导航组（auroraqua 236–249）：**只有 `:active { scale: .98 }`**，无 hover 放大
        hoverScale: false,
        pressScale: true,
        onTap: onTap,
        semanticLabel: meta.label,
        onPressChanged: (bool p) => _setPressed(p ? sel : null),
        child: AnimatedContainer(
          key: _keyFor(sel), // 胶囊目标 rect 的实测基准（= 按钮本体）
          // 导航组 transition：background/color/box-shadow 300ms `--auroraqua-ease`。
          // ⚠️ **选中态不给过渡**：web 的 \`.has-auroraqua-highlight.is-active { background:
          // transparent }\` 是瞬时的，高亮块直接出现/消失；渐隐会让半透明底色与后方
          // 胶囊、玻璃卡混色成**灰**（用户 2026-09-21 实报「出现和消失有一段灰色过渡，
          // 很拖沓很脏」）。未选中态（hover 底色）保留 300ms —— 与 web 一致。
          duration: active ? Duration.zero : AylaDurations.auroraqua,
          curve: AylaCurves.auroraqua,
          height: _SidebarMetrics.rowHeight, // height: 40px
          padding: EdgeInsets.only(
            left: AylaSpacing.sp4, // `padding: 0 var(--sp-4)`
            right: paddingRight,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius 12
            border: Border.all(
              color: AylaColors.glassBorder,
            ), // 1px --glass-border
          ),
          child: Row(
            spacing: AylaSpacing.sp3, // `gap: var(--sp-3)` = 12
            children: <Widget>[
              AylaIcon(
                aylaIconByName(meta.icon)!,
                size: 20, // tsx 269 `<Icon width={20} height={20} />`
                color: fg,
              ),
              Text(meta.label, style: labelStyle),
              // 裸文本状态（继承按钮样式：同字号/字重/颜色）
              if (statusText != null) Text(statusText, style: labelStyle),
              // 帖子未读徽标贴右（`.channel-scene-posts-badge { margin-left: auto }`）
              if (trailingPushedRight) const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }

  /// 行内浮层钮（`.channel-scene-*-add / -edit / -toggle`：28×28 / radius 12 / 透明底）。
  ///
  /// 两档按压语义**不同**（auroraqua 54–94 的 `:is()` 列表）：
  /// - 三角展开键（`.channel-scene-*-toggle`）**在组内** → hover 1.02 + active .98，200ms；
  /// - ＋ / 笔**不在任何组** → 无缩放，只有自身 `background/color 180ms`。
  Widget _buildOverlayButton({
    required _Selection sel,
    /// 该钮在行内的槽位（`edit` / `add` / `toggle`）—— 与行 id 合成**钮自己的**身份，
    /// 使同一行的多个钮 hover 互不串扰。
    required String slot,
    required bool inButtonGroup,
    required _SidebarGlyphKind glyph,
    required double glyphSize,
    required VoidCallback onTap,
    required String semanticLabel,
    /// `.is-active`（**只有编辑笔**用它）→ 底 .3 + 字 primary
    /// （group.css 852–855 / 999–1002 等）。
    bool activeState = false,

    /// `.is-open`（三角展开键）→ **只旋转，不点底色**。
    ///
    /// ⚠️ web `group.css 874–876`：`.channel-scene-voice-toggle.is-open {
    /// transform: translateY(-50%) rotate(180deg) }` —— **只有 transform**；
    /// 底色与字色**只有 `:hover` 才给**（883–886）。此前把 `is-open` 也传成
    /// `activeState` ⇒ 只要下拉是展开的，三角键就常驻亮底（用户 2026-09-21 实报
    /// 「常态时这里不高亮的」）。
    bool rotated = false,
  }) {
    // **钮自己的**身份 —— 同一行的两个钮必须分开判定（web 各有 `:hover`）
    final _Selection selfId = _Selection('overlay', '${sel.kind}:${sel.id}:$slot');
    final bool hovered = _hoveredOverlay == selfId;
    // `:hover` / `.is-active` → 底 .3 + 字 primary（group.css 852–855 / 883–886 /
    // 910–913 / 942–945 / 965–969 / 999–1002）
    final Color bg = hovered || activeState
        ? _SidebarTints.overlayHover
        : Colors.transparent;
    final Color fg = hovered || activeState
        ? AylaColors.textPrimary
        : AylaColors.textSecondary;

    final Widget face = AnimatedContainer(
      // 三角键的 transition 由**按钮组**接管（200ms，含 transform）；
      // ＋/笔 自身是 `background/color var(--dur-fast)` = 180ms。
      duration: inButtonGroup ? AylaDurations.button : AylaDurations.fast,
      curve: AylaCurves.auroraqua,
      width: _SidebarMetrics.overlayButtonSize, // 28
      height: _SidebarMetrics.overlayButtonSize,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Center(
        child: rotated
            ? AnimatedRotation(
                // `.is-open { transform: translateY(-50%) rotate(180deg) }`（874–876）
                turns: rotated ? 0.5 : 0,
                duration: AylaDurations.button,
                curve: AylaCurves.auroraqua,
                child: _SidebarGlyph(glyph, size: glyphSize, color: fg),
              )
            : _SidebarGlyph(glyph, size: glyphSize, color: fg),
      ),
    );

    return MouseRegion(
      // ① **钮自身**高亮（独立身份）② **行底**联动 —— web 878–881 里任一钮 hover
      // 都会把词条底点亮 .18；按钮级（扫光）仍只认按钮本体，故不设 button。
      onEnter: (_) {
        _setHoveredRow(sel);
        _setHoveredOverlay(selfId);
      },
      onExit: (_) {
        _setHoveredRow(null);
        _setHoveredOverlay(null);
      },
      child: inButtonGroup
          ? AylaPressScale(
              // 按钮组：hover 1.02 + active .98（auroraqua 72–94）
              hoverScale: true,
              pressScale: true,
              onTap: onTap,
              semanticLabel: semanticLabel,
              onPressChanged: (bool p) => _setPressed(p ? sel : null),
              child: face,
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Semantics(button: true, label: semanticLabel, child: face),
            ),
    );
  }

  // ======================= 子群下拉（tsx 448–508） =======================

  Widget _buildSubgroupsDropdown(_PanelData d, Duration disclosure) {
    final List<AylaChannelSubgroup> sorted = _sortedSubgroups(d);
    final int shown = math.max(sorted.length, d.subgroupDirectory.total);
    // tsx 254：`showMore = !editing && max(len, total) > 3`
    final bool showMore = !_editing && shown > 3;

    return _disclosure(
      open: _subgroupsOpen,
      duration: disclosure,
      child: _dropdownShell(
        gap: _SidebarDropdownBox.childGap,
        padding: const EdgeInsets.only(
          top: _SidebarDropdownBox.childPaddingTop,
          bottom: _SidebarDropdownBox.childPaddingBottom,
        ),
        children: <Widget>[
          // tsx 476：基础 3 条
          _childList(
            gap: _SidebarMetrics.childGap,
            children: <Widget>[
              for (final AylaChannelSubgroup sg in sorted.take(3).toList())
                _buildSubgroupRow(sg, d),
            ],
          ),
          // tsx 479–494：`editing || expanded` 时才渲染追加段（独立收起动画）
          _disclosure(
            open: _editing || _subgroupsExpanded,
            duration: disclosure,
            child: _childList(
              gap: _SidebarMetrics.childGap,
              children: <Widget>[
                for (final AylaChannelSubgroup sg in sorted.skip(3).toList())
                  _buildSubgroupRow(sg, d),
                // tsx 491：追加段内附页脚
                AylaDirectoryLoadMore(
                  loading: d.subgroupDirectory.loading,
                  error: d.subgroupDirectory.error,
                  hasMore: d.subgroupDirectory.hasMore,
                  invalidated: d.subgroupDirectory.invalidated,
                  loadMore: d.subgroupDirectory.loadMore,
                  refresh: d.subgroupDirectory.refresh,
                  retainCompletedSpace: false, // 紧凑侧栏不保留空页脚
                ),
              ],
            ),
          ),
          if (showMore)
            _moreButton(
              expanded: _subgroupsExpanded,
              count: shown - 3,
              onTap: () {
                setState(() => _subgroupsExpanded = !_subgroupsExpanded);
                _startTracking();
              },
            ),
          // tsx 500–504：编辑态列表下方 ＋添加（本轮不接弹窗 → 无副作用）
          if (d.canManageSubgroups && _editing)
            _moreButton(
              expanded: false,
              count: 0,
              icon: 'iconPlus',
              semanticLabel: '添加子群', // tsx 501 aria-label
              onTap: () {},
            ),
        ],
      ),
    );
  }

  Widget _buildSubgroupRow(AylaChannelSubgroup sg, _PanelData d) {
    final _Selection sel = _Selection('subgroup', sg.id);
    final bool active =
        widget.activeScene == AylaGroupScene.chat &&
        sg.id == d.activeSubgroupId;
    final bool hovered = _hoveredRow == sel;

    return SizedBox(
      height: _SidebarMetrics.childHeight, // 30
      child: Padding(
        padding: const EdgeInsets.only(right: 2), // `.channel-subgroup-item`
        child: AnimatedContainer(
          // `:hover { background: .18 }`；选中时自身底被 auroraqua 288–291 取消
          // （`:has(.has-auroraqua-highlight)` 特异性更高）。
          // ⚠️ **选中态不给过渡**：web 是直接 `background: transparent`（瞬时交还给共享
          // 胶囊）；渐隐会让半透明底色与后方胶囊/玻璃卡混色成**灰**（用户 2026-09-21 实报
          // 「高亮块出现和消失有一段灰色过渡，拖沓很脏」）。
          duration: active ? Duration.zero : AylaDurations.auroraqua,
          curve: AylaCurves.auroraqua,
          decoration: BoxDecoration(
            color: active
                ? _SidebarZeroTint.hover
                : (hovered ? _SidebarTints.hover : _SidebarZeroTint.hover),
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: Row(
            spacing: 2, // `.channel-subgroup-item { gap: 2px }`
            children: <Widget>[
              Expanded(child: _buildSubgroupButton(sg, d, sel, active)),
              // tsx 440–444：编辑态每行一个笔（`flex: none`，**不是浮层**）
              if (_editing)
                MouseRegion(
                  onEnter: (_) => _setHovered(row: sel),
                  onExit: (_) => _setHovered(row: null),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // 本轮不接弹窗 → 无副作用
                    child: Semantics(
                      button: true,
                      label: '编辑子群 ${sg.name}',
                      child: AnimatedContainer(
                        // `.channel-subgroup-edit-btn`：background/color 180ms
                        duration: AylaDurations.fast,
                        curve: AylaCurves.auroraqua,
                        width: _SidebarMetrics.overlayButtonSize, // 28×28
                        height: _SidebarMetrics.overlayButtonSize,
                        decoration: BoxDecoration(
                          color: hovered
                              ? _SidebarTints
                                    .hover // `.channel-subgroup-edit-btn:hover` 也是 .18
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AylaRadii.rInput),
                        ),
                        child: Center(
                          child: _SidebarGlyph(
                            _SidebarGlyphKind.pencil,
                            color: hovered
                                ? AylaColors.textPrimary
                                : AylaColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubgroupButton(
    AylaChannelSubgroup sg,
    _PanelData d,
    _Selection sel,
    bool active,
  ) {
    return MouseRegion(
      onEnter: (_) => _setHovered(row: sel, button: sel),
      onExit: (_) => _setHovered(row: null, button: null),
      child: AylaPressScale(
        hoverScale: false,
        pressScale: true,
        onTap: () {
          widget.onSelectSubgroup?.call(sg.id);
          widget.onSelectScene?.call(AylaGroupScene.chat);
          _jumpSweep('subgroup');
        },
        onPressChanged: (bool p) => _setPressed(p ? sel : null),
        child: Container(
          key: _keyFor(sel), // 胶囊目标 rect 的实测基准（= 按钮本体）
          height: _SidebarMetrics.childHeight, // 30
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp2, // `padding: 0 var(--sp-2)`
          ),
          child: Row(
            spacing: AylaSpacing.sp2, // `gap: var(--sp-2)`
            children: <Widget>[
              Expanded(
                child: Text(
                  sg.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis, // `.channel-subgroup-name`
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 14, // font-size: 14px
                    fontWeight: FontWeight.w600,
                    color: active
                        ? AylaColors.textPrimary
                        : AylaColors.textSecondary,
                  ),
                ),
              ),
              // tsx 437 + group.css 318–331（`.channel-subgroup-muted`）
              if (sg.muted) const _MutedTag(),
              // tsx 438：未读徽标（`.channel-subgroup-badge`，与 posts 同规格）
              if (sg.unreadCount > 0)
                TabBadge(
                  count: sg.unreadCount,
                  metrics: TabBadgeMetrics.channelBadge,
                  placement: TabBadgePlacement.inline,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ======================= 语音房下拉（tsx 263–337） =======================

  Widget _buildVoiceDropdown(_PanelData d, Duration disclosure) {
    final List<AylaChannelVoiceRoom> rooms = d.voiceRooms;
    final int shown = math.max(rooms.length, d.voiceDirectory.total);
    // tsx 255：`showVoiceMore = total > 3 || len > 3`
    final bool showMore = shown > 3;
    // tsx 297：折叠高度 = `max(0, min(3, n) * 31 − 1)`（行**全渲染但被裁**）
    final double collapsedHeight = math.max(
      0,
      math.min(3, rooms.length) * _SidebarMetrics.childPitch - 1,
    );

    return _disclosure(
      open: _voiceOpen,
      duration: disclosure,
      child: _dropdownShell(
        gap: _SidebarDropdownBox.childGap,
        padding: const EdgeInsets.only(
          top: _SidebarDropdownBox.childPaddingTop,
          bottom: _SidebarDropdownBox.childPaddingBottom,
        ),
        children: <Widget>[
          // tsx 294–325：**一个稳定父级**（行跨「前三条/展开区」移动时保留状态），
          // 折叠时高度固定 + 内容全渲染并被裁剪。Flutter 没有 CSS 的静默裁剪
          // → `SizedBox + ClipRect + OverflowBox`（`15-*` 坑 4）。
          AnimatedSize(
            duration: disclosure, // auroraquaIndicatorTransition
            curve: AylaCurves.auroraquaEaseOut,
            alignment: Alignment.topCenter,
            child: _voiceExpanded
                ? _voiceList(rooms, d, collapsed: false)
                : SizedBox(
                    height: collapsedHeight,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        maxHeight: double.infinity,
                        child: _voiceList(rooms, d, collapsed: true),
                      ),
                    ),
                  ),
          ),
          if (showMore)
            _moreButton(
              expanded: _voiceExpanded,
              count: shown - 3,
              onTap: () {
                setState(() => _voiceExpanded = !_voiceExpanded);
                _startTracking();
              },
            ),
          // tsx 331：页脚只在展开后渲染
          if (_voiceExpanded)
            AylaDirectoryLoadMore(
              loading: d.voiceDirectory.loading,
              error: d.voiceDirectory.error,
              hasMore: d.voiceDirectory.hasMore,
              invalidated: d.voiceDirectory.invalidated,
              loadMore: d.voiceDirectory.loadMore,
              refresh: d.voiceDirectory.refresh,
              retainCompletedSpace: false,
            ),
        ],
      ),
    );
  }

  /// 语音房列表：**一个稳定父级**，行按索引绝对定位 —— 活跃度重排时行做 300ms
  /// 位移（web `motion.li layout="position"`，tsx 305–311）；行状态由 key 保留。
  Widget _voiceList(
    List<AylaChannelVoiceRoom> rooms,
    _PanelData d, {
    required bool collapsed,
  }) {
    if (rooms.isEmpty) {
      return _childList(gap: _SidebarMetrics.childGap, children: <Widget>[]);
    }
    final double pitch = _SidebarMetrics.childPitch; // 31
    return _childList(
      gap: _SidebarMetrics.childGap,
      children: <Widget>[
        SizedBox(
          height: rooms.length * pitch - _SidebarMetrics.childGap,
          child: Stack(
            children: <Widget>[
              for (int i = 0; i < rooms.length; i++)
                AnimatedPositioned(
                  key: ValueKey<String>('voice-row-${rooms[i].id}'),
                  duration: AylaDurations.auroraqua,
                  curve: AylaCurves.auroraquaEaseOut,
                  top: i * pitch,
                  left: 0,
                  right: 0,
                  height: _SidebarMetrics.childHeight,
                  child: _buildVoiceRow(
                    rooms[i],
                    d,
                    index: i,
                    collapsed: collapsed,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceRow(
    AylaChannelVoiceRoom room,
    _PanelData d, {
    required int index,
    required bool collapsed,
  }) {
    final _Selection sel = _Selection('voice', room.id);
    final bool active =
        widget.activeScene == AylaGroupScene.voice &&
        room.id == d.activeVoiceChannelId;
    final bool hovered = _hoveredRow == sel;
    // tsx 303–315：折叠时 index ≥ 3 的行仍渲染但被裁 → 对齐 web 的
    // `disabled + tabIndex=-1 + inert` = IgnorePointer + ExcludeSemantics。
    final bool hidden = collapsed && index >= 3;

    final GlobalKey<AylaNavHighlightState> hk = _voiceHighlightKeys.putIfAbsent(
      room.id,
      () => GlobalKey<AylaNavHighlightState>(),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: IgnorePointer(
        ignoring: hidden,
        child: ExcludeSemantics(
          excluding: hidden,
          child: AnimatedContainer(
            // 选中态瞬时（见子群行注释：渐隐会与后方胶囊混色成灰）
            duration: active ? Duration.zero : AylaDurations.auroraqua,
            curve: AylaCurves.auroraqua,
            decoration: BoxDecoration(
              color: active
                  ? _SidebarZeroTint.hover
                  : (hovered ? _SidebarTints.hover : _SidebarZeroTint.hover),
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
            ),
            child: MouseRegion(
              onEnter: (_) => _setHovered(row: sel, button: sel),
              onExit: (_) => _setHovered(row: null, button: null),
              child: AylaPressScale(
                hoverScale: false,
                pressScale: true,
                semanticLabel: room.name,
                onPressChanged: (bool p) => _setPressed(p ? sel : null),
                onTap: () {
                  widget.onSelectScene?.call(AylaGroupScene.voice);
                  widget.onSelectVoiceChannel?.call(room.id);
                  // 行内独立胶囊（`sharedLayout={false}`）→ 直接驱动自身扫光；
                  // 同样排到下一帧（该行胶囊在选中态生效后才挂载）。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    hk.currentState?.setSweep(true, jump: true);
                  });
                },
                child: Stack(
                  children: <Widget>[
                    // web 对语音房行传 `sharedLayout={false}`（tsx 316–318）：
                    // 行有自己的排序位移，二次共享投影会互相取消 → 该行保持
                    // **行内独立胶囊**（扫光 / hover 底仍与其它行一致）。
                    if (active)
                      Positioned.fill(
                        // **不做入场淡入**（照 web：`AuroraquaNavHighlight` 的
                        // `initial={false}`，挂载即到位）。用户要的「高亮移动动画」来自
                        // 行自身：它在 `motion.li layout="position"` 里 ⇒ 高亮是行的
                        // 子元素、**随行一起位移**（300ms `auroraquaIndicatorTransition`）。
                        // Flutter 侧同理由外层 `AnimatedPositioned(top: i × pitch)`
                        // 驱动整行（含本胶囊）位移 —— 这就是「边播动画边上移」。
                        child: AylaNavHighlight(
                          key: hk,
                          sweep: true,
                          // 与三组共享胶囊**同一语义**：扫光只看**按钮本体**
                          // （auroraqua 163）。该行无浮层钮 → 行级 == 按钮级。
                          sweepActive: _hoveredButton == sel,
                          showBorder: false,
                        ),
                      ),
                    Container(
                      key: _keyFor(sel), // 胶囊目标 = 行内按钮（200×30）
                      height: _SidebarMetrics.childHeight,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AylaSpacing.sp2, // `padding: 0 var(--sp-2)`
                      ),
                      child: Row(
                        spacing: AylaSpacing.sp2, // `gap: var(--sp-2)`
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              room.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AylaFonts.body,
                                fontFamilyFallback: AylaFonts.cjkFallback,
                                fontSize: 14, // font-size: 14px
                                fontWeight: FontWeight.w600,
                                color: active
                                    ? AylaColors.textPrimary
                                    : AylaColors.textSecondary,
                              ),
                            ),
                          ),
                          // `.channel-voice-room-count`（Space Grotesk 12px）
                          if (room.memberCount > 0)
                            Text(
                              '${room.memberCount}',
                              style: TextStyle(
                                fontFamily: AylaFonts.utility,
                                fontSize: 12,
                                color: AylaColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 直播下拉（tsx 338–424） =======================

  Widget _buildLiveDropdown(_PanelData d, Duration disclosure) {
    final List<AylaChannelLiveRoom> rooms = d.liveRooms;
    final int shown = math.max(rooms.length, d.liveDirectory.total);
    final bool showMore = shown > 3;

    return _disclosure(
      open: _liveOpen,
      duration: disclosure,
      child: _dropdownShell(
        gap: _SidebarDropdownBox.liveGap,
        padding: const EdgeInsets.only(
          top: _SidebarDropdownBox.livePaddingTop,
          bottom: _SidebarDropdownBox.livePaddingBottom,
        ),
        children: <Widget>[
          // tsx 367–383：前 3 条
          _childList(
            gap: _SidebarMetrics.liveGap,
            children: <Widget>[
              for (final AylaChannelLiveRoom r in rooms.take(3).toList())
                _buildLiveRow(r, d),
            ],
          ),
          // tsx 385–413：「展开更多」追加段（**另一个列表** + 独立收起动画）
          _disclosure(
            open: _liveExpanded,
            duration: disclosure,
            child: _childList(
              gap: _SidebarMetrics.liveGap,
              children: <Widget>[
                for (final AylaChannelLiveRoom r in rooms.skip(3).toList())
                  _buildLiveRow(r, d),
              ],
            ),
          ),
          if (showMore)
            _moreButton(
              expanded: _liveExpanded,
              count: shown - 3,
              onTap: () {
                setState(() => _liveExpanded = !_liveExpanded);
                _startTracking();
              },
            ),
          if (_liveExpanded)
            AylaDirectoryLoadMore(
              loading: d.liveDirectory.loading,
              error: d.liveDirectory.error,
              hasMore: d.liveDirectory.hasMore,
              invalidated: d.liveDirectory.invalidated,
              loadMore: d.liveDirectory.loadMore,
              refresh: d.liveDirectory.refresh,
              retainCompletedSpace: false,
            ),
        ],
      ),
    );
  }

  Widget _buildLiveRow(AylaChannelLiveRoom room, _PanelData d) {
    final _Selection sel = _Selection('live', '${room.id}');
    final bool active =
        widget.activeScene == AylaGroupScene.live &&
        '${room.id}' == d.activeLiveChannelId;
    final bool hovered = _hoveredRow == sel;

    return SizedBox(
      // `.channel-live-room { padding: 6px var(--sp-2) }` + 封面 36 高 → 行高 48
      height: _SidebarMetrics.liveRowHeight,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: AnimatedContainer(
          // 选中态瞬时（见子群行注释：渐隐会与后方胶囊混色成灰）
          duration: active ? Duration.zero : AylaDurations.auroraqua,
          curve: AylaCurves.auroraqua,
          decoration: BoxDecoration(
            color: active
                ? _SidebarZeroTint.hover
                : (hovered ? _SidebarTints.hover : _SidebarZeroTint.hover),
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: MouseRegion(
            onEnter: (_) => _setHovered(row: sel, button: sel),
            onExit: (_) => _setHovered(row: null, button: null),
            child: AylaPressScale(
              hoverScale: false,
              pressScale: true,
              onTap: () {
                widget.onSelectLiveChannel?.call(room.id);
                _jumpSweep('live');
              },
              onPressChanged: (bool p) => _setPressed(p ? sel : null),
              child: Container(
                key: _keyFor(sel), // 胶囊目标 = 行内按钮（200×48）
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp2, // `padding: 6px var(--sp-2)`
                  vertical: 6,
                ),
                child: Row(
                  spacing: AylaSpacing.sp2, // `gap: var(--sp-2)`
                  children: <Widget>[
                    _buildLiveCover(room),
                    Expanded(
                      child: Text(
                        room.title,
                        maxLines: 2, // `-webkit-line-clamp: 2`（group.css 1344）
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 13, // font-size: 13px
                          height: 1.35, // line-height: 1.35
                          color: active
                              ? AylaColors.textPrimary
                              : AylaColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 直播封面（`.channel-live-cover`，group.css 1294–1334）。
  Widget _buildLiveCover(AylaChannelLiveRoom room) {
    const BorderRadius r = BorderRadius.all(Radius.circular(AylaRadii.rSm));
    final bool hasCover = room.cover != null && room.cover!.isNotEmpty;
    return SizedBox(
      width: _SidebarMetrics.liveCoverWidth, // 64
      height: _SidebarMetrics.liveCoverHeight, // aspect-ratio 16/9 → 36
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: r,
              child: Padding(
                // 内容区 = border-box 内缩 1px（CSS border 占布局，Flutter 不占）
                padding: const EdgeInsets.all(_SidebarMetrics.borderWidth),
                child: hasCover
                    ? ResourceImage(
                        src: room.cover!,
                        fit: BoxFit.cover,
                        fallback: Center(
                          child: AylaIcon(
                            _iconVideo,
                            size: 16,
                            color: AylaColors.ice500,
                          ),
                        ),
                      )
                    : Center(
                        child: AylaIcon(
                          _iconVideo,
                          size: 16,
                          color: AylaColors.ice500, // color: var(--ice-500)
                        ),
                      ),
              ),
            ),
          ),
          // `border: 1px solid var(--glass-border)`（group.css 1305）
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: r,
                  border: Border.all(color: AylaColors.glassBorder),
                ),
              ),
            ),
          ),
          // `.channel-live-dot { top:4; right:4; 8×8; --pink-500; pill }`（1326–1334）
          if (room.isLive)
            Positioned(
              top: _SidebarMetrics.liveDotInset,
              right: _SidebarMetrics.liveDotInset,
              child: Semantics(
                label: '直播中',
                child: Container(
                  width: _SidebarMetrics.liveDotSize,
                  height: _SidebarMetrics.liveDotSize,
                  decoration: const BoxDecoration(
                    color: AylaColors.pink500,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ======================= 共用小件 =======================

  /// 展开/收起动画（web `disclosureVariants`：`height auto ↔ 0` **且** `opacity 1 ↔ 0`，
  /// 300ms `--auroraqua-ease-out`）。
  ///
  /// ⚠️ opacity 必须包在**外层**：收起时内层 child 会被换成 0 高占位，
  /// 放在内层就来不及播淡出（实测）。
  Widget _disclosure({
    required bool open,
    required Duration duration,
    required Widget child,
  }) {
    return AnimatedOpacity(
      duration: duration,
      curve: AylaCurves.auroraquaEaseOut,
      opacity: open ? 1 : 0,
      child: AnimatedSize(
        duration: duration,
        curve: AylaCurves.auroraquaEaseOut,
        alignment: Alignment.topCenter,
        child: open ? child : const SizedBox(width: double.infinity, height: 0),
      ),
    );
  }

  /// 下拉容器外壳（`.channel-subgroups` / `.channel-voice-rooms` / `.channel-live-rooms`）。
  Widget _dropdownShell({
    required double gap,
    required EdgeInsets padding,
    required List<Widget> children,
  }) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: gap,
        children: children,
      ),
    );
  }

  /// 子列表（`.channel-subgroup-list` 等：`gap` + `padding-left: 40px`）。
  Widget _childList({required double gap, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(left: _SidebarMetrics.indent), // 40
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: gap,
        children: children,
      ),
    );
  }

  /// 「展开更多（N）」/「收起」/「＋添加」（`.channel-*-more`、`.channel-subgroup-add`）。
  Widget _moreButton({
    required bool expanded,
    required int count,
    required VoidCallback onTap,
    String? icon,
    String? semanticLabel,
  }) {
    final String text = expanded ? '收起' : '展开更多（$count）';
    return Padding(
      // `.channel-subgroup-more { margin: 4px 0 0 40px; width: calc(100% - 40px) }`
      padding: const EdgeInsets.only(
        left: _SidebarMetrics.indent,
        top: _SidebarMoreButton.marginTop,
      ),
      child: Semantics(
        button: true,
        label: semanticLabel ?? text,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: CustomPaint(
            // `border: 1px dashed var(--glass-border)`（group.css 1112 等）
            foregroundPainter: const _DashedBorderPainter(
              radius: AylaRadii.rInput,
              color: AylaColors.glassBorder,
            ),
            child: Container(
              height: _SidebarMoreButton.height, // 28
              padding: const EdgeInsets.symmetric(
                horizontal:
                    _SidebarMoreButton.paddingH, // `padding: 0 var(--sp-3)`
              ),
              decoration: BoxDecoration(
                color: _SidebarTints.moreButtonBg, // rgba(255,250,251,.5)
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
              ),
              child: Center(
                child: icon != null
                    ? AylaIcon(
                        aylaIconByName(icon)!,
                        size:
                            16, // tsx 502 `<IconPlus width={16} height={16} />`
                        color: AylaColors.textSecondary,
                      )
                    : Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: _SidebarMoreButton.fontSize, // 12px
                          fontWeight: FontWeight.w700, // font-weight: 700
                          color: AylaColors.textSecondary,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 禁言标签（group.css 318–331） =======================

/// `.channel-subgroup-muted` / `.group-chat-subgroup-tab-muted` /
/// `.group-info-subgroup-muted` 共用规格：`padding: 1px 6px` + pill +
/// `--ice-300` 底 + `--indigo-700` 字 + Fredoka 10px + `line-height: 1.4` + nowrap。
class _MutedTag extends StatelessWidget {
  const _MutedTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: const BoxDecoration(
        color: AylaColors.ice300,
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        '禁言',
        maxLines: 1,
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 10, // font-size: 10px
          height: 1.4, // line-height: 1.4
          color: AylaColors.indigo700,
        ),
      ),
    );
  }
}

// ======================= 私有 glyph（tsx 605–627 内联 SVG） =======================

/// 组件内私有 glyph 的三种形状（web 这三条 path **不在** `icons.tsx`）。
enum _SidebarGlyphKind {
  /// tsx 605–611（群名头 16px，`m9 6 6 6-6 6`）。
  chevronRight,

  /// tsx 613–619（三角展开键 14px，`m6 9 6 6 6-6`）。
  chevronDown,

  /// tsx 621–627（编辑笔 14px）。
  pencil,

  /// tsx 275 / 350 / 502：`IconPlus`（在 `icons.tsx`，这里走 `AylaIcon`）。
  plus,
}

/// 组件内私有 glyph（照 `_TrashGlyph` 先例）。
///
/// 基类属性同 `icons.tsx` 的 `base()`：`viewBox 0 0 24 24` / `fill:none` /
/// `stroke:currentColor` / `strokeWidth 2` / round cap·join。
class _SidebarGlyph extends StatelessWidget {
  const _SidebarGlyph(this.kind, {this.size = 14, this.color});

  final _SidebarGlyphKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (kind == _SidebarGlyphKind.plus) {
      // `IconPlus` 已在 icons.tsx（tsx 275/350/502 都用它）→ 复用图标库
      return AylaIcon(
        aylaIconByName('iconPlus')!,
        size: size,
        color: color ?? AylaColors.textSecondary,
      );
    }
    final String d = switch (kind) {
      _SidebarGlyphKind.chevronRight => 'm9 6 6 6-6 6',
      _SidebarGlyphKind.chevronDown => 'm6 9 6 6 6-6',
      _SidebarGlyphKind.pencil =>
        'M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z',
      _SidebarGlyphKind.plus => '',
    };
    return CustomPaint(
      size: Size.square(size),
      painter: _SidebarGlyphPainter(
        d: d,
        color: color ?? AylaColors.textSecondary,
      ),
    );
  }
}

/// 单路径线性 glyph 绘制（按 `size / 24` 缩放 viewBox）。
class _SidebarGlyphPainter extends CustomPainter {
  const _SidebarGlyphPainter({required this.d, required this.color});

  final String d;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24); // viewBox 0 0 24 24
    canvas.drawPath(
      parseMiniSvgPath(d),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            2 // strokeWidth: 2
        ..strokeCap = StrokeCap
            .round // strokeLinecap: round
        ..strokeJoin = StrokeJoin
            .round // strokeLinejoin: round
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SidebarGlyphPainter old) =>
      old.d != d || old.color != color;
}

/// 极简 SVG path 解析（只覆盖本文件三条 path 用到的 `M/m L/l H/h V/v A/a Z`）。
///
/// `A/a` 只取半径与终点（本组件用于笔尖的圆弧），不解析 large-arc / sweep 标志。
@visibleForTesting
Path parseMiniSvgPath(String d) {
  final Path path = Path();
  // ⚠️ 分词必须用「命令字母 | 数字」正则，**不能按空白切分**：SVG path 里
  // 数字可以紧凑书写（`m9 6 6 6-6 6` 的 `6-6`），按空白切会得到 `'6-6'`
  // → `double.parse` 抛 FormatException（实测踩过）。
  final RegExp tokenRe = RegExp(r'[MLHVAZmlhvaz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?');
  final List<String> tokens = tokenRe
      .allMatches(d)
      .map((RegExpMatch m) => m[0]!)
      .toList();
  double x = 0;
  double y = 0;
  double sx = 0;
  double sy = 0;
  int i = 0;
  String cmd = '';
  double next() => double.parse(tokens[i++]);
  bool isCmd(String t) => t.length == 1 && 'MLHVAZmlhvaz'.contains(t);

  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      cmd = tokens[i];
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        x = sx;
        y = sy;
      }
      continue;
    }
    switch (cmd) {
      case 'M':
        x = next();
        y = next();
        sx = x;
        sy = y;
        path.moveTo(x, y);
        cmd = 'L';
      case 'm':
        x += next();
        y += next();
        sx = x;
        sy = y;
        path.moveTo(x, y);
        cmd = 'l';
      case 'L':
        x = next();
        y = next();
        path.lineTo(x, y);
      case 'l':
        x += next();
        y += next();
        path.lineTo(x, y);
      case 'H':
        x = next();
        path.lineTo(x, y);
      case 'h':
        x += next();
        path.lineTo(x, y);
      case 'V':
        y = next();
        path.lineTo(x, y);
      case 'v':
        y += next();
        path.lineTo(x, y);
      case 'A':
        final double rx = next();
        final double ry = next();
        next(); // x-axis-rotation
        next(); // large-arc-flag
        next(); // sweep-flag
        x = next();
        y = next();
        path.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry));
      case 'a':
        final double rx = next();
        final double ry = next();
        next();
        next();
        next();
        x += next();
        y += next();
        path.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry));
      default:
        i++;
    }
  }
  return path;
}

/// 1px 虚线圆角边框（CSS `border: 1px dashed`；Flutter 无 dashed border）。
///
/// 段长按浏览器对 1px 边框的常见画法取 **3px 实 / 3px 空**。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    const double dash = 3;
    const double gap = 3;
    for (final PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.radius != radius || old.color != color;
}

// ======================= 图标常量 =======================

/// tsx 375 / 402 的 `<IconVideo width={16} height={16} />`。
final AylaIconData _iconVideo = aylaIconByName('iconVideo')!;

// ======================= 自定义 RenderObject 层 =======================

/// 主列场景行的浮层（**paint 定位**，零滞后）。
///
/// 三个必须一起做的细节（每个都实测踩过，`13-*` §6.11）：
/// 1. `performLayout` 自己写：层用 `Positioned.fill` 铺满（命中测试要覆盖），
///    但默认 ProxyBox 布局会把 40px 的行**拉伸到视口高** → `size = constraints.biggest`
///    + `child.layout(BoxConstraints.tightFor(...))`；
/// 2. 覆盖 `applyPaintTransform`（与 paint 同偏移）：否则 `localToGlobal`、命中测试、
///    语义树、测试里的 `getRect` 读到的还是布局坐标；
/// 3. 位置取决于**外部**占位的移动 → 重建/滚动/动画帧都要重绘。
class _SidebarStickyRow extends SingleChildRenderObjectWidget {
  const _SidebarStickyRow({
    super.key,
    required this.topOf,
    required this.left,
    required this.width,
    required this.height,
    required Widget super.child,
  });

  /// 该行的绘制顶部（卡片坐标系；paint 阶段求值）。
  final double? Function() topOf;
  final double left;
  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _StickyRowRender(topOf: topOf, left: left, width: width, height: height);

  @override
  void updateRenderObject(BuildContext context, _StickyRowRender renderObject) {
    renderObject
      ..topOf = topOf
      ..left = left
      ..width = width
      ..height = height
      // 属性（含闭包）变化意味着几何可能变 → 主动重绘（属性 setter 不做
      // identical 之外的比较，不会自动 markNeedsPaint）。
      ..markNeedsPaint();
  }
}

class _StickyRowRender extends RenderProxyBox {
  _StickyRowRender({
    required this.topOf,
    required this.left,
    required this.width,
    required this.height,
  });

  double? Function() topOf;
  double left;
  double width;
  double height;

  double _y = 0;

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(BoxConstraints.tightFor(width: width, height: height));
    // ⚠️ 这里**不能**调用 topOf()：它要读兄弟子树的 `localToGlobal`，而 layout
    // 期间尚未完成（会触发 'RenderBox.size accessed beyond the scope of resize'
    // —— 实测踩过）。位置一律在 paint 阶段求值（本帧 layout 已完成 → 同帧、零滞后）。
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? c = child;
    if (c == null) return;
    _y = topOf() ?? 0; // paint 阶段：本帧 layout 已完成 → 与内容同帧
    context.paintChild(c, Offset(offset.dx + left, offset.dy + _y));
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(left, _y, 0, 1); // ⚠️ 必须与 paint 同偏移
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? c = child;
    if (c == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(left, _y),
      position: position,
      hitTest: (BoxHitTestResult r, Offset p) => c.hitTest(r, position: p),
    );
  }
}

/// 下拉容器层（**paint-only 裁剪**，等价 `useSidebarContentClip` 的
/// `clip-path: inset(top 0 bottom 0)`）。
///
/// `start = max(viewportTop, headerBottom + gap, dropdownTop)`、
/// `end = min(viewportBottom, nextHeaderTop − gap, dropdownBottom)`
/// —— 与 web 逐条一致（含「相邻行吸附时把 flex gap 也留空」的语义）。
class _SidebarDropdownClip extends SingleChildRenderObjectWidget {
  const _SidebarDropdownClip({
    super.key,
    required this.cardKey,
    required this.viewportKey,
    required this.gap,
    required this.rowTop,
    required this.nextRowTop,
    required Widget super.child,
  });

  final GlobalKey cardKey;
  final GlobalKey viewportKey;
  final double gap;

  /// 本段 header 当前绘制顶部（null = 尚未布局）。
  final double? Function() rowTop;

  /// 下一段 header 当前绘制顶部（最后一段传 null）。
  final double? Function()? nextRowTop;

  @override
  RenderObject createRenderObject(BuildContext context) => _DropdownClipRender(
    cardKey: cardKey,
    viewportKey: viewportKey,
    gap: gap,
    rowTop: rowTop,
    nextRowTop: nextRowTop,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _DropdownClipRender renderObject,
  ) {
    renderObject
      ..cardKey = cardKey
      ..viewportKey = viewportKey
      ..gap = gap
      ..rowTop = rowTop
      ..nextRowTop = nextRowTop
      ..markNeedsPaint();
  }
}

class _DropdownClipRender extends RenderProxyBox {
  _DropdownClipRender({
    required this.cardKey,
    required this.viewportKey,
    required this.gap,
    required this.rowTop,
    required this.nextRowTop,
  });

  GlobalKey cardKey;
  GlobalKey viewportKey;
  double gap;
  double? Function() rowTop;
  double? Function()? nextRowTop;

  /// 当前裁剪矩形（局部坐标；null = 不裁剪）。
  ///
  /// **命中测试也要用它**：web 的 `clip-path` 会同时裁掉**指针命中**区域
  /// （被裁掉的内容点不到）；只做 paint 裁剪会让「已被吸顶行盖住的内容」
  /// 仍然吃掉点击 —— 实测「展开更多」按钮被吸顶的聊天行遮挡时点击落空。
  Rect? _clipRect;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final Rect? clip = _clipRect;
    if (clip != null && !clip.contains(position)) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? card =
        cardKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? vp =
        viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (card == null || vp == null) {
      super.paint(context, offset);
      return;
    }
    final Offset vpOffset = vp.localToGlobal(Offset.zero, ancestor: card);
    final double vpTop = vpOffset.dy;
    final double vpBottom = vpTop + vp.size.height;
    // ⚠️ 本层在**卡片坐标系**的范围：本层挂在滚动内容的 Column 里，
    // `offset.dy` 是相对 Column 的坐标、与 rowTop()/视口（卡片坐标）不同基准 ——
    // 混用会把 topInset 算成 63px（实测下拉被裁到只剩 4px，点击全失效）。
    final double selfTop = localToGlobal(Offset.zero, ancestor: card).dy;
    final double selfBottom = selfTop + size.height;
    final double? header = rowTop();
    if (header == null) {
      // 几何未就绪（首帧 layout 尚未发生）→ **不裁剪**：若按 selfTop 兜底，
      // 会凭空裁掉下拉顶部 44px，连命中一起挡掉（实测「语音房A / 摸鱼」点不中）。
      _clipRect = null;
      super.paint(context, offset);
      return;
    }
    final double headerBottom = header + _SidebarMetrics.rowHeight;
    final double? nextTop = nextRowTop?.call();
    final double start = math.max(vpTop, math.max(headerBottom + gap, selfTop));
    final double end = math.min(
      vpBottom,
      math.min(nextTop == null ? vpBottom : nextTop - gap, selfBottom),
    );
    final double topInset = (start - selfTop).clamp(0.0, size.height);
    final double bottomInset = (selfBottom - end).clamp(
      0.0,
      size.height - topInset,
    );
    if (topInset <= 0 && bottomInset <= 0) {
      _clipRect = null;
      super.paint(context, offset);
      return;
    }
    final Rect clip = Rect.fromLTRB(
      0,
      topInset,
      size.width,
      size.height - bottomInset,
    );
    _clipRect = clip;
    context.pushClipRect(
      needsCompositing,
      offset,
      clip,
      super.paint,
      clipBehavior: Clip.hardEdge,
    );
  }
}

// ======================= 预览 =======================

/// 预览数据：子群/语音房/直播间都给到 5 条以上，便于展示「展开更多」。
const List<AylaChannelSubgroup> _previewSubgroups = <AylaChannelSubgroup>[
  AylaChannelSubgroup(
    id: 'sg1',
    name: '默认组',
    isDefault: true,
    lastMessageSeq: 10,
  ),
  AylaChannelSubgroup(
    id: 'sg2',
    name: '摸鱼',
    lastMessageSeq: 30,
    unreadCount: 5,
  ),
  AylaChannelSubgroup(id: 'sg3', name: '技术', lastMessageSeq: 20, muted: true),
  AylaChannelSubgroup(id: 'sg4', name: '深夜电台', lastMessageSeq: 5),
  AylaChannelSubgroup(id: 'sg5', name: '作业互助', lastMessageSeq: 1),
];

const List<AylaChannelVoiceRoom> _previewVoiceRooms = <AylaChannelVoiceRoom>[
  AylaChannelVoiceRoom(id: 'v1', name: '自习室', memberCount: 3),
  AylaChannelVoiceRoom(id: 'v2', name: '闲聊房'),
  AylaChannelVoiceRoom(id: 'v3', name: '深夜连麦', memberCount: 1),
  AylaChannelVoiceRoom(id: 'v4', name: '开黑'),
  AylaChannelVoiceRoom(id: 'v5', name: '听歌'),
];

const List<AylaChannelLiveRoom> _previewLiveRooms = <AylaChannelLiveRoom>[
  AylaChannelLiveRoom(id: 1, title: '爱莉的晚间电台', isLive: true),
  AylaChannelLiveRoom(id: 2, title: '作业直播'),
  AylaChannelLiveRoom(id: 3, title: '游戏实况'),
  AylaChannelLiveRoom(id: 4, title: '绘画过程'),
  AylaChannelLiveRoom(id: 5, title: '点歌台'),
];

/// **可交互**样张宿主：一级（场景）与二级（子群/语音房/直播间）选项卡都能真实点。
///
/// 组件本身只接受 `activeXxx` 受控属性（与 web 一致），所以「点击 → 换选中」
/// 必须由调用方持有状态；画布/预览里由这里代持，交互才不是死的。
class _SidebarDemo extends StatefulWidget {
  const _SidebarDemo({
    required this.initialScene,
    this.initialSubgroupId,
    this.initialVoiceChannelId,
    this.initialLiveChannelId,
    this.canManage = false,
    this.initialEditing = false,
    this.initialExpanded = false,
    this.subgroups = _previewSubgroups,
    this.voiceRooms = _previewVoiceRooms,
    this.liveRooms = _previewLiveRooms,
    this.voiceMemberCount = 0,
    this.postUnread = 0,
  });

  final AylaGroupScene initialScene;
  final String? initialSubgroupId;
  final String? initialVoiceChannelId;
  final String? initialLiveChannelId;
  final bool canManage;
  final bool initialEditing;
  final bool initialExpanded;
  final List<AylaChannelSubgroup> subgroups;
  final List<AylaChannelVoiceRoom> voiceRooms;
  final List<AylaChannelLiveRoom> liveRooms;
  final int voiceMemberCount;
  final int postUnread;

  @override
  State<_SidebarDemo> createState() => _SidebarDemoState();
}

class _SidebarDemoState extends State<_SidebarDemo> {
  late AylaGroupScene _scene = widget.initialScene;
  late String? _subgroupId = widget.initialSubgroupId;
  late String? _voiceChannelId = widget.initialVoiceChannelId;
  late String? _liveChannelId = widget.initialLiveChannelId;

  /// 语音房列表（样张自持，可重排）。
  ///
  /// **为什么样张要自己排序**：web 的语音房顺序来自**活跃排序投影**
  /// （`VoiceChannelDescriptor.last_occupied_at / last_vacant_at`：最近有人进入的在前、
  /// 有人区在无人区之前），组件只按传入顺序渲染 —— 与 `AylaChannelSidebar` 的
  /// 「受控属性」契约一致。
  /// tsx 305–311 的 `motion.li layout="position"`（300ms `auroraquaIndicatorTransition`）
  /// 就是**重排时行的平滑位移**；组件侧由 `AnimatedPositioned(top: i × pitch)` 等价实现，
  /// 所以只有**顺序真的变了**才看得到那段动画 —— 这里用示例数据把它演出来：
  /// 点任意语音房 → 该房视为「有人进入」→ 排到最前，其余行平滑下移。
  late final List<AylaChannelVoiceRoom> _voiceRooms =
      List<AylaChannelVoiceRoom>.of(widget.voiceRooms);

  /// 模拟一次「进入语音房」：把该房提到最前（活跃排序），并标记为有人。
  void _enterVoiceRoom(String id) {
    final int index = _voiceRooms.indexWhere(
      (AylaChannelVoiceRoom r) => r.id == id,
    );
    if (index <= 0) return;
    final AylaChannelVoiceRoom picked = _voiceRooms.removeAt(index);
    _voiceRooms.insert(
      0,
      AylaChannelVoiceRoom(
        id: picked.id,
        name: picked.name,
        memberCount: math.max(1, picked.memberCount),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AylaChannelSidebar(
      groupId: 'g1',
      groupName: '星海观测站',
      activeScene: _scene,
      activeSubgroupId: _subgroupId,
      activeVoiceChannelId: _voiceChannelId,
      activeLiveChannelId: _liveChannelId,
      subgroups: widget.subgroups,
      voiceRooms: _voiceRooms,
      liveRooms: widget.liveRooms,
      canManageSubgroups: widget.canManage,
      postUnread: widget.postUnread,
      voiceMemberCount: widget.voiceMemberCount,
      previewEditing: widget.initialEditing,
      previewExpanded: widget.initialExpanded,
      animateEntrance: false,
      onSelectScene: (AylaGroupScene s) => setState(() => _scene = s),
      onSelectSubgroup: (String id) => setState(() {
        _scene = AylaGroupScene.chat;
        _subgroupId = id;
      }),
      onSelectVoiceChannel: (String id) => setState(() {
        _scene = AylaGroupScene.voice;
        _voiceChannelId = id;
        _enterVoiceRoom(id); // 活跃排序：该房排到最前 → 行平滑位移
      }),
      onSelectLiveChannel: (int id) => setState(() {
        _scene = AylaGroupScene.live;
        _liveChannelId = '$id';
      }),
    );
  }
}

/// 频道侧栏样张（宽屏；web `ChannelSidebar.tsx` + `group.css` 680–1370）。
///
/// 五档：默认（子群选中 + 状态标识三型）/ 语音（展开更多）/ 直播（展开更多）/
/// 编辑态（笔 + ＋添加 + 行内笔）/ 空数据。
/// **可交互**：点一级选项卡（聊天/语音/直播/帖子/桌游）、点子群/语音房/直播间行、
/// 点三角展开收起、点笔进编辑态 —— 高亮迁移 / 扫光 / 按压 `.98` 全部真实响应；
/// 与组件画布（`preview/component_gallery.dart`）共用同一份样张。
Widget aylaChannelSidebarSamples() {
  // `.channel-sidebar-slot` 宽 284 = 260 + 2×12（group.css 684）
  const double slotWidth = 284;
  Widget cell(String label, Widget child) => SizedBox(
    width: slotWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 组件几何按**本 cell 的视口**算（画布视口与真实宽屏不同）
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: const Size(slotWidth, 620)),
            child: SizedBox(height: 620, child: child),
          ),
        ),
        const SizedBox(height: 6),
        // ⚠️ 说明文字必须限宽，否则会把 Row/Wrap 撑出画布（`15-*` 坑 8）
        SizedBox(
          width: slotWidth,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    ),
  );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        cell(
          '默认：聊天 + 子群【摸鱼】选中；语音 7 人在麦（裸文本）、LIVE（裸文本）、帖子未读粉徽标',
          const _SidebarDemo(
            initialScene: AylaGroupScene.chat,
            initialSubgroupId: 'sg2',
            canManage: true,
            voiceMemberCount: 7,
            postUnread: 12,
          ),
        ),
        cell(
          '语音：语音房【闲聊房】选中（行内独立胶囊，不迁移）+ 展开更多；'
          '点任意语音房 → 它视为「有人进入」排到最前 = web 的活跃排序位移动画',
          const _SidebarDemo(
            initialScene: AylaGroupScene.voice,
            initialVoiceChannelId: 'v2',
            voiceMemberCount: 4,
            initialExpanded: true,
          ),
        ),
        cell(
          '直播：直播间【爱莉的晚间电台】选中；封面 64×36 + 右上粉点 + 两行标题',
          const _SidebarDemo(
            initialScene: AylaGroupScene.live,
            initialLiveChannelId: '1',
            initialExpanded: true,
          ),
        ),
        cell(
          '编辑态：聊天行笔 is-active + 追加段全显 + 行内笔 + 列表下方【＋添加子群】',
          const _SidebarDemo(
            initialScene: AylaGroupScene.chat,
            initialSubgroupId: 'sg1',
            canManage: true,
            initialEditing: true,
          ),
        ),
        cell(
          '空数据：无子群 / 无语音房 / 无直播间（下拉只剩容器内边距）',
          const _SidebarDemo(
            initialScene: AylaGroupScene.posts,
            subgroups: <AylaChannelSubgroup>[],
            voiceRooms: <AylaChannelVoiceRoom>[],
            liveRooms: <AylaChannelLiveRoom>[],
          ),
        ),
      ],
    ),
  );
}

/// `@Preview` 入口（组件画布另见 `preview/component_gallery.dart`）。
@Preview(
  group: 'Widgets',
  name: '频道侧栏（默认 / 语音 / 直播 / 编辑态 / 空数据；可点一级与二级选项卡）',
  size: Size(1280, 1460),
  wrapper: previewTheme,
)
Widget previewChannelSidebar() => aylaChannelSidebarSamples();
