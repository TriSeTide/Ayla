/// 转让群主弹窗（web `pages/group/GroupInfo.tsx:904–1010` 的 `TransferOwnerDialog` +
/// `styles/app.css 3894–4005`）。
///
/// ## 事实源
/// ```
/// app.css 3894–3903  .group-transfer-overlay：fixed inset 0 · z 70 · 居中 · padding sp4 ·
///                    background rgba(70,91,146,.25)（点遮罩关闭，busy 时不关）
/// app.css 3905–3910  .group-transfer-dialog：width min(480px, 100%) · max-height 80vh · 滚动 · padding sp4
///                    （+ `glass-card` ⇒ 玻璃材质）
/// tsx 925–938        role=dialog aria-label=转让群主；head：标题「转让群主」（Display 18/600）+ 关闭键
///                    （icon-btn-40 + IconClose 18，busy 时 disabled）；desc「选择一位群成员接任群主。
///                    转让后你将成为普通成员。」（13 / 1.6 / secondary / margin-bottom sp3）
/// app.css 3941–3954  .group-transfer-search：relative 一行；搜索图标 absolute left sp3（--text-secondary，
///                    pointer-events none）；`.field` **padding-left 34px**
/// app.css 3957–3966  .group-transfer-list：column · gap sp2 · **max-height 260px** · 滚动
/// app.css 3968–3982  .group-transfer-row：flex · gap sp3 · padding sp2 sp3 · radius-input ·
///                    hover rgba(157,191,230,.18) · is-selected rgba(157,191,230,.35)
/// app.css 3990–3998  .group-transfer-name：flex 1 · min-width 0 · 14/600/text-primary · 单行省略
/// app.css 4000–4004  .group-transfer-actions：justify-end · gap sp2 · margin-top sp3
/// tsx 947–987        行 = Avatar(36) + 名字 + **非 member 才出角色标签**；`aria-pressed` + `aria-label=转让给 {名}`；
///                    空态 `search-empty`「没有匹配的成员」；分页行内嵌 DirectoryLoadMore
///                    （`retainCompletedSpace={false}`）；已选提示「已选择：{名}」
/// tsx 991–1002       错误行 `.group-info-error`（**role=alert**）；动作：ghost「取消」+ primary
///                    「转让中… / 确认转让」（无选中或 busy ⇒ disabled）
/// ```
/// ⚠️ `.group-transfer-empty`（app.css 3933–3939）在 tsx **零使用 ⇒ 死声明，不复刻**（同类已见
/// `.search-more`）。空态实际走 `.search-empty`。
///
/// ## 公开面
/// `AylaTransferOwnerDialog`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import 'group_role_chip.dart';

/// 弹窗里的一名候选成员（页面把自己的成员模型映射进来）。
class AylaTransferMember {
  const AylaTransferMember({
    required this.id,
    required this.displayName,
    this.role = AylaGroupRole.member,
    this.avatarUrl,
    this.online = false,
  });

  /// 稳定 id（选中态按它比较）。
  final String id;

  /// 展示名（web `nickname || username`）。
  final String displayName;

  /// 角色（member 不显示标签）。
  final AylaGroupRole role;

  /// 头像。
  final String? avatarUrl;

  /// 在线状态。
  final bool online;
}

/// 转让群主弹窗：搜索 + 成员列表（单选）+ 取消/确认。
class AylaTransferOwnerDialog extends StatefulWidget {
  const AylaTransferOwnerDialog({
    super.key,
    required this.members,
    required this.selectedId,
    required this.query,
    this.onQueryChanged,
    this.onSelect,
    this.onConfirm,
    this.onClose,
    this.busy = false,
    this.loading = false,
    this.hasMore = false,
    this.error,
    this.pageError,
    this.onMore,
    this.title = '转让群主',
    this.desc = '选择一位群成员接任群主。转让后你将成为普通成员。',
    this.searchHint = '搜索成员昵称/用户名',
    this.emptyLabel = '没有匹配的成员',
    this.cancelLabel = '取消',
    this.confirmLabel = '确认转让',
    this.busyLabel = '转让中…',
  });

  /// 候选成员（web：已过滤掉 owner 自己与群主）。
  final List<AylaTransferMember> members;

  /// 当前选中（null ⇒ 未选，确认键 disabled）。
  final String? selectedId;

  /// 搜索词。
  final String query;

  /// 搜索词变化（web `setQuery`，由页面重新分页）。
  final ValueChanged<String>? onQueryChanged;

  /// 选中某位成员。
  final ValueChanged<AylaTransferMember>? onSelect;

  /// 确认转让。
  final ValueChanged<AylaTransferMember>? onConfirm;

  /// 关闭（取消 / 关闭键 / 点遮罩；busy 时不响应）。
  final VoidCallback? onClose;

  /// 转让进行中（两个按钮 disabled、文案换 [busyLabel]）。
  final bool busy;

  /// 列表加载中。
  final bool loading;

  /// 还有更多成员（显示分页行）。
  final bool hasMore;

  /// 转让失败文案（`role=alert` 行）。
  final String? error;

  /// 列表加载失败文案（分页行内）。
  final String? pageError;

  /// 加载更多。
  final VoidCallback? onMore;

  /// 文案（**默认 = web 原文**）。
  final String title;
  final String desc;
  final String searchHint;
  final String emptyLabel;
  final String cancelLabel;
  final String confirmLabel;
  final String busyLabel;

  /// 弹窗宽度上限（`width: min(480px, 100%)`）。
  static const double maxWidth = 480;

  /// 列表最大高度（`max-height: 260px`）。
  static const double listMaxHeight = 260;

  /// 搜索框左内距（`.group-transfer-search .field { padding-left: 34px }`）。
  static const double searchIndent = 34;

  @override
  State<AylaTransferOwnerDialog> createState() => _AylaTransferOwnerDialogState();
}

class _AylaTransferOwnerDialogState extends State<AylaTransferOwnerDialog> {
  /// 搜索框控制器（web 的 `query` 是组件内部 state；对外只报变化）。
  late final TextEditingController _query = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(AylaTransferOwnerDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部重置（如换群/清空）时同步；用户输入期间不打断光标
    if (oldWidget.query != widget.query && widget.query != _query.text) {
      _query.text = widget.query;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<AylaTransferMember> members = widget.members;
    final String? selectedId = widget.selectedId;
    final AylaTransferMember? selected = selectedId == null
        ? null
        : members.where((AylaTransferMember m) => m.id == selectedId).firstOrNull;
    final bool busy = widget.busy;
    final bool loading = widget.loading;
    final bool hasMore = widget.hasMore;
    final String? pageError = widget.pageError;
    final String? errorText = widget.error;
    final bool showPager = loading || pageError != null || hasMore;
    final VoidCallback? onClose = widget.onClose;
    return Semantics(
      // web：`role="dialog" aria-label="转让群主"`
      // ⚠️ Flutter 断言：`scopesRoute: true` 必须同时 `explicitChildNodes: true`
      explicitChildNodes: true,
      scopesRoute: true,
      namesRoute: true,
      label: widget.title,
      child: Container(
        color: const Color(0x40465B92), // rgba(70,91,146,.25)
        alignment: Alignment.center,
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: GestureDetector(
          // 点遮罩关闭（busy 时不关）
          onTap: busy ? null : onClose,
          child: GestureDetector(
            onTap: () {}, // 等价 `e.stopPropagation()`
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AylaTransferOwnerDialog.maxWidth),
              child: AylaGlassCard(
                padding: const EdgeInsets.all(AylaSpacing.sp4),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // ---- head ----
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            widget.title,
                            style: t.pageTitle.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AylaColors.textPrimary,
                            ),
                          ),
                          AylaIconButton(
                            icon: AylaIcon(aylaIconByName('iconClose')!, size: 18),
                            semanticLabel: '关闭',
                            onPressed: busy ? null : onClose,
                          ),
                        ],
                      ),
                      const SizedBox(height: AylaSpacing.sp3),
                      Text(
                        widget.desc,
                        style: t.label.copyWith(
                          fontSize: 13,
                          height: 1.6,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: AylaSpacing.sp3),
                      // ---- 搜索 ----
                      Stack(
                        alignment: Alignment.centerLeft,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(left: AylaSpacing.sp3),
                            child: AylaIcon(
                              aylaIconByName('iconSearch')!,
                              size: 15,
                              color: AylaColors.textSecondary,
                            ),
                          ),
                          AylaGlassInput(
                            controller: _query,
                            onChanged: widget.onQueryChanged,
                            hintText: widget.searchHint,
                            semanticLabel: '搜索成员',
                            padding: const EdgeInsets.only(left: AylaTransferOwnerDialog.searchIndent),
                          ),
                        ],
                      ),
                      const SizedBox(height: AylaSpacing.sp2),
                      // ---- 列表 ----
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: AylaTransferOwnerDialog.listMaxHeight),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            spacing: AylaSpacing.sp2,
                            children: <Widget>[
                              for (final AylaTransferMember m in members)
                                _Row(
                                  member: m,
                                  selected: m.id == selectedId,
                                  onTap: busy ? null : () => widget.onSelect?.call(m),
                                ),
                              if (!loading && pageError == null && members.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: AylaSpacing.sp6,
                                  ),
                                  child: Text(
                                    widget.emptyLabel,
                                    textAlign: TextAlign.center,
                                    style: t.label.copyWith(
                                      fontSize: 13,
                                      color: AylaColors.textSecondary,
                                    ),
                                  ),
                                ),
                              if (showPager)
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  spacing: AylaSpacing.sp2,
                                  children: <Widget>[
                                    if (pageError != null)
                                      Flexible(
                                        child: Text(
                                          pageError,
                                          style: t.label.copyWith(
                                            fontSize: 12,
                                            color: AylaColors.destructive,
                                          ),
                                        ),
                                      ),
                                    AylaGlassButton(
                                      label: loading
                                          ? '加载中…'
                                          : (pageError != null ? '重试' : '查看更多'),
                                      variant: AylaGlassButtonVariant.ghost,
                                      onPressed: loading ? null : widget.onMore,
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (selected != null) ...<Widget>[
                        const SizedBox(height: AylaSpacing.sp3),
                        Text(
                          '已选择：${selected.displayName}',
                          style: t.label.copyWith(
                            fontSize: 13,
                            color: AylaColors.textSecondary,
                          ),
                        ),
                      ],
                      if (errorText != null) ...<Widget>[
                        const SizedBox(height: AylaSpacing.sp2),
                        // web：`<p className="group-info-error" role="alert">`
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            errorText,
                            style: t.label.copyWith(color: AylaColors.destructive),
                          ),
                        ),
                      ],
                      const SizedBox(height: AylaSpacing.sp3),
                      // ---- 动作 ----
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        spacing: AylaSpacing.sp2,
                        children: <Widget>[
                          AylaGlassButton(
                            label: widget.cancelLabel,
                            variant: AylaGlassButtonVariant.ghost,
                            onPressed: busy ? null : onClose,
                          ),
                          AylaGlassButton(
                            label: busy ? widget.busyLabel : widget.confirmLabel,
                            onPressed: (selected == null || busy)
                                ? null
                                : () => widget.onConfirm?.call(selected),
                          ),
                        ],
                      ),
                    ],
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

/// 单行：头像 36 + 名字 + （非 member）角色标签。
class _Row extends StatelessWidget {
  const _Row({required this.member, required this.selected, this.onTap});

  final AylaTransferMember member;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Semantics(
      button: true,
      selected: selected, // aria-pressed
      label: '转让给 ${member.displayName}',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150), // --dur-fast / --ease-out
          curve: AylaCurves.auroraquaEaseOut,
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3,
            vertical: AylaSpacing.sp2,
          ),
          decoration: BoxDecoration(
            // hover rgba(157,191,230,.18) · is-selected rgba(157,191,230,.35)
            color: selected ? const Color(0x599DBFE6) : Colors.transparent,
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: Row(
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              AylaAvatarHalo(
                label: member.displayName,
                size: 36,
                online: member.online,
                resourceUrl: member.avatarUrl,
              ),
              Expanded(
                child: Text(
                  member.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
              AylaGroupRoleChip(role: member.role), // member ⇒ 不渲染
            ],
          ),
        ),
      ),
    );
  }
}
