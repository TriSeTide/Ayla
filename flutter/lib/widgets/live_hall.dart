/// live 域第二批（B2-2）：直播大厅卡片 + 大厅网格。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveChannelCard.tsx  12–53（封面 + 徽章 + 人数 + 标题 + meta + 收藏/转发）
/// components/live/LiveHall.tsx         13–45（空态 + 网格 + stagger）
/// app.css 3275–3279   .live-hall-grid：grid / repeat(auto-fill, minmax(240px,1fr)) / gap sp4
/// app.css 3281–3285   .live-card-wrap：relative / width 100% / min-width 0
/// app.css 3287–3305   .live-card：flex column / gap sp2 / padding sp4 / transparent-bg…（下面逐条）
/// app.css 3306–3310   .live-card-wrap > .favorite-toggle：absolute top sp3 / right sp3
/// app.css 3350–3355   .live-card-title：--font-display / text-primary / 16 / line-height 1.35
/// app.css 3357–3363   .live-card-owner：flex 1 1 auto / min-width 0 / secondary / 13 / 1.4
/// app.css 3365–3369   .live-hall-empty：secondary / center / padding sp12 0
/// app.css 3371–3397   .live-badge 族（padding 2×sp2 / pill / 12 / --font-utility）
/// live.css 486–493    .live-badge-source：--sakura-300 底 + --grape-700 字 + max-width 12ch
/// live.css 559–572    .live-card-cover：relative / center / aspect-ratio 16/9 / radius-input /
///                     透明底 / color --ice-500 / 1px --glass-border / overflow hidden
/// live.css 575–583    .live-card-cover-badge：absolute top calc(sp1 - 1px) / left sp1 / gap sp1
/// live.css 585–596    .live-card-meta（gap sp2 / min-width 0）+ .live-card-source-tags（max-width 55%）
/// live.css 617–655    .live-hub 网格覆写：≤768 2 列 + padding sp3 sp4；≥769 3 列；≥1440 4 列
/// live.css 628–631    .live-hub .live-card { padding: sp2 }（≤768）
/// live.css 636–640    ≥769：收藏键 top/right = calc(sp4 + sp1) = 20px
/// live.css 811–814    .live-badge-live 覆写为 --pink-500 底 + --surface 字（U9）
/// live.css 1333–1354  .live-card-viewers：右下玻璃胶囊（--glass-bg-strong + blur8 无 saturate）
/// shell.css 619–629   .placeholder-title（Fredoka 28/600）+ .placeholder-desc（14 secondary）
/// auroraqua.css 29–52 卡片族过渡/悬停（translate 0 -2px + --glass-shadow-hover）/按压 .99
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - 收藏键与转发键由**页面注入状态与回调**（Flutter 侧收藏有独立状态机：
///   `AylaFavoriteButton` 的 state/busy/onToggle）；web 里 `action === undefined`
///   默认渲染 `<FavoriteButton compact/>`，这里由 [AylaLiveChannelCard.showActions] 表达
///   「要不要这两键」（搜索页传 `action={null}` ⇒ `showActions: false`）。
/// - ⚠️ **转发键是有意偏离 web 的补充**：web 的 `LiveChannelCard` 只有收藏键
///   （转发键在直播**房头部**，`LiveRoomBody.tsx` 330–339）。用户 2026-09-22 要求
///   「要转发键，都要」⇒ 卡片也补上，位置贴收藏键左侧（收藏键保持 web 的右上角位置）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/visibility.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart' show aylaEnableSampleMedia;
import '../theme/tokens.dart';
import 'directory_controls.dart' show AylaFavoriteButton, FavoriteState;
import 'primitives.dart';
import 'resource_image.dart';
import 'reveal.dart';

/// 直播状态（web `LiveChannelStatus`；仅这三值渲染徽章）。
enum AylaLiveStatus {
  live,
  ended,
  idle;

  /// 徽章文案（tsx 23–25）。
  String get label => switch (this) {
    AylaLiveStatus.live => '直播中',
    AylaLiveStatus.ended => '已结束',
    AylaLiveStatus.idle => '未开播',
  };

  static AylaLiveStatus? parse(String? raw) => switch (raw) {
    'live' => AylaLiveStatus.live,
    'ended' => AylaLiveStatus.ended,
    'idle' => AylaLiveStatus.idle,
    _ => null,
  };
}

/// 直播卡数据投影（web `LiveCardData`：`LiveChannelDescriptor` 的 Partial 投影）。
class AylaLiveCardData {
  const AylaLiveCardData({
    required this.id,
    required this.title,
    this.cover,
    this.status,
    this.ownerId = '',
    this.ownerNickname,
    this.viewerCount,
    this.visibility,
    this.allowedGroupNames = const <String>[],
    this.groupName,
  });

  /// 频道 id（web `id: string | number`）。
  final String id;

  /// 标题。
  final String title;

  /// 封面图源（`/api/v1/media/...` 或外部 URL）；null = 用视频图标占位。
  final String? cover;

  /// 状态（null / 未知值 → 不渲染徽章）。
  final AylaLiveStatus? status;

  /// 归属用户 id（判「爱莉」角标）。
  final String ownerId;

  /// 主播昵称（**优先于** [AylaLiveHall.ownerNames] 的懒拉兜底）。
  final String? ownerNickname;

  /// 在看人数：null = **读不到**（presence 存储不可用）⇒ 不渲染角标、不用 0 冒充；
  /// 0 是真实读数，照常显示。
  final int? viewerCount;

  /// 可见性（`types.ts` 三值；跨域共用模型）。
  final AylaPostVisibility? visibility;

  final List<String> allowedGroupNames;
  final String? groupName;

  /// web `cardVisibilityLabels(channel)` → `getVisibilityLabels`（逐条同源）。
  ///
  /// ⚠️ web 的转发函数是 `item.visibility ? getVisibilityLabels(...) : []`
  /// （`components/cards/cardData.ts:14–16`）——**visibility 缺失 ⇒ 空数组**，
  /// 不走 `getVisibilityLabels` 自己的「群可见」兜底（那个兜底只用于
  /// `visibility === "group"` 但群名为空的旧数据）。
  List<String> get visibilityLabels => visibility == null
      ? const <String>[]
      : aylaVisibilityLabels(
          visibility: visibility,
          allowedGroupNames: allowedGroupNames,
          groupName: groupName,
        );
}

/// 人数文本（web `utils/liveViewers.ts formatViewerCount`）：
/// <1000 原样；1k–9.9k 一位小数；≥10k 取整；后缀 `k`。
String aylaFormatViewerCount(int count) {
  if (count < 1000) return '$count';
  final double k = count / 1000;
  return '${k.toStringAsFixed(count < 10000 ? 1 : 0)}k';
}

/// 列表卡面人数角标取值（web `liveViewerBadge`）：
/// **仅 `status == live` 且 `viewerCount` 有读数**时返回数字，否则 null（不渲染）。
int? aylaLiveViewerBadge(AylaLiveStatus? status, int? viewerCount) {
  if (status != AylaLiveStatus.live) return null;
  return viewerCount;
}

/// `.live-card-wrap` + `button.live-card` —— 直播频道卡（`LiveChannelCard.tsx` 53 行）。
class AylaLiveChannelCard extends StatelessWidget {
  const AylaLiveChannelCard({
    super.key,
    required this.channel,
    required this.onEnter,
    this.ownerName,
    this.isElysia = false,
    this.revealDelay,
    this.showActions = true,
    this.favoriteState = FavoriteState.unknown,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.reserveMetaSpace = false,
  });

  /// 频道数据。
  final AylaLiveCardData channel;

  /// 进入直播间（web `onEnter`）。
  final VoidCallback onEnter;

  /// 主播昵称兜底（web `ownerNames[owner_id]`：后端列表不带主播名时由页面补齐）。
  final String? ownerName;

  /// owner 是爱莉 → 加「爱莉」角标（tsx 36）。
  final bool isElysia;

  /// 入场延迟（非 null → 挂 `.reveal-item` + `--reveal-delay`，`staggerDelay` 50ms/条 cap 300）。
  final Duration? revealDelay;

  /// 是否渲染收藏键（web `action === null` 的搜索页用法 ⇒ false）。
  ///
  /// ⚠️ **卡片上不放转发键**（用户 2026-09-22：「语音列表卡片上不用显示分享键，直播也不用」）——
  /// 转发键只出现在**房头部**（web `LiveRoomBody.tsx` 330–339）。
  final bool showActions;

  /// 收藏状态（`AylaFavoriteButton` 契约）。
  final FavoriteState favoriteState;

  /// 收藏请求进行中。
  final bool favoriteBusy;

  /// 收藏失败文案。
  final String? favoriteError;

  /// 切换收藏（传入目标状态：true = 收藏）。
  final ValueChanged<bool>? onToggleFavorite;

  /// 收藏状态未知/出错时点击 → 重新拉取。
  final VoidCallback? onRetryFavoriteStatus;

  /// **网格等高**（用户 2026-09-22：直播所有卡片高度要一致）。
  ///
  /// web 的卡片在 CSS grid 里被 `align-items: stretch`（默认值）拉平：同一行里
  /// 「没有 meta 行」的卡会被撑到与最高卡等高。Flutter 没有 stretch ⇒ 这里改为
  /// **预留 meta 行高度**（`AylaLiveHall` 恒传 true），使等高由构造保证。
  ///
  /// ⚠️ 本卡片单独使用（搜索结果 / 目录投影）时**不要**开：那种上下文没有同行拉平，
  /// 预留会在卡底多出一段空白（web 同样没有）。
  final bool reserveMetaSpace;


  @override
  Widget build(BuildContext context) {
    final Duration? delay = revealDelay;
    final Widget card = _buildWrap(context);
    if (delay == null) return card;
    return AylaRevealItem(delay: delay, child: card);
  }

  Widget _buildWrap(BuildContext context) {
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    // ≥769：收藏键 top/right = calc(sp4 + sp1) = 20px；窄屏 = sp3 = 12px（app.css 3306–3310）
    final double actionInset = narrow
        ? AylaSpacing.sp3
        : AylaSpacing.sp4 + AylaSpacing.sp1;

    return Stack(
      children: <Widget>[
        _card(context, narrow),
        if (showActions)
          Positioned(
            top: actionInset,
            right: actionInset,
            child: AylaFavoriteButton(
              state: favoriteState,
              compact: true, // `.favorite-toggle.is-compact`：32×32、图标 16
              busy: favoriteBusy,
              actionError: favoriteError,
              onToggle: onToggleFavorite,
              onRetryStatus: onRetryFavoriteStatus,
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context, bool narrow) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<String> labels = channel.visibilityLabels;
    final String? owner = (channel.ownerNickname ?? '').isNotEmpty
        ? channel.ownerNickname
        : ownerName;

    return AylaCardInteraction(
      onTap: onEnter,
      semanticLabel: '${channel.title}直播间',
      builder: (BuildContext context, bool hovered) => GlassSurface(
        // `.live-card`：--glass-bg / 1px 亮边 / radius 16 / --glass-shadow / blur24 sat1.4
        radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard,
        shadow: hovered ? AylaShadows.glassHover : AylaShadows.glass,
        padding: EdgeInsets.all(
          // `.live-hub .live-card { padding: sp2 }`（≤768）；基础 padding sp4
          narrow ? AylaSpacing.sp2 : AylaSpacing.sp4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, // 卡片是 flex column
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: <Widget>[
            _cover(context, t),
            // `.live-card-title`：Fredoka 16 / 1.35（固定行高防字体 fallback 抖动）
            AylaScrollingText(
              text: channel.title,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 16,
                height: 1.35,
                color: AylaColors.textPrimary,
              ),
            ),
            // meta 行：网格里恒占位（等高）；单独使用时按 web 的条件渲染
            if (reserveMetaSpace)
              SizedBox(
                height: _metaRowHeight(t),
                child: (owner ?? '').isNotEmpty || labels.isNotEmpty
                    ? _meta(context, owner, labels)
                    : null,
              )
            else if ((owner ?? '').isNotEmpty || labels.isNotEmpty)
              _meta(context, owner, labels),
          ],
        ),
      ),
    );
  }

  /// `.live-card-cover`（live.css 559–572）+ 两组角标。
  Widget _cover(BuildContext context, AylaTextStyles t) {
    final AylaLiveStatus? status = channel.status;
    final int? viewers = aylaLiveViewerBadge(status, channel.viewerCount);
    final String? cover = channel.cover;

    return AspectRatio(
      aspectRatio: 16 / 9, // aspect-ratio: 16 / 9
      child: DecoratedBox(
        decoration: BoxDecoration(
          // `background: transparent` + `color: --ice-500`（无封面时的图标色）
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          border: Border.all(color: AylaColors.glassBorder),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: cover == null
                    // 无封面：居中视频图标（tsx 33；`aria-hidden`）
                    ? Center(
                        child: AylaIcon(
                          aylaIconByName('iconVideo')!,
                          size: 28,
                          color: AylaColors.ice500,
                        ),
                      )
                    // 有封面：`alt: ''`（装饰图）→ 失败只回退、不提示；铺满 + cover
                    : ResourceImage(
                        src: cover,
                        alt: '',
                        fit: BoxFit.cover,
                      ),
              ),
              // `.live-card-cover-badge`：top calc(sp1 - 1px) = 3 / left sp1 = 4 / gap sp1
              Positioned(
                top: AylaSpacing.sp1 - 1,
                left: AylaSpacing.sp1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: AylaSpacing.sp1,
                  children: <Widget>[
                    if (status != null) _statusBadge(status),
                    if (isElysia) _elysiaBadge(t),
                  ],
                ),
              ),
              // `.live-card-viewers`：right calc(sp1 - 1px) = 3 / bottom sp1 = 4
              if (viewers != null)
                Positioned(
                  right: AylaSpacing.sp1 - 1,
                  bottom: AylaSpacing.sp1,
                  child: _viewersBadge(t, viewers),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态徽章（`.live-badge` 基类 + `-live/-idle/-ended`）。
  ///
  /// ⚠️ `-live` 的底色由 **live.css 811–814** 覆写为 `--pink-500` + `--surface`
  /// （后加载压过 app.css 3379–3382 的 `--sakura-100`）。
  Widget _statusBadge(AylaLiveStatus status) {
    final _BadgeColors colors = switch (status) {
      AylaLiveStatus.live => const _BadgeColors(
        bg: AylaColors.pink500,
        fg: AylaColors.surface,
      ),
      AylaLiveStatus.ended || AylaLiveStatus.idle => const _BadgeColors(
        bg: AylaColors.ice100, // --ice-100
        fg: AylaColors.textSecondary,
      ),
    };
    return _LiveBadge(
      label: status.label,
      background: colors.bg,
      foreground: colors.fg,
    );
  }

  /// 爱莉角标（`.live-badge-elysia`：`--bubble-elysia` 渐变底 + `--text-on-pink`）。
  Widget _elysiaBadge(AylaTextStyles t) {
    return _LiveBadge(
      label: '爱莉',
      gradient: AylaGradients.bubbleElysia,
      foreground: AylaColors.textOnPink,
    );
  }

  /// `.live-card-viewers`（live.css 1333–1354）：右下玻璃胶囊。
  Widget _viewersBadge(AylaTextStyles t, int viewers) {
    return Semantics(
      label: '$viewers 人在看', // tsx 39 aria-label
      child: Container(
        constraints: const BoxConstraints(minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2),
        decoration: BoxDecoration(
          color: AylaColors.glassBgStrong, // --glass-bg-strong
          borderRadius: AylaRadii.pill,
          border: Border.all(color: AylaColors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 3, // gap: 3px
          children: <Widget>[
            AylaIcon(aylaIconByName('iconUsers')!, size: 12),
            Text(
              aylaFormatViewerCount(viewers),
              style: TextStyle(
                fontFamily: AylaFonts.utility,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                letterSpacing: 0.3,
                height: 1, // line-height: 1
                color: AylaColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// meta 行的**预留高度** = max(主播名行高 13×1.4, 标签胶囊高 12×body 行高 + 2×2)。
  ///
  /// 与语音卡的「预留 owner 行」同一手法（`voice_channels.dart` 的同行等高说明）：
  /// 让每张卡的高度**由构造决定**，不依赖测量、也不用 `IntrinsicHeight`
  /// （卡片内含 `LayoutBuilder`，而 LayoutBuilder 不支持 intrinsics）。
  static double _metaRowHeight(AylaTextStyles t) {
    final double ownerLine = 13 * 1.4;
    // 标签胶囊高 = 12 × body 行高 + padding 2+2；**向上取整**到整像素，
    // 否则预留高度比真实布局（RenderBox 取整）少 0.4px ⇒ 又会出现亚像素裁切
    final double tagLine = (12 * (t.body.height ?? 1.55) + 2 + 2).ceilToDouble();
    return math.max(ownerLine, tagLine);
  }

  /// `.live-card-meta`：主播名（收缩滚动）+ 来源标签（`max-width: 55%`）。
  Widget _meta(BuildContext context, String? owner, List<String> labels) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Row(
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: <Widget>[
            if ((owner ?? '').isNotEmpty)
              // `.live-card-owner { flex: 1 1 auto; min-width: 0; 13px / 1.4 }`
              Expanded(
                child: AylaScrollingText(
                  text: owner!,
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 13,
                    height: 1.4,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ),
            if (labels.isNotEmpty)
              // `.live-card-source-tags { flex: 0 0 auto; max-width: 55% }`
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.55,
                ),
                child: AylaScrollingTags(
                  children: <Widget>[
                    for (final String label in labels) AylaSourceTag(label),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `.live-badge` 基类（app.css 3371–3377）：`padding 2px sp2` / pill / 12 / `--font-utility`。
class _LiveBadge extends StatelessWidget {
  const _LiveBadge({
    required this.label,
    required this.foreground,
    this.background,
    this.gradient,
  });

  final String label;
  final Color foreground;
  final Color? background;
  final List<Color>? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: background,
        gradient: gradient == null
            ? null
            : cssLinearGradient(angleDeg: 135, colors: gradient!),
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AylaFonts.utility,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 12,
          color: foreground,
        ),
      ),
    );
  }
}

class _BadgeColors {
  const _BadgeColors({required this.bg, required this.fg});

  final Color bg;
  final Color fg;
}

/// 大厅网格（`LiveHall.tsx` 45 行）。
///
/// LiveHall 只在大厅页渲染（`LiveHubPage.tsx` 156，容器 `.live-hub.directory-page`）
/// ⇒ `.live-hub` 的网格覆写**恒生效**：≤768 → 2 列（+ 上下 padding sp3），
/// ≥769 → 3 列，≥1440 → 4 列；左右 padding 由页面 `.directory-content` 持有
/// （`directory-filters.css 171–181` 把它归 0）。
class AylaLiveHall extends StatelessWidget {
  const AylaLiveHall({
    super.key,
    required this.channels,
    required this.onEnter,
    this.elysiaUserId,
    this.ownerNames = const <String, String>{},
    this.revealItems = false,
    this.padding,
    this.favoriteStateBuilder,
    this.onToggleFavorite,
  });

  /// 频道列表。
  final List<AylaLiveCardData> channels;

  /// 进入直播间（传频道 id）。
  final ValueChanged<String> onEnter;

  /// 爱莉 profile 的 user id（用于「爱莉」角标）；null = 不标注。
  final String? elysiaUserId;

  /// `owner_id → 展示昵称`兜底（大厅列表不带主播信息时由页面补齐；
  /// 后端给了 `ownerNickname` 时以后者为准）。
  final Map<String, String> ownerNames;

  /// 逐条浮入（stagger 50ms/条、cap 300）。
  final bool revealItems;

  /// 网格 padding 覆盖；null = 按 web（窄屏上下 `sp3`、左右 0——左右归页面）。
  final EdgeInsetsGeometry? padding;

  /// 逐卡收藏状态（页面注入；web 由 `<FavoriteButton>` 自管，Flutter 侧数据层在页面）。
  final FavoriteState Function(AylaLiveCardData channel)? favoriteStateBuilder;

  /// 逐卡切换收藏（true = 收藏）。
  final void Function(AylaLiveCardData channel, bool next)? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);

    if (channels.isEmpty) {
      final AylaTextStyles t = AylaTextStyles.of(context);
      // `.live-hall-empty`（app.css 3365–3369）+ placeholder 两行（shell.css 619–629）
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '还没有直播间', // tsx 32
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 28, // `.placeholder-title`
                fontWeight: FontWeight.w600,
                color: AylaColors.textPrimary,
              ),
            ),
            Text(
              '点右下角 + 发起第一场直播吧', // tsx 33
              textAlign: TextAlign.center,
              style: t.body.copyWith(
                fontSize: 14, // `.placeholder-desc`
                color: AylaColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // `.live-hub` 覆写：≤768 → 2 / ≥769 → 3 / ≥1440 → 4
        final int columns = narrow
            ? 2
            : (constraints.maxWidth >= 1440 ? 4 : 3);
        const double gap = AylaSpacing.sp4; // gap: var(--sp-4)
        final EdgeInsetsGeometry resolved =
            padding ??
            EdgeInsets.only(top: narrow ? AylaSpacing.sp3 : 0, bottom: narrow ? AylaSpacing.sp3 : 0);
        final double available =
            constraints.maxWidth - resolved.horizontal;
        final double itemWidth = (available - gap * (columns - 1)) / columns;

        return Padding(
          padding: resolved,
          // web 是 CSS grid（等宽列、行高随内容；同行 `align-items: stretch`）
          // ⇒ 用 Wrap 表达等宽列 + 内容高（缺 meta 行的卡会比同行略矮，属已知小差）
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (int i = 0; i < channels.length; i += 1)
                SizedBox(
                  width: itemWidth,
                  child: AylaLiveChannelCard(
                    channel: channels[i],
                    ownerName: ownerNames[channels[i].ownerId],
                    isElysia:
                        elysiaUserId != null &&
                        channels[i].ownerId == elysiaUserId,
                    revealDelay: revealItems
                        ? AylaRevealMotion.staggerDelay(i)
                        : null,
                    favoriteState:
                        favoriteStateBuilder?.call(channels[i]) ??
                        FavoriteState.notFavorited,
                    onToggleFavorite: onToggleFavorite == null
                        ? null
                        : (bool next) => onToggleFavorite!(channels[i], next),
                    reserveMetaSpace: true, // 网格内等高（用户 2026-09-22）
                    onEnter: () => onEnter(channels[i].id),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ======================= 预览样张 =======================

/// 直播大厅样张（可交互）：卡片网格（收藏/转发可点）+ 空态。
Widget aylaLiveHallSamples() {
  aylaEnableSampleMedia();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(1000, 640),
        label:
            '直播大厅（≥769 → 3 列；卡片 padding sp4；**卡片等高**——meta 行恒占位）· 可交互：点卡进入 / 点收藏键切换',
        child: const _LiveHallDemo(columns: 3),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 480),
        label: '窄屏（≤768 → 2 列 + 卡片 padding sp2 + 网格上下 padding sp3）',
        child: const _LiveHallDemo(columns: 2),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(1000, 200),
        label: '空态（app.css 3365–3369 + shell.css 619–629）',
        child: const AylaLiveHall(
          channels: <AylaLiveCardData>[],
          onEnter: _noopEnter,
        ),
      ),
    ],
  );
}

void _noopEnter(String _) {}

class _LiveHallDemo extends StatefulWidget {
  const _LiveHallDemo({required this.columns});

  /// 仅用于样张舞台宽度（列数由组件按断点自算）。
  final int columns;

  @override
  State<_LiveHallDemo> createState() => _LiveHallDemoState();
}

class _LiveHallDemoState extends State<_LiveHallDemo> {
  final Set<String> _favorites = <String>{'lc2'};
  int _enters = 0;

  List<AylaLiveCardData> get _channels => const <AylaLiveCardData>[
    AylaLiveCardData(
      id: 'lc1',
      title: '深夜电台 · 爱莉陪你写代码',
      status: AylaLiveStatus.live,
      ownerId: 'u-elysia',
      ownerNickname: '爱莉',
      viewerCount: 1240, // → 1.2k
      visibility: AylaPostVisibility.public,
      allowedGroupNames: <String>['冰樱研究社'],
    ),
    AylaLiveCardData(
      id: 'lc2',
      title: '周末的雪山行记',
      status: AylaLiveStatus.ended,
      ownerId: 'u2',
      ownerNickname: '汐汐',
      viewerCount: 0, // 0 是真实读数；但已结束 ⇒ 不显示角标
      visibility: AylaPostVisibility.friends,
    ),
    AylaLiveCardData(
      id: 'lc3',
      title: '未开播的房间',
      status: AylaLiveStatus.idle,
      ownerId: 'u3',
      visibility: AylaPostVisibility.group,
      groupName: '冰樱研究社',
    ),
    AylaLiveCardData(
      id: 'lc4',
      title: '长标题压力：今晚八点开播，主题是「把 Ayla 复刻到桌面端」的进度复盘与答疑',
      status: AylaLiveStatus.live,
      ownerId: 'u4',
      ownerNickname: '一个名字很长的主播昵称测试一下滚动',
      viewerCount: null, // 读不到 ⇒ 不渲染人数角标（不用 0 冒充）
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AylaLiveHall(
            channels: _channels,
            elysiaUserId: 'u-elysia',
            onEnter: (_) => setState(() => _enters += 1),
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
            revealItems: false,
            favoriteStateBuilder: (AylaLiveCardData c) =>
                _favorites.contains(c.id)
                ? FavoriteState.favorited
                : FavoriteState.notFavorited,
            onToggleFavorite: (AylaLiveCardData c, bool next) => setState(() {
              if (next) {
                _favorites.add(c.id);
              } else {
                _favorites.remove(c.id);
              }
            }),
          ),
        ),
        Text(
          '进入 $_enters 次 · 已收藏 ${_favorites.length} 个',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台（与其它批次同纪律：断点/布局都读 `MediaQuery` 视口）。
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

/// 直播大厅（卡片 + 网格 + 空态）。
@Preview(
  group: 'Widgets',
  name: '直播大厅（卡片网格 + 空态）',
  size: Size(1100, 1000),
  wrapper: previewTheme,
)
Widget aylaLiveHallPreview() => aylaLiveHallSamples();
