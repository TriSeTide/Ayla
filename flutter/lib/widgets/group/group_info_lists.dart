/// AylaGroupInfoLayout / AylaGroupSubgroupList / AylaGroupMemberList
/// —— 群信息页「右列两卡 + 两列布局」三件（19 号 §7.5 range B/C 第 ③ 批，2026-09-28 收尾轮）。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构；落盘前已按 skill 第 1 条 grep 全部命中）
/// ```
/// ── ① 两列布局 ───────────────────────────────────────────────────────────
/// group.css 1422–1427  .group-info-layout：display grid · grid-template-columns minmax(0,1fr) ·
///                      gap sp3(12) · align-items start
/// group.css 1429–1435  .group-info-side / .group-info-main：flex column · gap sp3 · min-width 0
/// group.css 1437       .group-info-main { container-type: inline-size }
///                      （Flutter 无 container query ⇒ LayoutBuilder 把主列 inline-size 下发，
///                        见 _AylaGroupInfoMainContainer）
/// group.css 1439–1452  @media (min-width: 769px)：grid-template-columns
///                      clamp(280px, 32%, 340px) minmax(0,1fr) · gap sp4(16) · side/main gap sp4 ·
///                      子项 flex-shrink 0
/// group.css 1454–1459  @media (min-width:769px) and (max-width:1000px)：
///                      **退回 grid-template-columns minmax(0,1fr)**（原文注释：两条导航轨
///                      留给详情列的空间太窄）
/// group.css 1393–1401  ≥769：.group-info-layout { flex: none }（滚动归整页 .group-info）
/// group.css 1461–1465  .group-info-loading：padding sp4(16) · display flex · flex-direction column
/// GroupInfo.tsx 401–405 加载档内容 = 三个 .skeleton（height 64 · 前两个 margin-bottom 8）
/// auroraqua.css 324–332  ≥769：side → auroraqua-sidebar-in（−20px x 淡入）·
///                      main → auroraqua-panel-from-right（+20px x 淡入），300ms ease-out
/// auroraqua.css 429–434  ≤768：side / main 都 → auroraqua-panel-from-bottom（+20px y 淡入）
/// auroraqua.css 8–26     四个 @keyframes 本体（位移 20 / 透明度 0→1）
/// auroraqua.css 614–629 / 631–653  reduced-motion 两段：animation none + translate none + opacity 1
///
/// ── ② 子群列表 ───────────────────────────────────────────────────────────
/// group.css 1690–1695  .group-info-subgroup-list：flex column · gap sp1(4)
/// group.css 1697–1705  .group-info-subgroup：flex · align-items center · gap sp3 ·
///                      padding sp2 sp3 · radius-input(12) · transition background 180ms --ease-out
/// group.css 1707–1710  :hover ⇒ background rgba(157,191,230,.14)（= --ice-500 @14%）
/// group.css 1712–1722  .group-info-subgroup-name：flex 1 · min-width 0 · 14 · w600 ·
///                      --text-primary · 单行省略（overflow hidden + ellipsis + nowrap）
/// group.css 1734–1745  .group-info-role(-owner)：pill · padding 1px 8px · Fredoka 11 ·
///                      owner = --sakura-300 底 + --grape-700 字（库内 AylaGroupRoleChip）
/// GroupInfo.tsx 680    默认组 chip：className「group-info-role group-info-role-owner」· 文案「默认组」
/// group.css 2062–2067  .group-info-subgroup-muted：font-size 11 · w700 · --text-secondary
/// group.css 318–331    ⚠️ **同名类的前一条命中**（三者共用视觉「灰底小字」）：padding 1px 6px ·
///                      radius pill · background --ice-300 · font-family Display · line-height 1.4 ·
///                      white-space nowrap。2062 只覆写 font-size / font-weight / color，
///                      其余声明**仍然生效**（同特异性、后加载者逐属性胜出）⇒ 本件按合并结果实现。
/// GroupInfo.tsx 681–685 禁言 chip：条件 sg.muted === true · 文案「禁言」·
///                      title「已禁言（仅群主/管理员可发言）」（库内 AylaTooltip）
/// group.css 2069–2081  .group-info-subgroup-badge：min-width 16 · height 16 · padding 0 4 · pill ·
///                      --pink-500 底 · #fffafb 字 · Fredoka 11 · line-height 16px · flex none
/// GroupInfo.tsx 686–690 unread > 0 才出 · >99 ⇒「99+」· aria-label「{n} 条未读」（n 用原值）
/// group.css 2083–2093  .group-info-subgroup-edit-btn：32×32 · inline-flex 居中 · radius-input ·
///                      --text-secondary · transition background/color 180ms --ease-out
/// group.css 2095–2098  :hover ⇒ background rgba(157,191,230,.18) + color --text-primary
/// GroupInfo.tsx 691–704 条件 subgroupEditing && canManage · aria-label「编辑子群 {name}」·
///                      title「编辑子群」
/// GroupInfo.tsx 1012–1018 图标 = **tsx 内联 SVG 铅笔**（path
///                      M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z · 14px）——不在 icons.tsx
///                      （全仓仅 ChannelSidebar.tsx:624 与 GroupInfo.tsx:1015 两处内联）
/// group.css 2118–2128  .group-info-subgroup-edit-actions：flex · gap sp2(8) · margin-top sp3(12)；
///                      > .btn { flex 1 · min-height 36 · font-size 13 }
/// GroupInfo.tsx 722–744 primary「+ 添加子群」（IconPlus 16）/ ghost「完成」·
///                      aria-label 分别「添加子群」「完成子群编辑」
/// group.css 1684–1687  .group-info-placeholder：13px · --text-secondary
/// GroupInfo.tsx 670–671 空态三档逐字：loading「加载中…」/ error「子群加载失败」/ 否则「暂无子群」
///
/// ── ③ 成员列表 ───────────────────────────────────────────────────────────
/// group.css 1690–1695 / 1697–1710  列表 gap sp1；行 flex · center · gap sp3 · padding sp2 sp3 ·
///                      radius-input · hover --ice-500 @14%
/// GroupInfo.tsx 761–768 头像：size 窄屏 36 / 宽屏 40 · online · imageUrl · onClick 进个人主页 ·
///                      ariaLabel「查看 {名字} 的个人主页」（库内 AylaAvatarHalo）
///                      ⚠️ isNarrow = NARROW_QUERY「(max-width: 768px)」（hooks/useMediaQuery.ts:13）
/// group.css 1712–1722  .group-info-member-name：14 · w600 · --text-primary · 单行省略；
///                      GroupInfo.tsx 769 另带 title={名字}
/// group.css 1724–1732  .group-info-me：padding 1px 8px · pill · rgba(249,176,255,.28)
///                      （--sakura-300 @28%）· Fredoka 11 · --grape-700 ·
///                      GroupInfo.tsx 770 条件 m.user.id === currentUser?.id · 文案「我」
/// group.css 1734–1750 / GroupInfo.tsx 771–775  角色 chip（role !== "member" 才出 · ROLE_LABEL）
/// group.css 1752–1759  .group-info-member-actions：flex · center · gap sp2 · flex none ·
///                      transition opacity 180ms --ease-out
/// group.css 1761–1770  ≥769 ⇒ opacity 0；行 :hover / :focus-within ⇒ opacity 1（窄屏常显）
/// group.css 1772–1777  .group-info-member-actions .btn：min-height 30 · padding 2px 12px ·
///                      font-size 12 · radius pill
/// GroupInfo.tsx 776–787 渲染条件 canManage && 非自己 && role !== owner；
///                      isOwner ⇒ role === "admin" ? 「撤销管理员」: 「设为管理员」；「移除」
///                      （busyAction === remove-{id} ⇒「移除中…」）；busyAction !== null ⇒ 全部 disabled
/// group.css 1780–1787  @container (max-width: 420px)：行 flex-wrap · 操作区 width 100% ·
///                      justify-content flex-end · opacity 1
///                      ⚠️ 容器 = .group-info-main（1437 的 container-type），**不是卡片**；而卡片
///                      自身 padding sp4（1678–1682）⇒ 卡内量到的可用宽 = 容器宽 − 32 ⇒
///                      判据必须把卡内距「加回」再比 420 —— 见 wrapThreshold 的注释。
/// group.css 1684–1687 / GroupInfo.tsx 755–756  空态三档：「加载中…」/「成员加载失败」/
///                      否则「没有匹配的成员」
/// ```
///
/// ## 层叠核查（全部命中已逐条读过）
/// - `.group-info-layout` / `-side` / `-main` 只被 auroraqua.css 324–332 / 429–434 / 614–653
///   **命中动效**（未覆写几何）；group.css 1398 的 `flex: none` 是页面滚动档。
/// - `.group-info-subgroup*` / `-member*` / `-me` / `-role*` / `-placeholder` 在 auroraqua.css
///   **零命中**。
/// - `.group-info-subgroup-muted` 的两条命中见上（318 与 2062 合并生效）。
///
/// ## 有意偏离（逐条带依据）
/// 1. **容器查询 → LayoutBuilder**：Flutter 3.47 无 `@container`。`@container (max-width: 420px)`
///    的判据用「主列 inline-size」（宿主 `AylaGroupInfoLayout` 下发，精确等价）；脱离宿主时退回
///    「自身可用宽 + 卡内距 ×2」。两者取同一阈值 420，见 [AylaGroupMemberList.wrapThreshold]。
/// 2. **CSS `grid` → Row + SizedBox**：两列宽度按 `clamp(280, 32%, 340)` 显式算出（CSS 百分比
///    基数 = 网格容器内容宽，Flutter 用 LayoutBuilder 的 maxWidth，同基数）。
///    `min-width: 0` 的等价物 = 给子件**有界宽度**（SizedBox），不再由内容撑开。
/// 3. **`> * { flex-shrink: 0 }`（1450–1451）为 no-op**：Flutter 的 Column 子件默认不收缩
///    （除非用 Flexible/Expanded），本件不写「反例保护」。
/// 4. **进场动效**用库内 `AylaRevealItem`（配方同 auroraqua 关键帧：位移 20 / 300ms / ease-out；
///    reduced-motion 时它自己就不播）——web 的 `animation` 无延迟，故 delay: Duration.zero。
///    ⚠️ 动效档由 **viewport** 决定（≥769 侧左入 / 主右入；≤768 都下入），与列数是两件事：
///    769–1000 虽然单列，动效仍是「左入 + 右入」。
/// 5. **编辑笔图标自绘**：`PencilIcon` 是 tsx 内联 SVG、不在 icons.tsx（`AylaIcon` 只能画图标表里的）。
///    库内先例 = `channel_sidebar.dart:2488–2570` 的私有 glyph（同 path，私有件）；本件另写一份
///    私有 painter，**未**把它提升为公共件（跨组件改动须先经用户裁决，登记为待裁决项）。
/// 6. **未读徽标复用 `AylaTabBadge`**：`.group-info-subgroup-badge` 与 `.server-item-badge` 逐条同值
///    （min 16 / height 16 / padding 0 4 / pill / --pink-500 / #fffafb / Display 11 / line-height 16px），
///    字重 w400 也对（group.css 未声明 font-weight，继承 body 默认 400）⇒ 直接用
///    [AylaTabBadgeMetrics.serverItem] + inline 档，**不新造档**。
/// 7. **操作区淡入用 `AnimatedOpacity`**：web 本体就是 `transition: opacity`（1752–1758）。opacity == 1
///    时 Flutter 不建层（`RenderOpacity` 直接画子件）⇒ 玻璃钮的 backdrop 不受影响；淡入的那 180ms
///    与 CSS 同样存在「祖先透明组使 backdrop 采样退化」的现象（两边语义一致，非偏差）。
///    ⚠️ 与本项目「禁用态禁止整层 Opacity」不冲突：禁用态走 [AylaGlassButton] 的**按颜色降透明**。
/// 8. **`:focus-within` 用 `FocusNode.descendants`**：row 自身挂一个 `canRequestFocus: false` 的
///    FocusNode，监听其 `hasFocus` 变化（框架在焦点路径差集上 `_notify`，见 focus_manager.dart
///    1990–2012）后按 `descendants.any(hasFocus)` 判定——等价 `:focus-within`。
///    `FocusNode.descendants` 在 3.47 可用（focus_manager.dart:715）。
/// 9. **可访问名的「独立节点」口径**：web 的 `aria-label` 是该元素节点上的可访问名；
///    Flutter 的 `Semantics(label:)` **默认会合并进祖先节点**（实测：按钮的 label 与文本并成
///    「添加子群\n添加子群」一行），于是 `find.bySemanticsLabel` 这类精确检索会落空。
///    本件自绘的两处（行内编辑键、未读徽标）显式 `container: true`（徽标另加
///    `excludeSemantics: true`，对齐 web「aria-label 覆盖元素内容」）；**复用件**
///    （AylaGlassButton / AylaAvatarHalo）的结构不改，其 label 会与文本合并、头像还带
///    「，在线/离线」后缀（avatar_halo.dart:310–316），测试按包含关系断言。
/// 10. ⚠️ **复用件的既有偏离（登记，未改）**：`group_role_chip.dart:56` 用 `t.timestamp`
///    ⇒ 角色 chip 实际是 **Space Grotesk**，而 web `.group-info-role` 是
///    `font-family: var(--font-display)` = Fredoka（group.css 1738）。本件被指定复用该件，
///    跨组件改动须先经用户裁决 ⇒ 保持现状并在测试里如实断言，作为待裁决项上报。
///
/// ## 公开面
/// `AylaGroupInfoLayout` · `AylaGroupSubgroupItem` · `AylaGroupSubgroupList` ·
/// `AylaGroupMemberItem` · `AylaGroupMemberList` · `aylaGroupInfoListsSamples`
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/svg_path.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/loading.dart' show AylaSkeleton;
import '../base/reveal.dart';
import '../base/tab_badge.dart';
import '../base/tooltip.dart';
import 'group_role_chip.dart';

/// ═══════════════════════════ ① 两列布局 ═══════════════════════════

/// 群信息页主布局：窄屏连续单列 / 宽屏两列（左「资料 + 管理」、右「子群 + 成员」）。
///
/// 事实源：group.css 1421–1459（几何与两档断点）+ 1454–1459（769–1000 退回单列）+
/// 1461–1465 与 GroupInfo.tsx 401–405（加载骨架档）+ auroraqua.css 324–332 / 429–434（进场动效）。
///
/// 几何速查（CSS px = Flutter 逻辑 px）：
/// - 单列：`grid-template-columns: minmax(0, 1fr)`，gap sp3；侧列/主列各自 gap sp3；
/// - ≥769 且 >1000：`clamp(280px, 32%, 340px) minmax(0, 1fr)`，gap sp4；两列各自 gap sp4；
/// - 769≤w≤1000：**退回单列**（两条导航轨 + 详情列太窄）。
class AylaGroupInfoLayout extends StatelessWidget {
  const AylaGroupInfoLayout({
    super.key,
    this.side = const <Widget>[],
    this.main = const <Widget>[],
    this.loading = false,
  });

  /// 左列（web `.group-info-side`：资料卡 + 管理卡，随整页连续滚动）。
  final List<Widget> side;

  /// 右列（web `.group-info-main`：子群卡 + 成员卡）。
  final List<Widget> main;

  /// 加载档（web `!conv && !loadError` 分支）：只渲染 `.group-info-loading` 骨架，不渲染两列。
  ///
  /// ⚠️ web 的失败档是 `.group-scene-placeholder`（role=alert + 重试键）⇒ 由
  /// `AylaGroupScenePlaceholder` 承担，本件不做。
  final bool loading;

  /// 左列锚点（测试/画布用；不要赌 find 的元素顺序）。
  static const Key sideKey = ValueKey<String>('ayla-group-info-side');

  /// 右列（主列）锚点。
  static const Key mainKey = ValueKey<String>('ayla-group-info-main');

  /// 加载骨架容器锚点。
  static const Key loadingKey = ValueKey<String>('ayla-group-info-loading');

  @override
  Widget build(BuildContext context) {
    if (loading) {
      // .group-info-loading：padding sp4 + flex column（1461–1465）
      return Padding(
        key: loadingKey,
        padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, // flex 默认 stretch
          children: <Widget>[
            // GroupInfo.tsx 402–404：三块 height 64，前两块 margin-bottom 8
            const Padding(
              padding: EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: AylaSkeleton(height: 64),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: AylaSkeleton(height: 64),
            ),
            const AylaSkeleton(height: 64),
          ],
        ),
      );
    }

    final double viewport = MediaQuery.sizeOf(context).width;
    // CSS：单列是默认档（1424）→ ≥769 两列（1441）→ 769–1000 又退回单列（1455）。
    final bool twoColumn = viewport >= 769 && viewport > 1000;
    final double columnGap = twoColumn
        ? AylaSpacing.sp4 // 1447：≥769 两列各自 gap sp4
        : AylaSpacing.sp3; // 1433：单列档 gap sp3

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 无界宽（横向滚动宿主等）只可能是宿主问题：退回单列，避免 SizedBox(width: ∞)。
        // 工程硬约束（非视觉规则），web 无对应声明。
        final double available = c.hasBoundedWidth ? c.maxWidth : 0;
        final double sideWidth = twoColumn
            ? (available * 0.32).clamp(280.0, 340.0) // clamp(280px, 32%, 340px)
            : available; // 单列：grid 单列铺满
        final double mainWidth = twoColumn
            ? math.max(0, available - sideWidth - AylaSpacing.sp4) // 减去网格 gap sp4
            : available;

        final Widget sideColumn = _column(
          key: sideKey,
          width: twoColumn ? sideWidth : null,
          gap: columnGap,
          children: side,
          entering: _entering(context, viewport, isSide: true),
        );
        final Widget mainColumn = _column(
          key: mainKey,
          width: twoColumn ? mainWidth : null,
          gap: columnGap,
          children: main,
          entering: _entering(context, viewport, isSide: false),
          containerWidth: mainWidth, // container-type: inline-size 的等价下发
        );

        if (!twoColumn) {
          // 单列：两个 grid 行（align-items: start ⇒ 各自自然高度，不互相拉伸）
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: columnGap, // 单列档网格 gap 仍是 sp3（1425）
            children: <Widget>[sideColumn, mainColumn],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start, // align-items: start
          children: <Widget>[
            sideColumn,
            const SizedBox(width: AylaSpacing.sp4), // gap: var(--sp-4)
            mainColumn,
          ],
        );
      },
    );
  }

  /// 单列（`.group-info-side` / `-main`）：flex column · gap 档 · 子件横向铺满（stretch）。
  Widget _column({
    required Key key,
    required double? width,
    required double gap,
    required List<Widget> children,
    required AylaRevealItem Function(Widget) entering,
    double? containerWidth,
  }) {
    Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: gap,
      children: children,
    );
    if (containerWidth != null) {
      column = _AylaGroupInfoMainContainer(width: containerWidth, child: column);
    }
    return SizedBox(key: key, width: width, child: entering(column));
  }

  /// 进场动效包装（auroraqua 324–332 / 429–434）——见文件头「有意偏离 4」。
  AylaRevealItem Function(Widget) _entering(
    BuildContext context,
    double viewport, {
    required bool isSide,
  }) {
    final bool wide = viewport >= 769;
    final Offset offset = wide
        // auroraqua-sidebar-in（324–327）/ auroraqua-panel-from-right（329–332）
        ? (isSide
              ? const Offset(-AylaRevealMotion.distance, 0)
              : const Offset(AylaRevealMotion.distance, 0))
        // auroraqua-panel-from-bottom（429–434）
        : const Offset(0, AylaRevealMotion.distance);
    return (Widget child) => AylaRevealItem(
      enabled: !MediaQuery.disableAnimationsOf(context), // 614–653：reduced ⇒ animation none
      delay: Duration.zero, // web animation 无 delay（故不用 stagger）
      offset: offset,
      duration: AylaDurations.auroraqua, // --auroraqua-duration 300ms
      curve: AylaCurves.auroraquaEaseOut, // var(--auroraqua-ease-out)
      child: child,
    );
  }
}

/// `.group-info-main { container-type: inline-size }`（group.css 1437）的 Flutter 等价。
///
/// 把**主列的 inline-size** 下发给子树，让 `@container (max-width: 420px)` 类判据
/// （1780–1787，成员行换行档）拿到与 web 同一个「容器宽」，而不是各自量到的局部宽度。
class _AylaGroupInfoMainContainer extends InheritedWidget {
  const _AylaGroupInfoMainContainer({required this.width, required super.child});

  /// 主列可用宽（= `@container` 查询的 inline-size）。
  final double width;

  /// 取最近的主列宽（不在 `AylaGroupInfoLayout` 子树内时为 null）。
  static double? maybeWidthOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AylaGroupInfoMainContainer>()
      ?.width;

  @override
  bool updateShouldNotify(_AylaGroupInfoMainContainer oldWidget) =>
      width != oldWidget.width;
}

/// ═══════════════════════════ ② 子群列表 ═══════════════════════════

/// 子群行数据（web SubGroup 的展示投影：GroupInfo.tsx 675–706 读到的四个字段）。
class AylaGroupSubgroupItem {
  const AylaGroupSubgroupItem({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.muted = false,
    this.unread = 0,
  });

  /// 子群 id（web sg.id；行 key 与 busy 键都基于它）。
  final String id;

  /// 子群名（.group-info-subgroup-name，单行省略）。
  final String name;

  /// 默认组（web sg.is_default ⇒ 出「默认组」chip）。
  final bool isDefault;

  /// 禁言（web sg.muted === true ⇒ 出「禁言」chip + 提示）。
  final bool muted;

  /// 未读数（web unreadByKey[subgroupKey(groupId, sg.id)] ?? 0；>0 才出徽标）。
  final int unread;
}

/// 子群列表（web .group-info-subgroup-list + 行内三态 chip + 编辑档）。
///
/// 事实源：group.css 1690–1722 / 2062–2098 / 2118–2128 + 318–331（禁言 chip 合并档）+
/// 1734–1745（角色 chip）+ GroupInfo.tsx 670–744。
class AylaGroupSubgroupList extends StatelessWidget {
  const AylaGroupSubgroupList({
    super.key,
    required this.subgroups,
    this.loading = false,
    this.error = false,
    this.canManage = false,
    this.editing = false,
    this.onEdit,
    this.onAdd,
    this.onDone,
  });

  /// 子群列表（web subgroups；空数组时才出空态文案，与 web 的三元一致）。
  final List<AylaGroupSubgroupItem> subgroups;

  /// 加载中（web subgroupPage.loading）——只影响空态文案。
  final bool loading;

  /// 加载失败（web subgroupPage.error）——只影响空态文案。
  final bool error;

  /// 可管理（web canManage）——编辑键与编辑态两键的条件之一。
  final bool canManage;

  /// 编辑态（web subgroupEditing）——与 [canManage] 同时为真才出行内编辑键。
  final bool editing;

  /// 行内编辑键回调（web setSubgroupDialog({kind:'edit', sg})）。
  final void Function(AylaGroupSubgroupItem subgroup)? onEdit;

  /// 「+ 添加子群」（web setSubgroupDialog({kind:'add'})）。
  final VoidCallback? onAdd;

  /// 「完成」（web setSubgroupEditing(false)）。
  final VoidCallback? onDone;

  /// 行锚点（web key={sg.id} 的 Flutter 等价）。
  static Key rowKey(String subgroupId) =>
      ValueKey<String>('ayla-group-subgroup-$subgroupId');

  /// 行内编辑键锚点。
  static Key editButtonKey(String subgroupId) =>
      ValueKey<String>('ayla-group-subgroup-edit-$subgroupId');

  /// 编辑态两键容器锚点（.group-info-subgroup-edit-actions）。
  static const Key editActionsKey = ValueKey<String>(
    'ayla-group-subgroup-edit-actions',
  );

  /// 空态锚点（.group-info-placeholder）。
  static const Key placeholderKey = ValueKey<String>(
    'ayla-group-subgroup-placeholder',
  );

  /// 空态文案三档（GroupInfo.tsx:671，逐字）。
  String get _emptyLabel {
    if (loading) return '加载中…';
    if (error) return '子群加载失败';
    return '暂无子群';
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (subgroups.isEmpty)
          Text(
            key: placeholderKey,
            _emptyLabel,
            // .group-info-placeholder：13px + --text-secondary；web 未声明 line-height
            // ⇒ 继承 body 的 1.55（故不用 t.caption 的 1.45）
            style: t.body.copyWith(
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          )
        else
          // .group-info-subgroup-list：flex column + gap sp1（1691–1695）
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp1, // gap: var(--sp-1)
            children: <Widget>[
              for (final AylaGroupSubgroupItem sg in subgroups)
                _SubgroupRow(
                  key: rowKey(sg.id),
                  subgroup: sg,
                  showEditButton: editing && canManage,
                  onEdit: onEdit,
                ),
            ],
          ),
        // 编辑态两键在 web 里**在空态三元之外**（GroupInfo.tsx:722）⇒ 空列表时同样出现
        if (canManage && editing)
          Padding(
            // margin-top: var(--sp-3)（2119–2121）
            padding: const EdgeInsets.only(top: AylaSpacing.sp3),
            child: Row(
              key: editActionsKey,
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                // > .btn { flex: 1; min-height: 36px; font-size: 13px }（2124–2128）
                Expanded(
                  child: AylaGlassButton(
                    label: '添加子群', // GroupInfo.tsx:733
                    semanticLabel: '添加子群', // aria-label
                    variant: AylaGlassButtonVariant.primary,
                    icon: AylaIcon(
                      aylaIconByName('iconPlus')!,
                      size: 16, // <IconPlus width={16} height={16} />
                    ),
                    minHeight: 36,
                    fontSize: 13,
                    expand: true, // flex 1 ⇒ 玻璃底撑满分格
                    onPressed: onAdd,
                  ),
                ),
                Expanded(
                  child: AylaGlassButton(
                    label: '完成', // GroupInfo.tsx:741
                    semanticLabel: '完成子群编辑', // aria-label
                    variant: AylaGlassButtonVariant.ghost,
                    minHeight: 36,
                    fontSize: 13,
                    expand: true,
                    onPressed: onDone,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 子群行（.group-info-subgroup）。
class _SubgroupRow extends StatefulWidget {
  const _SubgroupRow({
    super.key,
    required this.subgroup,
    required this.showEditButton,
    required this.onEdit,
  });

  final AylaGroupSubgroupItem subgroup;
  final bool showEditButton;
  final void Function(AylaGroupSubgroupItem subgroup)? onEdit;

  @override
  State<_SubgroupRow> createState() => _SubgroupRowState();
}

class _SubgroupRowState extends State<_SubgroupRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaGroupSubgroupItem sg = widget.subgroup;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        // transition: background 180ms var(--ease-out)（1704）
        duration: AylaDurations.fast,
        curve: AylaCurves.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3, // padding: sp2 sp3
          vertical: AylaSpacing.sp2,
        ),
        decoration: BoxDecoration(
          // :hover ⇒ rgba(157,191,230,.14)（1709，= --ice-500 @14%）；静息无背景
          color: _hovered
              ? AylaColors.ice500.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius-input 12
        ),
        child: Row(
          spacing: AylaSpacing.sp3, // gap: var(--sp-3)
          children: <Widget>[
            // .group-info-subgroup-name：flex 1 · 14 / w600 / --text-primary · 单行省略
            Expanded(
              child: Text(
                sg.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: t.body.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
            if (sg.isDefault)
              // GroupInfo.tsx:680：.group-info-role.group-info-role-owner + 文案「默认组」
              const AylaGroupRoleChip(
                role: AylaGroupRole.owner,
                label: '默认组',
              ),
            if (sg.muted)
              AylaTooltip(
                // title「已禁言（仅群主/管理员可发言）」（GroupInfo.tsx:682）
                message: '已禁言（仅群主/管理员可发言）',
                child: const _MutedChip(),
              ),
            if (sg.unread > 0)
              Semantics(
                // aria-label「{n} 条未读」（GroupInfo.tsx:687）——n 是**原始**未读数，
                // 与可见文案（>99 ⇒ 99+）不同，两个值都要对。
                // container + excludeSemantics = web 的「aria-label 覆盖元素内容作为
                // 可访问名」：不加则 Flutter 会把 label 合并进祖先节点、徽标自身不可检索。
                container: true,
                excludeSemantics: true,
                label: '${sg.unread} 条未读',
                child: AylaTabBadge(
                  count: sg.unread,
                  max: 99,
                  metrics: AylaTabBadgeMetrics.serverItem,
                  placement: AylaTabBadgePlacement.inline,
                ),
              ),
            if (widget.showEditButton)
              _EditIconButton(
                key: AylaGroupSubgroupList.editButtonKey(sg.id),
                semanticLabel: '编辑子群 ${sg.name}', // aria-label
                onTap: widget.onEdit == null
                    ? null
                    : () => widget.onEdit!(sg),
              ),
          ],
        ),
      ),
    );
  }
}

/// 禁言 chip：.group-info-subgroup-muted（**两条命中合并**，见文件头）。
///
/// - group.css 318–331（共用视觉）：padding 1px 6px · radius pill · background --ice-300 ·
///   font-family Display · line-height 1.4 · nowrap；
/// - group.css 2062–2067（群信息档覆写）：font-size 11 · font-weight 700 · color --text-secondary。
class _MutedChip extends StatelessWidget {
  const _MutedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: const BoxDecoration(
        color: AylaColors.ice300, // background: var(--ice-300)（318–331 未被覆写）
        borderRadius: AylaRadii.pill,
      ),
      child: const Text(
        '禁言', // GroupInfo.tsx:683
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontFamily: AylaFonts.display, // font-family: var(--font-display)
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11, // 2064 覆写（原 10）
          fontWeight: FontWeight.w700, // 2065
          height: 1.4, // line-height: 1.4
          color: AylaColors.textSecondary, // 2066 覆写（原 --indigo-700）
        ),
      ),
    );
  }
}

/// 行内编辑键（.group-info-subgroup-edit-btn，32×32 / radius-input / 铅笔）
///
/// ⚠️ web **无 :focus-visible 规则**（2083–2098 只声明 background / color）⇒ 本件**不画焦点环**
/// （不凭经验添加样式）；键盘可达性仍保留（Enter / Space 触发，等价 web 的 button）。
class _EditIconButton extends StatefulWidget {
  const _EditIconButton({
    super.key,
    required this.semanticLabel,
    required this.onTap,
  });

  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  State<_EditIconButton> createState() => _EditIconButtonState();
}

class _EditIconButtonState extends State<_EditIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return AylaTooltip(
      message: '编辑子群', // title="编辑子群"（GroupInfo.tsx:700）
      child: Semantics(
        button: true, // web <button>
        container: true, // 独立按钮节点（默认会合并进祖先 ⇒ aria-label 不可检索）
        label: widget.semanticLabel, // aria-label
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Focus(
            // 键盘：web <button> 的 Enter / Space（无环，见类头注）
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final bool activate =
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space;
              if (!activate || widget.onTap == null) {
                return KeyEventResult.ignored;
              }
              widget.onTap!();
              return KeyEventResult.handled;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                // transition: background/color 180ms var(--ease-out)（2092）
                duration: AylaDurations.fast,
                curve: AylaCurves.easeOut,
                width: 32, // width: 32px
                height: 32, // height: 32px
                decoration: BoxDecoration(
                  // :hover ⇒ rgba(157,191,230,.18)（2096）；静息无背景
                  color: _hovered
                      ? AylaColors.ice500.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AylaRadii.rInput),
                ),
                child: Center(
                  child: _SubgroupPencilGlyph(
                    size: 14, // <svg width="14" height="14">
                    color: _hovered
                        ? AylaColors.textPrimary // :hover 换色（2097）
                        : AylaColors.textSecondary, // 静息色（2091）
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

/// 子群编辑笔图标（tsx 内联 SVG，**不在 icons.tsx**）。
///
/// 事实源 GroupInfo.tsx 1012–1018：
/// <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
/// strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"> 内含一条 path。
///
/// ⚠️ 与 channel_sidebar.dart:2530 的 _SidebarGlyph.pencil **同 path、同为私有件**：本件没有把它
/// 提升成公共 glyph（那会改动 channel_sidebar，属跨组件改动 ⇒ 登记为待裁决项，见文件头偏离 5）。
class _SubgroupPencilGlyph extends StatelessWidget {
  const _SubgroupPencilGlyph({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SubgroupPencilPainter(d: _pencilPath, color: color),
    );
  }
}

/// GroupInfo.tsx:1015 的 path 原文（与 ChannelSidebar.tsx:624 逐字相同）。
const String _pencilPath = 'M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z';

/// 单路径线性 glyph 绘制（按 size / 24 缩放 viewBox，同 icons.tsx 的 base() 属性）。
class _SubgroupPencilPainter extends CustomPainter {
  const _SubgroupPencilPainter({required this.d, required this.color});

  final String d;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24); // viewBox 0 0 24 24
    canvas.drawPath(
      aylaParseSvgPath(d),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 // stroke-width: 2
        ..strokeCap = StrokeCap.round // stroke-linecap: round
        ..strokeJoin = StrokeJoin.round // stroke-linejoin: round
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SubgroupPencilPainter oldDelegate) =>
      oldDelegate.d != d || oldDelegate.color != color;
}

/// ═══════════════════════════ ③ 成员列表 ═══════════════════════════

/// 成员行数据（web 成员行的展示投影：GroupInfo.tsx 759–788 读到的字段）。
class AylaGroupMemberItem {
  const AylaGroupMemberItem({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.online = false,
    this.role = AylaGroupRole.member,
    this.isSelf = false,
  });

  /// 用户 id（busy 键与行 key 基于它）。
  final String id;

  /// 展示名（web m.user.nickname || m.user.username）。
  final String name;

  /// 头像 URL（web m.user.avatar || null）。
  final String? avatarUrl;

  /// 在线（web presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user))）。
  final bool online;

  /// 角色（web m.role）。
  final AylaGroupRole role;

  /// 是否当前用户（web m.user.id === currentUser?.id）。
  final bool isSelf;
}

/// 成员列表（web .group-info-member-list + 「我」chip + 角色 chip + 操作区）。
///
/// 事实源：group.css 1690–1732 / 1752–1787 + GroupInfo.tsx 755–790。
class AylaGroupMemberList extends StatelessWidget {
  const AylaGroupMemberList({
    super.key,
    required this.members,
    this.loading = false,
    this.error = false,
    this.canManage = false,
    this.isOwner = false,
    this.busyAction,
    this.onSetRole,
    this.onRemove,
    this.onOpenProfile,
    this.cardPadding = AylaSpacing.sp4,
  });

  /// 成员列表（web members；空数组时才出空态文案）。
  final List<AylaGroupMemberItem> members;

  /// 加载中（web memberPage.loading）——只影响空态文案。
  final bool loading;

  /// 加载失败（web memberPage.error）——只影响空态文案。
  final bool error;

  /// 可管理（web canManage = isOwner || isAdmin）——操作区条件之一。
  final bool canManage;

  /// 群主（web isOwner）——决定操作区里是否有「设为/撤销管理员」。
  final bool isOwner;

  /// 进行中的管理动作键（web busyAction）：[roleActionKey] / [removeActionKey] 之一；
  /// 非 null ⇒ 操作区两键全部 disabled（GroupInfo.tsx:779/783）。
  final String? busyAction;

  /// 角色切换回调（web chatApi.setMemberRole(groupId, id, role === 'admin' ? 'member' : 'admin')）。
  final void Function(AylaGroupMemberItem member)? onSetRole;

  /// 移除成员回调（web chatApi.removeMember(groupId, id)）。
  final void Function(AylaGroupMemberItem member)? onRemove;

  /// 点头像进个人主页（web goUserProfile(currentUser?.id, m.user.id)）。
  final void Function(AylaGroupMemberItem member)? onOpenProfile;

  /// 卡片内距（默认 sp4 = .group-info-members { padding: var(--sp-4) }，group.css 1678–1682）。
  ///
  /// ⚠️ 只用于 @container 判据的**换算**：容器是列而不是卡（见 [wrapThreshold]）。
  final double cardPadding;

  /// @container (max-width: 420px) 阈值（group.css 1780）。
  ///
  /// ⚠️ **换算关系**：容器 = .group-info-main（1437 的 container-type: inline-size），而卡片
  /// 自身有 padding sp4（1678–1682）⇒ 在卡内量到的可用宽 = 容器宽 − 32。故判据是
  /// 「(卡内可用宽 + [cardPadding]×2) ≤ 420」，**不是**「卡内宽 ≤ 420」。
  /// 宿主是 [AylaGroupInfoLayout] 时直接取它下发的**容器宽**（精确等价，无需换算）。
  static const double wrapThreshold = 420;

  /// 行锚点（web key={m.id} 的 Flutter 等价）。
  static Key rowKey(String memberId) =>
      ValueKey<String>('ayla-group-member-$memberId');

  /// 操作区锚点（.group-info-member-actions）。
  static Key actionsKey(String memberId) =>
      ValueKey<String>('ayla-group-member-actions-$memberId');

  /// 空态锚点（.group-info-placeholder）。
  static const Key placeholderKey = ValueKey<String>(
    'ayla-group-member-placeholder',
  );

  /// web busyAction 的角色键：role-${m.user.id}（GroupInfo.tsx:779）。
  static String roleActionKey(String memberId) => 'role-$memberId';

  /// web busyAction 的移除键：remove-${m.user.id}（GroupInfo.tsx:783）。
  static String removeActionKey(String memberId) => 'remove-$memberId';

  /// 空态文案三档（GroupInfo.tsx:756，逐字）。
  String get _emptyLabel {
    if (loading) return '加载中…';
    if (error) return '成员加载失败';
    return '没有匹配的成员';
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 主列容器宽（宿主下发；null ⇒ 本件自己量，见 wrapThreshold）。
    final double? containerWidth = _AylaGroupInfoMainContainer.maybeWidthOf(
      context,
    );
    final double viewport = MediaQuery.sizeOf(context).width; // NARROW_QUERY

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double probe = containerWidth ??
            (c.hasBoundedWidth ? c.maxWidth + cardPadding * 2 : double.infinity);
        final bool wrapActions = probe <= wrapThreshold;

        if (members.isEmpty) {
          return Text(
            key: placeholderKey,
            _emptyLabel,
            // .group-info-placeholder：13px + --text-secondary（web 未声明 line-height）
            style: t.body.copyWith(
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AylaSpacing.sp1, // gap: var(--sp-1)（1694）
          children: <Widget>[
            for (final AylaGroupMemberItem m in members)
              _MemberRow(
                key: rowKey(m.id),
                member: m,
                // GroupInfo.tsx:776：canManage && 非自己 && role !== "owner"
                showActions:
                    canManage && !m.isSelf && m.role != AylaGroupRole.owner,
                showRoleButton: isOwner, // GroupInfo.tsx:778
                busy: busyAction != null, // 两键同时禁用（779 / 783）
                removing: busyAction == removeActionKey(m.id), // 「移除中…」
                wrapActions: wrapActions,
                viewport: viewport,
                onSetRole: onSetRole,
                onRemove: onRemove,
                onOpenProfile: onOpenProfile,
              ),
          ],
        );
      },
    );
  }
}

/// 成员行（.group-info-member）。
class _MemberRow extends StatefulWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.showActions,
    required this.showRoleButton,
    required this.busy,
    required this.removing,
    required this.wrapActions,
    required this.viewport,
    required this.onSetRole,
    required this.onRemove,
    required this.onOpenProfile,
  });

  final AylaGroupMemberItem member;
  final bool showActions;
  final bool showRoleButton;
  final bool busy;
  final bool removing;
  final bool wrapActions;
  final double viewport;
  final void Function(AylaGroupMemberItem member)? onSetRole;
  final void Function(AylaGroupMemberItem member)? onRemove;
  final void Function(AylaGroupMemberItem member)? onOpenProfile;

  @override
  State<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends State<_MemberRow> {
  /// 行自身节点（canRequestFocus: false）：只用来承载 :focus-within 的判定。
  final FocusNode _rowFocus = FocusNode(
    debugLabel: 'ayla-group-member-row',
    canRequestFocus: false,
    skipTraversal: true,
  );

  bool _hovered = false;
  bool _focusWithin = false;

  @override
  void initState() {
    super.initState();
    // ⚠️ 必须监听**自身节点**：焦点进入后代时框架把祖先链上的节点标脏并 _notify
    // （focus_manager.dart 1990–2012），该节点的 hasFocus 由 false→true。
    _rowFocus.addListener(_syncFocusWithin);
  }

  @override
  void dispose() {
    _rowFocus
      ..removeListener(_syncFocusWithin)
      ..dispose();
    super.dispose();
  }

  /// :focus-within 等价：行自身或任一后代持有焦点（FocusNode.descendants，3.47 可用）。
  void _syncFocusWithin() {
    final bool within = _rowFocus.descendants.any(
      (FocusNode node) => node.hasFocus,
    );
    if (within != _focusWithin && mounted) {
      setState(() => _focusWithin = within);
    }
  }

  /// 操作区该不该可见（1761–1770 的 opacity 档 + 1782–1786 的换行档覆盖）。
  bool get _revealActions =>
      widget.wrapActions ||
      widget.viewport < 769 || // 窄屏常显（触摸无 hover）
      _hovered ||
      _focusWithin;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaGroupMemberItem m = widget.member;

    final List<Widget> leading = <Widget>[
      // Avatar：size 窄屏 36 / 宽屏 40（GroupInfo.tsx:761–768）
      AylaAvatarHalo(
        label: m.name,
        size: widget.viewport <= 768 ? 36 : 40, // NARROW_QUERY (max-width: 768px)
        online: m.online,
        resourceUrl: m.avatarUrl,
        semanticLabel: '查看 ${m.name} 的个人主页', // ariaLabel
        onTap: widget.onOpenProfile == null
            ? null
            : () => widget.onOpenProfile!(m),
      ),
      // .group-info-member-name：flex 1 · 14 / w600 / --text-primary · 单行省略；tsx 769 带 title
      Expanded(
        child: AylaTooltip(
          message: m.name, // title={m.user.nickname || m.user.username}
          child: Text(
            m.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: t.body.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AylaColors.textPrimary,
            ),
          ),
        ),
      ),
      if (m.isSelf) const _MeChip(), // GroupInfo.tsx:770
      if (m.role != AylaGroupRole.member)
        AylaGroupRoleChip(role: m.role), // GroupInfo.tsx:771–775
    ];
    final Widget? actions = widget.showActions ? _actions() : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        focusNode: _rowFocus,
        child: AnimatedContainer(
          // transition: background 180ms var(--ease-out)（1704）
          duration: AylaDurations.fast,
          curve: AylaCurves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3, // padding: sp2 sp3
            vertical: AylaSpacing.sp2,
          ),
          decoration: BoxDecoration(
            // :hover ⇒ rgba(157,191,230,.14)（1709）
            color: _hovered
                ? AylaColors.ice500.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: actions == null
              ? Row(spacing: AylaSpacing.sp3, children: leading)
              : widget.wrapActions
                  // @container (max-width: 420px)：行 flex-wrap（1781）+ 操作区
                  // width 100% / justify-content flex-end / opacity 1（1782–1786）
                  // ⇒ 第一行 = 头像 + 名字 + chip；第二行 = 操作区右对齐（行距 = gap sp3）
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(spacing: AylaSpacing.sp3, children: leading),
                        Padding(
                          // flex wrap 的行距（row-gap）= gap = sp3
                          padding: const EdgeInsets.only(top: AylaSpacing.sp3),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: actions,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      spacing: AylaSpacing.sp3,
                      children: <Widget>[...leading, actions],
                    ),
        ),
      ),
    );
  }

  /// 操作区（.group-info-member-actions，GroupInfo.tsx:776–787）。
  Widget _actions() {
    final AylaGroupMemberItem m = widget.member;
    final bool roleButtonEnabled = !widget.busy && widget.onSetRole != null;
    final bool removeButtonEnabled = !widget.busy && widget.onRemove != null;
    return AnimatedOpacity(
      key: AylaGroupMemberList.actionsKey(m.id),
      // transition: opacity 180ms var(--ease-out)（1758）；opacity == 1 时不建层
      duration: AylaDurations.fast,
      curve: AylaCurves.easeOut,
      opacity: _revealActions ? 1 : 0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)（1756）
        children: <Widget>[
          if (widget.showRoleButton)
            AylaGlassButton(
              // role === "admin" ? 「撤销管理员」: 「设为管理员」（GroupInfo.tsx:780）
              label: m.role == AylaGroupRole.admin ? '撤销管理员' : '设为管理员',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 30, // .group-info-member-actions .btn（1772–1777）
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              fontSize: 12,
              borderRadius: AylaRadii.rPill,
              onPressed: roleButtonEnabled ? () => widget.onSetRole!(m) : null,
            ),
          AylaGlassButton(
            label: widget.removing ? '移除中…' : '移除', // busyAction === remove-{id}
            variant: AylaGlassButtonVariant.ghost,
            minHeight: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            fontSize: 12,
            borderRadius: AylaRadii.rPill,
            onPressed: removeButtonEnabled
                ? () => widget.onRemove!(m)
                : null,
          ),
        ],
      ),
    );
  }
}

/// 「我」chip（.group-info-me，group.css 1724–1732 · GroupInfo.tsx:770）。
class _MeChip extends StatelessWidget {
  const _MeChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1), // 1px 8px
      decoration: BoxDecoration(
        // background: rgba(249,176,255,.28)（--sakura-300 @28%）
        color: AylaColors.sakura300.withValues(alpha: 0.28),
        borderRadius: AylaRadii.pill,
      ),
      child: const Text(
        '我', // GroupInfo.tsx:770
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          color: AylaColors.grape700,
        ),
      ),
    );
  }
}

/// ═══════════════════════════ 画布样张 ═══════════════════════════

/// 三件样张（布局四档 + 子群列表六档 + 成员列表五档）。
///
/// 数据是运行期输入 ⇒ 样张用库内既有示例文案（子群名沿用 group_chat_subgroup_bar 的示例）。
Widget aylaGroupInfoListsSamples() => const _GroupInfoListsSamples();

class _GroupInfoListsSamples extends StatefulWidget {
  const _GroupInfoListsSamples();

  @override
  State<_GroupInfoListsSamples> createState() => _GroupInfoListsSamplesState();
}

class _GroupInfoListsSamplesState extends State<_GroupInfoListsSamples> {
  static const List<AylaGroupSubgroupItem> _subgroups =
      <AylaGroupSubgroupItem>[
    AylaGroupSubgroupItem(id: 'all', name: '默认组', isDefault: true),
    AylaGroupSubgroupItem(id: 'sg-1', name: '星海观测站', unread: 3),
    AylaGroupSubgroupItem(id: 'sg-2', name: '深夜电台', muted: true),
    AylaGroupSubgroupItem(
      id: 'sg-3',
      name: '超长的子群名称用来验证单行省略',
      unread: 120,
    ),
  ];

  static const List<AylaGroupMemberItem> _members = <AylaGroupMemberItem>[
    AylaGroupMemberItem(
      id: 'u-self',
      name: '汐汐',
      online: true,
      isSelf: true,
    ),
    AylaGroupMemberItem(
      id: 'u-owner',
      name: '爱莉',
      online: true,
      role: AylaGroupRole.owner,
    ),
    AylaGroupMemberItem(
      id: 'u-admin',
      name: '管理员小樱',
      online: true,
      role: AylaGroupRole.admin,
    ),
    AylaGroupMemberItem(id: 'u-off', name: '离线成员'),
  ];

  bool _editing = false;
  bool _busy = false;
  String _last = '（未点击）';

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('① 两列布局（group.css 1421–1459 / 1461–1465）', style: t.body),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          '宽屏两列：视口 1440（MediaQuery 覆写）+ 内容宽 1120 ⇒ 左列取 340 上限、'
          '右列 = 1120 − 340 − sp4 = 764。横向滚动宿主只为画布不溢出，不是组件行为。',
          style: t.caption,
        ),
        const SizedBox(height: AylaSpacing.sp1),
        _hScroll(
          width: 1120,
          height: 560,
          child: _viewport(
            const Size(1440, 900),
            const AylaGroupInfoLayout(
              side: <Widget>[_SideSlotCard()],
              main: <Widget>[_SubgroupCardDemo(), _MemberCardDemo()],
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        Text(
          '左：视口 1440 + 内容宽 800 ⇒ 左列取 280 下限（clamp 下限档）· '
          '中：视口 900（769–1000）⇒ **退回单列** · 右：视口 375 ⇒ 窄屏单列',
          style: t.caption,
        ),
        const SizedBox(height: AylaSpacing.sp1),
        Wrap(
          spacing: AylaSpacing.sp4,
          runSpacing: AylaSpacing.sp4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _hScroll(
              width: 800,
              height: 400,
              child: _viewport(
                const Size(1440, 900),
                const AylaGroupInfoLayout(
                  side: <Widget>[_SideSlotCard()],
                  main: <Widget>[_SubgroupCardDemo()],
                ),
              ),
            ),
            _hScroll(
              width: 700,
              height: 400,
              child: _viewport(
                const Size(900, 900),
                const AylaGroupInfoLayout(
                  side: <Widget>[_SideSlotCard()],
                  main: <Widget>[_SubgroupCardDemo()],
                ),
              ),
            ),
            SizedBox(
              width: 375,
              child: _viewport(
                const Size(375, 900),
                const AylaGroupInfoLayout(
                  side: <Widget>[_SideSlotCard()],
                  main: <Widget>[_SubgroupCardDemo()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp4),
        Text(
          '加载档（.group-info-loading：padding sp4 + 三个 height 64 骨架，前两块 margin-bottom 8）',
          style: t.caption,
        ),
        const SizedBox(height: AylaSpacing.sp1),
        const SizedBox(width: 420, child: AylaGroupInfoLayout(loading: true)),

        const SizedBox(height: AylaSpacing.sp6),
        Text('② 子群列表（group.css 1690–1722 / 2062–2128）', style: t.body),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          '默认组 chip · 禁言 chip（悬停出「已禁言（仅群主/管理员可发言）」）· '
          '未读 120 ⇒ 可见「99+」且 aria-label「120 条未读」· 长名省略；'
          '第二张 = 编辑态（行内 32×32 铅笔 + primary「+ 添加子群」/ ghost「完成」，两键 flex 1 / min-h 36）',
          style: t.caption,
        ),
        const SizedBox(height: AylaSpacing.sp1),
        Wrap(
          spacing: AylaSpacing.sp4,
          runSpacing: AylaSpacing.sp4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _card(
              const AylaGroupSubgroupList(
                subgroups: _subgroups,
                canManage: true,
              ),
            ),
            _card(
              AylaGroupSubgroupList(
                subgroups: _subgroups,
                canManage: true,
                editing: _editing,
                onEdit: (AylaGroupSubgroupItem sg) =>
                    setState(() => _last = '编辑子群 ${sg.name}'),
                onAdd: () => setState(() => _last = '点了「添加子群」'),
                onDone: () => setState(() {
                  _editing = false;
                  _last = '点了「完成」';
                }),
              ),
            ),
            _card(
              const AylaGroupSubgroupList(
                subgroups: <AylaGroupSubgroupItem>[],
                loading: true,
              ),
            ),
            _card(
              const AylaGroupSubgroupList(
                subgroups: <AylaGroupSubgroupItem>[],
                error: true,
              ),
            ),
            _card(
              const AylaGroupSubgroupList(
                subgroups: <AylaGroupSubgroupItem>[],
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Row(
          spacing: AylaSpacing.sp3,
          children: <Widget>[
            AylaGlassButton(
              label: _editing ? '退出编辑态' : '进入编辑态',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              fontSize: 12,
              borderRadius: AylaRadii.rPill,
              onPressed: () => setState(() => _editing = !_editing),
            ),
            AylaGlassButton(
              label: _busy ? '解除 busy' : '切到 busy 档',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              fontSize: 12,
              borderRadius: AylaRadii.rPill,
              onPressed: () => setState(() => _busy = !_busy),
            ),
            Flexible(child: Text('回调记录：$_last', style: t.caption)),
          ],
        ),

        const SizedBox(height: AylaSpacing.sp6),
        Text('③ 成员列表（group.css 1690–1732 / 1752–1787）', style: t.body),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          '「我」chip · 角色 chip（owner / admin；member 不出）· 操作区（≥769 悬停或 focus-within '
          '淡入，窄屏常显）· 第二张 = 容器 ≤420 换行档（操作区独占一行右对齐）· '
          '第三张 = 非 canManage 档（无操作区）· 第四张 = 空态。busy 档见①下方的按钮。',
          style: t.caption,
        ),
        const SizedBox(height: AylaSpacing.sp1),
        Wrap(
          spacing: AylaSpacing.sp4,
          runSpacing: AylaSpacing.sp4,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            // 440 宽卡 ⇒ 容器宽 440 + 32 = 472 > 420 ⇒ 不换行（悬停看操作区淡入）
            _card(
              AylaGroupMemberList(
                members: _members,
                canManage: true,
                isOwner: true,
                busyAction: _busy
                    ? AylaGroupMemberList.removeActionKey('u-admin')
                    : null,
                onSetRole: (AylaGroupMemberItem m) =>
                    setState(() => _last = '切换角色 ${m.name}'),
                onRemove: (AylaGroupMemberItem m) =>
                    setState(() => _last = '移除 ${m.name}'),
                onOpenProfile: (AylaGroupMemberItem m) =>
                    setState(() => _last = '查看 ${m.name} 的主页'),
              ),
              width: 440,
            ),
            // 372 宽卡 ⇒ 容器宽 372 + 32 = 404 ≤ 420 ⇒ 换行档
            _card(
              const AylaGroupMemberList(
                members: _members,
                canManage: true,
                isOwner: true,
              ),
              width: 372,
            ),
            _card(
              const AylaGroupMemberList(members: _members),
              width: 440,
            ),
            _card(
              const AylaGroupMemberList(members: <AylaGroupMemberItem>[]),
              width: 440,
            ),
          ],
        ),
      ],
    );
  }

  /// 卡片（.group-info-subgroups / .group-info-members = solid-card + padding sp4）。
  Widget _card(Widget child, {double width = 420}) => SizedBox(
    width: width,
    child: AylaGlassCard(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: child,
    ),
  );

  /// 横向滚动宿主：画布可用宽 ~736，宽档几何样张必须**不撑破宿主**
  /// （skill「画布样张宽度自适应」条；这不是组件行为，只服务于画布）。
  Widget _hScroll({
    required double width,
    required double height,
    required Widget child,
  }) => SizedBox(
    height: height,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // 横向滚动宿主的**交叉轴是紧约束**（会被拉满 height）⇒ 用 Align 交还松约束，
      // 样张才按内容高度顶对齐；这是宿主行为，与组件无关。
      child: SizedBox(
        width: width,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );

  /// 覆写视口（画布宿主很宽/很窄都不代表真实页面视口）。
  Widget _viewport(Size size, Widget child) => Builder(
    builder: (BuildContext context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: size),
      child: child,
    ),
  );
}

/// 左列槽位占位卡：本件只做**两列装配**，资料卡 / 管理卡是另件（group_info_profile.dart /
/// group_info_manage.dart）。样张里如实标注，不冒充已交付件。
class _SideSlotCard extends StatelessWidget {
  const _SideSlotCard();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaGlassCard(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('左列槽位', style: t.cardTitle.copyWith(fontSize: 17)),
          const SizedBox(height: AylaSpacing.sp1),
          Text(
            '资料卡 / 管理卡由 AylaGroupInfoProfile / AylaGroupInfoManage 提供；'
            '本件只负责两列装配（clamp 280–340 / 769–1000 退回单列）。',
            style: t.caption.copyWith(color: AylaColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 子群卡（真实装配：卡头 + 列表）。
class _SubgroupCardDemo extends StatelessWidget {
  const _SubgroupCardDemo();

  @override
  Widget build(BuildContext context) {
    return AylaGlassCard(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: AylaGroupSubgroupList(
        subgroups: _GroupInfoListsSamplesState._subgroups,
        canManage: true,
      ),
    );
  }
}

/// 成员卡（真实装配：卡头 + 列表）。
class _MemberCardDemo extends StatelessWidget {
  const _MemberCardDemo();

  @override
  Widget build(BuildContext context) {
    return AylaGlassCard(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: const AylaGroupMemberList(
        members: _GroupInfoListsSamplesState._members,
        canManage: true,
        isOwner: true,
      ),
    );
  }
}
