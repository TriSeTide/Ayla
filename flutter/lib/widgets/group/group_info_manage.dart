/// 群信息**右列卡头 / 区块标题 / 危险操作**（web `pages/group/GroupInfo.tsx` +
/// `styles/group.css`；2026-09-28 收尾轮第 1 批 B2 三件）。
///
/// ## 事实源（tsx 结构 + CSS 逐条）
/// ```
/// 【区块标题】GroupInfo.tsx:523–526（<h3 class="group-info-section-title"><IconMenu 18/>{管理|更多}</h3>）
///   group.css 1610–1623  flex · align-items center · gap sp2 · font-display 17px / w500 / --text-primary ·
///                         margin-bottom sp3 · svg ⇒ --text-secondary
///
/// 【卡头】GroupInfo.tsx:651–663（子群：IconGrid 18 + 标题「子群」+ 计数 + 「编辑子群」ghost）
///        GroupInfo.tsx:748–752（成员：IconUsers 18 + 标题「成员」+ 计数 + 「已载入成员在线 {N}」）
///   group.css 1626–1643  .group-info-card-head：flex · center · gap sp2 · margin-bottom sp3
///                        .group-info-card-icon：--text-secondary · flex none
///                        .group-info-card-title：font-display 17 / w500 / --text-primary
///   group.css 1645–1658  .group-info-count：min-width 20 · height 20 · padding 0 6 · radius pill ·
///                        bg rgba(157,191,230,.32)（= --ice-500 @32%）· --indigo-700 ·
///                        font-utility 11 / w500 / line-height 20 · text-align center · flex none
///   group.css 1660–1675  .group-info-online：margin-left auto · inline-flex · center · gap 5px ·
///                        12px · --text-secondary · ::before 6×6 圆 --success
///   group.css 2100–2107  .group-info-head-action：margin-left auto · min-height 30 · padding 2 12 ·
///                        12px · radius pill · flex none（ghost 档）
///
/// 【危险操作】GroupInfo.tsx:627–645（owner：转让群主 ghost + 解散群聊 destructive；
///            非 owner：退出群聊 destructive）——**逐键 busy/disabled 语义不同**，见该类头注
///   group.css 2050–2054  .group-info-danger：column · gap sp2
///   group.css 2056–2059  .group-info-action-row：width 100% · min-height 40
///   app.css 21–36        .btn：inline-flex · center · gap sp2 · min-h 40 · padding 0 sp6 ·
///                        radius-input · 14px / w700 / ls .2px
/// ```
///
/// ## 公开面
/// `AylaGroupInfoSectionTitle` · `AylaGroupInfoCardHead` · `AylaGroupInfoDangerActions` ·
/// `aylaGroupInfoManageSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 区块标题（`.group-info-section-title`，group.css 1610–1623；GroupInfo.tsx:523–526）。
class AylaGroupInfoSectionTitle extends StatelessWidget {
  const AylaGroupInfoSectionTitle({
    super.key,
    required this.title,
    this.icon,
  });

  /// 标题文案（web「管理」/「更多」）。
  final String title;

  /// 前置图标（web `IconMenu width={18} height={18}`；null ⇒ 不渲染）。
  final AylaIconData? icon;

  /// ⚠️ 本件**恒为** `margin-bottom: var(--sp-3)`（group.css 1618）——web 没有第二档。
  /// 宿主 `.group-info-manage` 另带 `gap: var(--sp-3)`（1790–1794），flex 的 gap
  /// **不吸收** margin ⇒ 标题与首个相邻块的间距在 web 上就是 12 + 12 = 24，
  /// 本页保持同一合成结果（2026-10-02 实测 24）。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp3), // margin-bottom: sp3
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            AylaIcon(
              icon!,
              size: 18,
              color: AylaColors.textSecondary, // svg { color: --text-secondary }
            ),
            const SizedBox(width: AylaSpacing.sp2), // gap: sp2
          ],
          Semantics(
            // web：<h3 class="group-info-section-title">（GroupInfo.tsx:523）
            header: true,
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片头（`.group-info-card-head` + `-card-icon` / `-card-title` / `-count` / `-online` /
/// `-head-action`，group.css 1626–1675 / 2100–2107；GroupInfo.tsx:651–663 / 748–752）。
class AylaGroupInfoCardHead extends StatelessWidget {
  const AylaGroupInfoCardHead({
    super.key,
    required this.title,
    this.icon,
    this.count,
    this.onlineCount,
    this.actionLabel,
    this.onAction,
    this.actionSemanticLabel,
  });

  /// 标题（web「子群」/「成员」）。
  final String title;

  /// 前置图标 18（web `IconGrid` / `IconUsers`；null ⇒ 不渲染）。
  final AylaIconData? icon;

  /// 计数胶囊（web `{subgroupPage.total}` / `{memberPage.total}`；null ⇒ 不渲染）。
  final int? count;

  /// 「已载入成员在线 {N}」（web 仅成员卡传；null ⇒ 不渲染，带 6×6 --success 圆点）。
  final int? onlineCount;

  /// 头部动作文案（web 子群卡 canManage && !subgroupEditing ⇒「编辑子群」；null ⇒ 不渲染）。
  final String? actionLabel;

  /// 头部动作回调。
  final VoidCallback? onAction;

  /// 头部动作 aria-label（web `aria-label="编辑子群"`）。
  final String? actionSemanticLabel;

  /// 标题锚点（测试/画布用；页面里「子群」「成员」各一个）。
  ///
  /// ⚠️ 不要用 `find.text('子群')`：资料卡的统计格也有同名文案（`GroupInfo.tsx:506`）。
  static Key titleKey(String title) =>
      ValueKey<String>('ayla-group-info-card-title-$title');

  /// ⚠️ 本件**恒为** `margin-bottom: var(--sp-3)`（group.css 1630）——web 没有第二档，
  /// 子群卡与成员卡都用它；卡内其余块间距各自来自 `<p>` 的归零（base.css 316–326）
  /// 与 `.group-info-expand-btn { margin-top: sp2 }`（group.css 2112），不在这里叠。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp3), // margin-bottom: sp3
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            AylaIcon(
              icon!,
              size: 18,
              color: AylaColors.textSecondary, // .group-info-card-icon
            ),
            const SizedBox(width: AylaSpacing.sp2), // gap: sp2
          ],
          Semantics(
            // web：<h3 class="group-info-card-title">（GroupInfo.tsx:653 / 750）
            header: true,
            child: Text(
              title,
              key: titleKey(title),
              style: const TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          if (count != null) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp2),
            _CountPill(value: count!),
          ],
          // .group-info-online 与 .group-info-head-action 都是 margin-left:auto（推右）；
          // 两处 web 调用互斥（子群卡出动作、成员卡出在线），不会同时出现。
          if (actionLabel != null) ...<Widget>[
            const Spacer(), // margin-left: auto
            AylaGlassButton(
              label: actionLabel!,
              variant: AylaGlassButtonVariant.ghost,
              // .group-info-head-action：min-height 30 / padding 2 12 / font-size 12 / pill
              minHeight: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              fontSize: 12,
              borderRadius: AylaRadii.rPill, // radius pill（API 传 double）

              semanticLabel: actionSemanticLabel ?? actionLabel,
              onPressed: onAction,
            ),
          ] else if (onlineCount != null) ...<Widget>[
            const Spacer(), // margin-left: auto
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // ::before { width/height 6 · radius 50% · background --success }
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AylaColors.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5), // gap: 5px
                Text(
                  '已载入成员在线 $onlineCount',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 计数胶囊（`.group-info-count`，group.css 1645–1658）。
class _CountPill extends StatelessWidget {
  const _CountPill({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20), // min-width: 20px
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6), // padding: 0 6px
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AylaColors.ice500.withValues(alpha: 0.32), // rgba(157,191,230,.32)
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        '$value',
        style: const TextStyle(
          fontFamily: AylaFonts.utility,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AylaColors.indigo700,
          height: 1, // line-height: 20px（整颗胶囊高）由 height + center 表达
        ),
      ),
    );
  }
}

/// 危险操作 / 退出（`.group-info-danger` + `.group-info-action-row`，group.css 2050–2059；
/// GroupInfo.tsx:628–645）。
///
/// 三个回调都是**可选**，语义与 web 的条件渲染一一对应：
/// `onTransfer` 非空 ⇒ 出「转让群主」（owner 档）；`onDissolve` 非空 ⇒ 出「解散群聊」（owner 档）；
/// `onLeave` 非空 ⇒ 出「退出群聊」（非 owner 档）。`busy` ⇒ 全部禁用 + 文案转「解散中…」/「退出中…」。
class AylaGroupInfoDangerActions extends StatelessWidget {
  const AylaGroupInfoDangerActions({
    super.key,
    this.onTransfer,
    this.onDissolve,
    this.dissolveBusy = false,
    this.onLeave,
    this.leaveBusy = false,
    this.anyActionBusy = false,
  });

  /// 「转让群主」回调（web `setTransferOpen(true)`）。
  ///
  /// ⚠️ web 该键**没有 disabled**（tsx:629–631 只有 onClick）⇒ 本件同样不禁用。
  final VoidCallback? onTransfer;

  /// 「解散群聊」回调（web `setConfirmAction({kind:'dissolve'})`）。
  ///
  /// ⚠️ web 该键**没有 disabled**，只有文案切换（tsx:632–634）。
  final VoidCallback? onDissolve;

  /// 解散进行中（web `busyAction === "dissolve"` ⇒ 文案「解散中…」）。
  final bool dissolveBusy;

  /// 「退出群聊」回调（web `setConfirmAction({kind:'leave'})`；非 owner 档）。
  final VoidCallback? onLeave;

  /// 退出进行中（web `busyAction === "leave"` ⇒ 文案「退出中…」）。
  final bool leaveBusy;

  /// 是否有**任意**管理动作在途（web `busyAction !== null`）。
  ///
  /// ⚠️ 只作用在「退出群聊」上（tsx:641 的 `disabled={busyAction !== null}`）——
  /// 转让 / 解散两键 web 不因此禁用（2026-09-28 独立审计更正了此前「一键 busy 全禁」的写法）。
  final bool anyActionBusy;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[
      if (onTransfer != null)
        AylaGlassButton(
          label: '转让群主',
          variant: AylaGlassButtonVariant.ghost,
          minHeight: 40,
          expand: true, // .group-info-action-row { width: 100% }
          onPressed: onTransfer, // web 无 disabled
        ),
      if (onDissolve != null)
        AylaGlassButton(
          label: dissolveBusy ? '解散中…' : '解散群聊', // web: busyAction === 'dissolve'（只切文案）
          variant: AylaGlassButtonVariant.destructive,
          minHeight: 40,
          expand: true,
          onPressed: onDissolve, // web 无 disabled
        ),
      if (onLeave != null)
        AylaGlassButton(
          label: leaveBusy ? '退出中…' : '退出群聊', // web: busyAction === 'leave'
          variant: AylaGlassButtonVariant.destructive,
          minHeight: 40,
          expand: true,
          // web：disabled={busyAction !== null} —— **任意**管理动作在途都禁用
          onPressed: anyActionBusy ? null : onLeave,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp2, // gap: sp2
      children: rows,
    );
  }
}

/// 画布样张（三件 × 各自档位）。
Widget aylaGroupInfoManageSamples() => const _GroupInfoManageDemo();

class _GroupInfoManageDemo extends StatefulWidget {
  const _GroupInfoManageDemo();

  @override
  State<_GroupInfoManageDemo> createState() => _GroupInfoManageDemoState();
}

class _GroupInfoManageDemoState extends State<_GroupInfoManageDemo> {
  bool _busy = false;
  String _last = '（未点击）';

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('① 区块标题（group.css 1610–1623 · GroupInfo.tsx:523–526）', style: t.body),
        const SizedBox(height: 8),
        AylaGroupInfoSectionTitle(
          title: '管理', // canManage 档
          icon: aylaIconByName('iconMenu'),
        ),
        AylaGroupInfoSectionTitle(
          title: '更多', // 非 canManage 档
          icon: aylaIconByName('iconMenu'),
        ),
        const SizedBox(height: 16),
        Text('② 卡片头（group.css 1626–1675 / 2100–2107）', style: t.body),
        const SizedBox(height: 8),
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 子群卡：图标 + 标题 + 计数 + 「编辑子群」ghost（GroupInfo.tsx:651–663）
              AylaGroupInfoCardHead(
                title: '子群',
                icon: aylaIconByName('iconGrid'),
                count: 6,
                actionLabel: '编辑子群',
                actionSemanticLabel: '编辑子群',
                onAction: () => setState(() => _last = '点了「编辑子群」'),
              ),
              // 成员卡：图标 + 标题 + 计数 + 「已载入成员在线 N」（GroupInfo.tsx:748–752）
              AylaGroupInfoCardHead(
                title: '成员',
                icon: aylaIconByName('iconUsers'),
                count: 128,
                onlineCount: 12,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('③ 危险操作（group.css 2050–2059 · GroupInfo.tsx:628–645）', style: t.body),
        const SizedBox(height: 8),
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('owner 档（转让群主 + 解散群聊）', style: t.caption),
              const SizedBox(height: 6),
              AylaGroupInfoDangerActions(
                dissolveBusy: _busy,
                anyActionBusy: _busy,
                onTransfer: () => setState(() => _last = '点了「转让群主」'),
                onDissolve: () => setState(() => _last = '点了「解散群聊」'),
              ),
              const SizedBox(height: 16),
              Text('非 owner 档（退出群聊）', style: t.caption),
              const SizedBox(height: 6),
              AylaGroupInfoDangerActions(
                leaveBusy: _busy,
                anyActionBusy: _busy,
                onLeave: () => setState(() => _last = '点了「退出群聊」'),
              ),
              const SizedBox(height: 16),
              Text('busy 档（解散/退出切文案；只有「退出群聊」禁用 —— web 逐键不同）', style: t.caption),
              const SizedBox(height: 6),
              AylaGroupInfoDangerActions(
                dissolveBusy: true,
                leaveBusy: true,
                anyActionBusy: true,
                onTransfer: () {},
                onDissolve: () {},
                onLeave: () {},
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  AylaGlassButton(
                    label: _busy ? '恢复可点' : '切到 busy',
                    variant: AylaGlassButtonVariant.ghost,
                    minHeight: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    fontSize: 12,
                    borderRadius: AylaRadii.rPill,
                    onPressed: () => setState(() => _busy = !_busy),
                  ),
                  const SizedBox(width: 12),
                  Text('回调记录：$_last', style: t.caption),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
