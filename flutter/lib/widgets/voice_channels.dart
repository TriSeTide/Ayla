/// voice 域第一批（B1-1）：语音频道卡片 / 卡片网格列表 / 控制条。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// VoiceChannelCard.tsx 1–47    wrap > card(role=button,tabIndex=0) > head(标签组 + 收藏键)
///                              > title(IconMic 14 + 名称) > owner? > foot(人数 + 加入钮)
/// VoiceChannelList.tsx 1–43    channels.map → 卡片；0 项 → .voice-list-empty 空态
/// VoiceControls.tsx 1–31       离开频道；`livekit === "failed"` 时追加「重新加入」
/// app.css 2811–2815            .voice-channel-list（基础竖列 gap sp2 —— 被网格覆盖）
/// app.css 2817–2832            .voice-channel-card 基础**横排** + `.mine` 边色
/// app.css 2910–2915            .voice-list-empty：padding sp4 / 13px / secondary / 居中
/// app.css 3099–3120            .voice-controls / .voice-leave-btn / .voice-rejoin-btn
/// voice.css 471–485            .voice-source-tag（Micro Tag）：pill / padding 0 8 /
///                              sakura-300 底 / grape-700 字 / Fredoka 11 / ls .8 /
///                              max-width 12ch + ellipsis
/// voice.css 505–523            .voice-hub 网格：2 列 · gap sp3 · padding sp3 sp4；
///                              .voice-channel-card-wrap { min-width: 0 }（reveal 挂外层）
/// voice.css 526–628            .voice-hub 竖排卡全族（head / title / owner / foot / meta / join）
/// voice.css 647–659            ≥769 → 3 列；≥1440 → 4 列（**只有 `.voice-hub` 有这两条**）
/// voice.css 690–695            .group-voice 网格：**恒 2 列** · padding 0
/// voice.css 697–789            .group-voice 竖排卡全族（与 hub **逐字相同**）
/// typed-result-cards.css 46–140  目录结果上下文（同样逐字相同；单列）
/// auroraqua.css 28–52          卡片族动效：transition translate/box-shadow/border-color
///                              300ms `--auroraqua-ease` + scale 200ms；hover 上浮 -2 +
///                              `--glass-shadow-hover`；`:active` 归位 + `scale .99`
/// ```
///
/// ## 层叠关键结论（防后人误加档位）
/// `.voice-hub` / `.group-voice` / `.typed-result-card` 三处的**卡片视觉声明逐字相同**
/// ⇒ Flutter 侧**只有一个竖排形态**，差异只在**容器网格**（列数 / padding）→ 用
/// [AylaVoiceChannelList.columns] / [AylaVoiceChannelList.padding] 表达，**不设 variant**。
/// `app.css:2817` 的**横排**基础卡在真实渲染里从不出现（三个使用点都在上述容器内）⇒ 不实现。
///
/// ## 交互事实
/// - 整卡可点（`role="button" tabIndex={0}`，`Enter`/`Space` 同义，tsx 21–24）→
///   [AylaCardInteraction]（hover 上浮 2 / press .99）+ `focusRingColor: --ice-500`
///   （`voice.css:547/718`、`typed-result-cards.css:68`）；
/// - foot 的加入钮先 `stopPropagation()` 再进房（tsx 41）→ Flutter 里内层按钮天然赢下
///   手势竞技场，卡片的 `onTap` **不会**触发（已用测试锁死这条）；
/// - `joining`：卡片 `aria-disabled` → `opacity .7` + 不可点；按钮 disabled（`.55`）+「加入中…」。
///
/// ## 与 web 的装配差异
/// web 自取 store/网络（`useVoiceChannel.join`、`FavoriteButton` 自拉状态）；Flutter 侧按既有
/// 「展示型 + 注入」模式：进房走 [AylaVoiceChannelCard.onEnter]、收藏槽走
/// [AylaVoiceChannelCard.favorite]（调用方传 `AylaFavoriteButton(compact: true, ...)`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/visibility.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'primitives.dart';
import 'reveal.dart';

/// 语音频道卡数据 —— web `VoiceChannelDescriptor`（`types.ts:863–881`）里本组件真正消费的字段。
///
/// 未收录的字段（`room_name` / `owner_id` / `group` / `allowed_group_ids` / `created_at`）
/// 不参与渲染；缺失就是缺失（不给默认值，认知零规则）。
class AylaVoiceCardData {
  const AylaVoiceCardData({
    required this.id,
    required this.name,
    this.ownerNickname,
    this.memberCount,
    this.visibility,
    this.allowedGroupNames = const <String>[],
    this.groupName,
    this.mine = false,
  });

  final String id;
  final String name;

  /// 创建者显示名（tsx 37：非空才渲染 owner 行）。
  final String? ownerNickname;

  /// 在麦人数（tsx 39：`typeof === "number"` 才渲染）。
  final int? memberCount;

  /// 可见性（`types.ts:872`）。null = 未知（由 [visibilityLabels] 兜底成「群可见」，
  /// 与 web `getVisibilityLabels` 同一兜底）。
  final AylaPostVisibility? visibility;

  final List<String> allowedGroupNames;
  final String? groupName;

  /// 我是否在该频道（`types.ts:880`，列表/详情注入）。
  final bool mine;

  /// web `cardVisibilityLabels(channel)` → `getVisibilityLabels`（逐条同源）。
  List<String> get visibilityLabels => aylaVisibilityLabels(
        visibility: visibility,
        allowedGroupNames: allowedGroupNames,
        groupName: groupName,
      );
}

/// `.voice-channel-card-wrap` + `.voice-channel-card` —— 语音频道卡（`VoiceChannelCard.tsx`）。
class AylaVoiceChannelCard extends StatelessWidget {
  const AylaVoiceChannelCard({
    super.key,
    required this.channel,
    this.active = false,
    this.joining = false,
    this.browsing = false,
    this.onEnter,
    this.revealDelay,
    this.action,
    this.favorite,
  });

  final AylaVoiceCardData channel;

  /// 当前所在频道（`.voice-channel-card.active` → 边色 `--indigo-700`）。
  final bool active;

  /// 进房中（tsx 19–20：`aria-disabled` + 不响应点击）。
  final bool joining;

  /// 目录/搜索语境：只「查看」，不在此开 RTC（tsx 16–19）。
  final bool browsing;

  /// 进房回调（web `onEnter` → `useVoiceChannel.join`）。
  final VoidCallback? onEnter;

  /// 入场延迟（tsx 25–26：非 null 时挂 `.reveal-item` + `--reveal-delay`）。
  final Duration? revealDelay;

  /// head 右侧槽（web `action`）：非空 → 渲染它。
  final Widget? action;

  /// head 右侧槽的**默认**内容（web `action === undefined` 时的 `<FavoriteButton compact/>`）。
  ///
  /// [action] 与 [favorite] 都为 null = web `action={null}`（SearchPage 的用法）→ 不渲染。
  final Widget? favorite;

  /// tsx 19：`browsing ? "查看" : mine ? "进入" : "加入"`（用于卡片 aria-label）。
  String get _verb => browsing
      ? '查看'
      : channel.mine
          ? '进入'
          : '加入';

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final BorderRadius radius =
        BorderRadius.all(Radius.circular(AylaRadii.rCard));
    // voice.css 471–485：来源标签（Micro Tag）。
    // ⚠️ 该规则**不声明 font-weight** ⇒ 继承 body（400），不是 `.auth-intro-feature`
    //    的 500；`max-width: 12ch` 按同字体实测（见 [_sourceTagMaxWidth]）。
    final double sourceTagMaxWidth = _sourceTagMaxWidth();
    // `.voice-card-owner` / `.voice-card-meta`：font-size 12 + 继承 body 的 line-height 1.55。
    final TextStyle metaStyle = t.body.copyWith(
      fontSize: 12,
      color: AylaColors.textSecondary,
    );
    // `.voice-card-owner` 的占位高度 = 12 × 1.55（见下方「同行等高」说明）。
    final double ownerLineHeight = t.body.fontSize! * t.body.height! * 12 / 15;

    final Widget card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, // align-items: stretch
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2) = 8
      children: <Widget>[
        // ---- head：标签组（占满剩余）+ 收藏键（不收缩）----
        Row(
          children: <Widget>[
            Expanded(
              child: AylaScrollingTags(
                children: <Widget>[
                  for (final String label in channel.visibilityLabels)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: sourceTagMaxWidth),
                      child: AylaCapsuleTag(
                        label,
                        tone: CapsuleTone.sakura,
                        // `.voice-source-tag`：padding 0 8 / Fredoka 11 / ls .8 / 无字重声明
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.8,
                      ),
                    ),
                ],
              ),
            ),
            // `.voice-card-head .favorite-toggle { flex: 0 0 auto }`
            if (action != null)
              action!
            else if (favorite != null)
              favorite!,
          ],
        ),
        // ---- title：mic 14（不收缩）+ 名称（滚动单行）----
        Row(
          children: <Widget>[
            AylaIcon(
              aylaIconByName('iconMic')!,
              size: 14, // tsx 34：`<IconMic width={14} height={14} />`
              color: AylaColors.textPrimary,
            ),
            const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
            Expanded(
              child: AylaScrollingText(
                text: channel.name,
                // `.voice-card-title`：15px / 700 / line-height 1.3 / --text-primary
                style: t.body.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        // ---- owner：非空才渲染（tsx 37），但**保留该行高度** ----
        // web 的网格是 CSS grid（默认 `align-items: stretch`）⇒ 同一行卡片等高，
        // 卡内 `margin-top: auto` 再把 foot 压到底；Flutter 侧不能对含
        // `GlassButton`（内部 `LayoutBuilder`）的子树用 `IntrinsicHeight`
        // （`LayoutBuilder` 不支持 intrinsics），故改为**预留这一行的高度** ⇒
        // 同行卡片天然等高、foot 对齐。
        // ⚠️ 已登记差异：整行都无 owner 时，本实现比 web 多留一行空白（web 那行会更矮）。
        SizedBox(
          height: ownerLineHeight,
          child: channel.ownerNickname == null
              ? null
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    channel.ownerNickname!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
        ),
        // ---- foot：人数（占满剩余）+ 加入钮 / 我在其中 ----
        Row(
          children: <Widget>[
            Expanded(
              child: channel.memberCount == null
                  ? const SizedBox.shrink()
                  : Text(
                      '${channel.memberCount} 人',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
            ),
            if (channel.mine && !browsing)
              const _MinePill()
            else
              GlassButton(
                // tsx 42：`joining ? "加入中…" : browsing ? "查看语音房" : "加入"`
                label: joining
                    ? '加入中…'
                    : browsing
                        ? '查看语音房'
                        : '加入',
                variant: GlassButtonVariant.primary,
                minHeight: 32, // `.voice-join-btn { min-height: 32px }`
                fontSize: 13, // 13px
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp3, // padding: 0 var(--sp-3)
                ),
                onPressed: joining ? null : onEnter,
              ),
          ],
        ),
      ],
    );

    // 只挂一次交互壳：卡面材质与描边色都跟着 hover 走
    // （web：`.voice-hub .voice-channel-card:hover { border-color: rgba(157,191,230,.65) }`、
    //  `.active { border-color: --indigo-700 }`——两条同特异性，`.active` 在后 ⇒ 它优先）。
    Widget body(BuildContext context, bool hovered) {
      final Color borderColor = active
          ? AylaColors.indigo700
          : (hovered
              ? AylaColors.ice500.withValues(alpha: 0.65)
              : AylaColors.glassBorder);
      // `[aria-disabled="true"] { cursor: default; opacity: .7 }`（外观保留）
      return Opacity(
        opacity: joining ? 0.7 : 1,
        child: GlassSurface(
          radiusOverride: radius,
          blur: AylaGlass.blurCard, // --glass-filter: blur(24px) saturate(1.4)
          shadow: AylaShadows.glass, // --glass-shadow
          borderOverride: Border.all(color: borderColor),
          padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
          child: card,
        ),
      );
    }

    return AylaCardInteraction(
      semanticLabel: '$_verb语音频道 ${channel.name}', // tsx 28 aria-label
      onTap: joining ? null : onEnter,
      // 卡片族的焦点环是 `--ice-500`（不是 AylaPressScale 的 glow-500）
      focusRingColor: joining ? null : AylaColors.ice500,
      focusRingRadius: radius,
      builder: body,
    );
  }

  /// `max-width: 12ch` 的 Flutter 等价：同字体（Fredoka 11 / ls .8 / w400）下 `0` 的实测宽 × 12。
  ///
  /// CSS 的 `ch` = 元素字体中 `0` 的 advance（含 letter-spacing）；
  /// Flutter 无 `ch` 单位 ⇒ 按语义实测（用户 2026-09-21 拍板：不写死像素）。
  static double _sourceTagMaxWidth() {
    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: '0',
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width * 12;
  }
}

/// `.voice-mine-btn` —— 「我在其中」占位胶囊（`app.css:631–645`）。
///
/// 是 `<span>`（非按钮）：与同排的加入钮**等高对齐**（min-height 32 / padding 0 12）。
class _MinePill extends StatelessWidget {
  const _MinePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.ice100, // background: var(--ice-100)
        borderRadius: AylaRadii.pill,
        border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
      ),
      alignment: Alignment.center,
      child: const Text(
        '我在其中',
        maxLines: 1,
        style: TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AylaColors.indigo700,
        ),
      ),
    );
  }
}

/// `.voice-channel-list` —— 语音频道卡片网格（`VoiceChannelList.tsx`）。
///
/// 列数（web）：
/// - `.voice-hub`：**2 列** → ≥769 **3 列** → ≥1440 **4 列**（`voice.css:507/650/657`）；
/// - `.group-voice`：**恒 2 列**（`voice.css:692`，那两条媒体查询只作用于 `.voice-hub`）
///   → 传 [columns] = 2。
///
/// 行高语义：CSS 网格的 `grid-auto-rows: auto` ⇒ **同一行等高**（该行最高卡决定），
/// 卡片 `margin-top: auto` 把 foot 压到底 ⇒ Flutter 侧按行分块 + `IntrinsicHeight` 等价表达。
class AylaVoiceChannelList extends StatelessWidget {
  const AylaVoiceChannelList({
    super.key,
    required this.channels,
    this.currentChannelId,
    this.joining = false,
    this.browsing = false,
    this.revealItems = false,
    this.columns,
    this.padding,
    this.onJoin,
    this.emptyTitle = '还没有语音房',
    this.emptyDescription = '点右下角 + 建一个吧',
    this.favoriteBuilder,
    this.actionBuilder,
    this.onEnterCard,
  });

  final List<AylaVoiceCardData> channels;

  /// 当前所在频道 id（卡片 `.active`）。
  final String? currentChannelId;

  final bool joining;
  final bool browsing;

  /// 逐条浮入（web `revealItems`；步长 `min(i*50, 300)`ms —— `staggerDelay` 默认 gap 50）。
  final bool revealItems;

  /// 列数；null = `.voice-hub` 规则（2 / 3 / 4 随断点）。
  final int? columns;

  /// 网格 padding；null = `.voice-hub` 的 `padding: var(--sp-3) var(--sp-4)`（12 / 16）。
  final EdgeInsetsGeometry? padding;

  /// 进房回调（web `onJoin(channel.id)`）。
  final ValueChanged<String>? onJoin;

  final String emptyTitle;
  final String emptyDescription;

  /// 收藏槽（head 右侧默认内容）；与 [actionBuilder] 二选一。
  final Widget Function(BuildContext context, AylaVoiceCardData channel)?
      favoriteBuilder;

  /// 自定义 head 右侧槽（web `action`）；非空时优先。
  final Widget Function(BuildContext context, AylaVoiceCardData channel)?
      actionBuilder;

  /// 卡片点击回调；null 时回落到 [onJoin]（web 里两者是同一个 `join`）。
  final ValueChanged<AylaVoiceCardData>? onEnterCard;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      // `.voice-list-empty`（app.css 2910–2915）+ tsx 30–33 的 placeholder 两行
      return Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Column(
          children: <Widget>[
            Text(emptyTitle, style: _emptyTitleStyle),
            const SizedBox(height: AylaSpacing.sp2),
            Text(emptyDescription, style: _emptyDescStyle),
          ],
        ),
      );
    }

    final int cols = columns ?? _hubColumns(context);
    final EdgeInsetsGeometry pad =
        padding ??
            const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4, // padding: var(--sp-3) var(--sp-4)
              vertical: AylaSpacing.sp3,
            );

    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // gap: var(--sp-3) = 12
        children: <Widget>[
          for (int start = 0; start < channels.length; start += cols)
            Row(
              // 同行等高由「卡片预留 owner 行」保证（见 AylaVoiceChannelCard 的说明），
              // 不用 IntrinsicHeight —— 卡片内的 GlassButton 含 LayoutBuilder，
              // 而 LayoutBuilder 不支持 intrinsics（会抛 "does not support
              // returning intrinsic dimensions"）。
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AylaSpacing.sp3,
                children: <Widget>[
                  for (int i = start;
                      i < channels.length && i < start + cols;
                      i++)
                    Expanded(
                      child: _CardSlot(
                        index: i,
                        reveal: revealItems,
                        child: AylaVoiceChannelCard(
                          channel: channels[i],
                          active: channels[i].id == currentChannelId,
                          joining: joining,
                          browsing: browsing,
                          onEnter: () => (onEnterCard ?? _joinById)(channels[i]),
                          favorite: favoriteBuilder?.call(
                            context,
                            channels[i],
                          ),
                          action: actionBuilder?.call(context, channels[i]),
                        ),
                      ),
                    ),
                // 最后一行不足 cols 时补空位（网格语义：列宽不拉伸）
                for (int i = channels.length; i < start + cols; i++)
                  const Expanded(child: SizedBox.shrink()),
              ],
            ),
        ],
      ),
    );
  }

  void _joinById(AylaVoiceCardData channel) => onJoin?.call(channel.id);

  /// `.voice-hub` 列数：<769 → 2；769–1439 → 3；≥1440 → 4（`voice.css:507/650/657`）。
  static int _hubColumns(BuildContext context) {
    final double w = MediaQuery.sizeOf(context).width;
    if (w >= Breakpoint.lg) return 4; // 1440
    if (w > Breakpoint.sm) return 3; // >768
    return 2;
  }

  /// `.placeholder-title`（shell.css 619–624）：Fredoka 28 / 600 / textPrimary。
  static const TextStyle _emptyTitleStyle = TextStyle(
    fontFamily: AylaFonts.display,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    color: AylaColors.textPrimary,
  );

  /// `.placeholder-desc`（shell.css 626–629）：14px / textSecondary。
  static const TextStyle _emptyDescStyle = TextStyle(
    fontFamily: AylaFonts.body,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 14,
    color: AylaColors.textSecondary,
  );
}

/// 单个网格槽：`revealItems` 时挂 `.reveal-item`（延迟 `min(i*50, 300)`ms）。
class _CardSlot extends StatelessWidget {
  const _CardSlot({
    required this.index,
    required this.reveal,
    required this.child,
  });

  final int index;
  final bool reveal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!reveal) return child;
    // web：`.voice-channel-card-wrap.reveal-item` + `--reveal-delay`（tsx 25–26），
    // 延迟来自 `staggerDelay(index)`（gap 默认 50ms、cap 300ms）。
    return AylaRevealItem(index: index, child: child);
  }
}

/// `.voice-controls` —— 语音控制条（`VoiceControls.tsx`）。
///
/// 麦克风开关**不在这里**（web 注释：已上移到成员行内，voice.css 的
/// `VoiceMemberRow onToggleMic`）；本件只有「离开频道」和 `livekit === "failed"` 时的
/// 「重新加入」（媒体断线 ≠ 离开频道，不自动 leave）。
class AylaVoiceControls extends StatelessWidget {
  const AylaVoiceControls({
    super.key,
    this.showRejoin = false,
    this.onLeave,
    this.onRejoin,
  });

  /// web `livekit === "failed"`。
  final bool showRejoin;

  final VoidCallback? onLeave;
  final VoidCallback? onRejoin;

  @override
  Widget build(BuildContext context) {
    return Container(
      // `.voice-controls { padding-top: var(--sp-2); border-top: 1px solid --glass-border }`
      padding: const EdgeInsets.only(top: AylaSpacing.sp2),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AylaColors.glassBorder),
        ),
      ),
      child: Wrap(
        spacing: AylaSpacing.sp3, // gap: var(--sp-3) = 12
        runSpacing: AylaSpacing.sp3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          GlassButton(
            label: '离开频道',
            // `.voice-leave-btn`：透明底 + --destructive 字 + 1px --destructive 边
            variant: GlassButtonVariant.outlineDestructive,
            onPressed: onLeave,
          ),
          if (showRejoin)
            GlassButton(
              label: '重新加入',
              variant: GlassButtonVariant.primary,
              minHeight: 28, // `.voice-rejoin-btn { min-height: 28px }`
              fontSize: 12, // font-size: 12px
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3, // padding: 0 var(--sp-3)
              ),
              onPressed: onRejoin,
            ),
        ],
      ),
    );
  }
}

// ======================= 预览 =======================

/// 语音频道族样张（画布与 @Preview 共用；**可交互**）。
///
/// - 宽屏舞台（1200）看 `.voice-hub` 的 **4 列**（≥1440 才是 4 列，1200 时是 3 列 —— 见下）；
/// - 窄屏舞台（375）看 **2 列**；
/// - 卡片档位：常规 / `mine`（「我在其中」）/ `active`（当前频道边色）/ `joining`（`.7` + 禁用钮）
///   / `browsing`（「查看语音房」）/ 无 owner、无人数；
/// - 点卡片与点「加入」都会累加计数（验证两者各自触发一次，不叠加）；
/// - 空态与「重新加入」形态各一档。
Widget aylaVoiceChannelSamples() => const _VoiceChannelDemo();

class _VoiceChannelDemo extends StatefulWidget {
  const _VoiceChannelDemo();

  @override
  State<_VoiceChannelDemo> createState() => _VoiceChannelDemoState();
}

class _VoiceChannelDemoState extends State<_VoiceChannelDemo> {
  int _joinCount = 0;
  String _lastJoin = '—';
  bool _rejoinVisible = false;

  static const List<AylaVoiceCardData> _channels = <AylaVoiceCardData>[
    AylaVoiceCardData(
      id: '1',
      name: '深夜电台',
      ownerNickname: '爱莉',
      memberCount: 5,
      visibility: AylaPostVisibility.public,
    ),
    AylaVoiceCardData(
      id: '2',
      name: '我在的频道（mine）',
      ownerNickname: '汐汐',
      memberCount: 3,
      visibility: AylaPostVisibility.friends,
      mine: true,
    ),
    AylaVoiceCardData(
      id: '3',
      name: '当前频道（active）',
      ownerNickname: '小满',
      memberCount: 12,
      visibility: AylaPostVisibility.public,
      allowedGroupNames: <String>['冰樱研究社', '深夜电台'],
    ),
    AylaVoiceCardData(
      id: '4',
      name: '公开+白名单群名叠加的语音房（标签会被 12ch 截断）',
      memberCount: null,
      visibility: AylaPostVisibility.public,
      allowedGroupNames: <String>['很久以前的一个群名字'],
    ),
    AylaVoiceCardData(
      id: '5',
      name: '无 owner 无人数',
      visibility: AylaPostVisibility.group,
      groupName: '冰樱研究社',
    ),
    AylaVoiceCardData(
      id: '6',
      name: '我在其中 + browse 语境',
      ownerNickname: '爱莉',
      memberCount: 8,
      visibility: AylaPostVisibility.friends,
      mine: true,
    ),
  ];

  void _joined(String id) => setState(() {
        _joinCount++;
        _lastJoin = id;
      });

  Widget _list({
    Size viewport = const Size(1200, 520),
    int? columns,
    bool browsing = false,
    bool joining = false,
  }) {
    return SizedBox(
      width: viewport.width,
      child: AylaVoiceChannelList(
        channels: _channels,
        currentChannelId: '3',
        joining: joining,
        browsing: browsing,
        columns: columns,
        revealItems: false,
        onJoin: _joined,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Stage(
          viewport: const Size(1200, 560),
          label: '宽屏 1200（<1440 ⇒ 3 列；≥1440 才 4 列）· 卡片档位：常规 / mine / active / '
              '无 owner / 标签 12ch 截断 · 点卡片或「加入」各计一次（$_joinCount 次，最后一次 ${_lastJoin.isEmpty ? '—' : _lastJoin}）',
          child: _list(),
        ),
        _Stage(
          viewport: const Size(375, 620),
          label: '窄屏 375：2 列（`.voice-hub` <769；`.group-voice` 恒 2 列）',
          child: _list(viewport: const Size(375, 620)),
        ),
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp4,
            children: <Widget>[
              const Text('单件档位', style: TextStyle(fontSize: 12)),
              // mine + browsing（web：mine && !browsing 才显示「我在其中」）
              _Stage(
                viewport: const Size(320, 150),
                label: 'browsing 语境：mine 也走按钮「查看语音房」',
                child: AylaVoiceChannelList(
                  channels: <AylaVoiceCardData>[_channels[5]],
                  columns: 1,
                  padding: EdgeInsets.zero,
                  browsing: true,
                  onJoin: _joined,
                ),
              ),
              _Stage(
                viewport: const Size(320, 150),
                label: 'joining：卡片 .7 + 按钮禁用（.55）+「加入中…」',
                child: AylaVoiceChannelList(
                  channels: <AylaVoiceCardData>[_channels.first],
                  columns: 1,
                  padding: EdgeInsets.zero,
                  joining: true,
                  onJoin: _joined,
                ),
              ),
              _Stage(
                viewport: const Size(320, 150),
                label: '空态：.voice-list-empty + placeholder 两行',
                child: const AylaVoiceChannelList(
                  channels: <AylaVoiceCardData>[],
                ),
              ),
              _Stage(
                viewport: const Size(320, 140),
                label: '控制条：离开频道 + ${_rejoinVisible ? '重新加入（livekit=failed）' : '（无重入钮）'}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    AylaVoiceControls(
                      showRejoin: _rejoinVisible,
                      onLeave: () => setState(() => _rejoinVisible = false),
                      onRejoin: () => setState(() => _rejoinVisible = true),
                    ),
                    const SizedBox(height: AylaSpacing.sp2),
                    GlassButton(
                      label: _rejoinVisible ? '模拟：连接恢复' : '模拟：连接失败',
                      variant: GlassButtonVariant.ghost,
                      minHeight: 32,
                      fontSize: 12,
                      onPressed: () =>
                          setState(() => _rejoinVisible = !_rejoinVisible),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台（与 A3/A4/A5 样张同纪律：断点/网格都读 `MediaQuery` 视口）。
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
              child: SingleChildScrollView(child: child),
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

/// 语音频道族（卡片 / 列表 / 控制条）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '语音频道族（卡片 + 网格列表 + 控制条）',
  size: Size(1700, 900),
  wrapper: previewTheme,
)
Widget aylaVoiceChannelPreview() => aylaVoiceChannelSamples();
