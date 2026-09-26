/// B5 group 域第一批（1/2）：添加 / 编辑子群弹窗。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ── SubGroupDialog.tsx 18–110：结构 = overlay > dialog > head + 名称输入 + 禁言开关（仅 edit）
/// + 错误 + 按钮排
/// ── group.css 2131–2144：.subgroup-dialog-overlay —— fixed inset · z 60 · flex 居中 ·
/// padding sp4 · 遮罩 rgba(70,91,146,.18) + backdrop-filter blur(3px)
/// ── group.css 2146–2159：.subgroup-dialog —— width min(360px, 100%) · flex column ·
/// gap sp4 · padding sp6 · radius panel 20 · glass-bg-strong · blur24 sat1.4 · 1px 边 ·
/// glass-shadow-modal
/// ── group.css 2161–2172：.subgroup-dialog-head —— flex space-between（无 margin-bottom，
/// 间距由容器 gap 提供）；title display 18 / w500
/// ── tsx 51–53：关闭键 .icon-btn-40 + IconClose 18（disabled=busy）
/// ── tsx 55–63：input.field —— hint「子群群名」· aria-label 同 · maxLength 64 · autoFocus
/// ── group.css 2180–2215：.subgroup-dialog-mute —— row gap sp3 · padding sp3 · radius-input ·
/// 底 rgba(255,250,251,.6) · 1px 边；checkbox 18×18 accent glow-500；
/// copy 两行（title 14/w700 · desc 12/secondary · gap 2）
/// ── group.css 2174–2177：.subgroup-dialog-error —— 13px · destructive
/// ── group.css 2217–2231：.subgroup-dialog-actions —— flex · justify-end · gap sp2 · nowrap；
/// .btn { white-space: nowrap; min-width 72 }；.btn-destructive { margin-right: auto }（删除键靠左）
/// ── tsx 80–105：删除（仅 edit 且非默认组）/ 取消（ghost）/ 确定（primary）
/// ── tsx 34–37：初始名 = edit 的当前名；初始禁言 = edit 的 muted ?? false；
/// canDelete = edit && !is_default
/// ── tsx 98–104：空名拦截（trim 后为空直接 return，不发请求）；busy →「保存中…」
///
/// ## 与 web 的装配差异
/// web 在组件内直接调 chatApi（create / update / delete），并把「删除二次确认」交给调用方
/// （ChannelSidebar.tsx:588–601 渲染 AylaConfirmDialog + 文案「确定删除子群「…」？该子群的所有
/// 聊天记录将永久删除，无法恢复。」）。Flutter 侧沿用注入范式：组件只负责表单状态 / 校验 /
/// busy / 错误展示，请求与二次确认由调用方在 [onConfirm] / [onDelete] 里完成。
///
/// ## 一处有意偏离
/// web 的 .subgroup-dialog 未声明 max-height / overflow（内容高时直接溢出屏幕）；
/// Flutter 侧走 [AylaModalCard] 的默认兜底（80vh + 内部滚动），避免小屏把按钮挤出可视区。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;

import '../../core/models/subgroup.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart' show AylaIconButton;
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/dialogs.dart' show AylaModalCard, AylaModalOverlay;
import '../base/directory_controls.dart' show AylaCheckbox;

/// 弹窗状态（web SubGroupDialogState：add | edit | null）。
///
/// Flutter 侧用「[subgroup] 为 null 即 add 态」表达；整体不打开弹窗由调用方决定是否挂载本组件。
class AylaSubGroupDialogState {
  /// 添加态。
  const AylaSubGroupDialogState.add() : subgroup = null;

  /// 编辑态（预填 [subgroup] 的名称与禁言开关）。
  const AylaSubGroupDialogState.edit(AylaSubGroup this.subgroup);

  /// 编辑态的子群；null = 添加态。
  final AylaSubGroup? subgroup;

  /// 是否编辑态。
  bool get isEdit => subgroup != null;
}

/// .subgroup-dialog —— 添加 / 编辑子群弹窗（SubGroupDialog.tsx）。
class AylaSubGroupDialog extends StatefulWidget {
  const AylaSubGroupDialog({
    super.key,
    required this.state,
    required this.onClose,
    required this.onConfirm,
    this.onDelete,
    this.busy = false,
    this.error,
  });

  /// 弹窗状态（add / edit）。
  final AylaSubGroupDialogState state;

  /// 关闭（点遮罩 / 关闭键 / 取消）。busy 时组件内部已拦截，不会调用。
  final VoidCallback onClose;

  /// 确定：edit 态第二参数为禁言开关当前值（add 态为 null）。
  final void Function(String name, bool? muted) onConfirm;

  /// 删除（仅 edit 且非默认组可见）；二次确认由调用方负责。
  final VoidCallback? onDelete;

  /// 请求进行中。
  final bool busy;

  /// 错误文案（调用方注入）。
  final String? error;

  /// tsx 61：maxLength = 64。
  static const int nameMaxLength = 64;

  /// tsx 60：占位与 aria-label 同文案。
  static const String namePlaceholder = '子群群名';

  @override
  State<AylaSubGroupDialog> createState() => _AylaSubGroupDialogState();
}

class _AylaSubGroupDialogState extends State<AylaSubGroupDialog> {
  late final TextEditingController _name;
  late bool _muted;

  /// tsx 36：isEdit。
  bool get _isEdit => widget.state.isEdit;

  /// tsx 37：canDelete = isEdit && !sg.is_default。
  bool get _canDelete => _isEdit && !(widget.state.subgroup!.isDefault);

  @override
  void initState() {
    super.initState();
    final AylaSubGroup? sg = widget.state.subgroup;
    _name = TextEditingController(text: sg?.name ?? ''); // tsx 34
    _muted = sg?.muted ?? false; // tsx 35：旧后端缺省按未禁言
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// tsx 97–104：空名直接 return（不发请求）。
  void _confirm() {
    final String trimmed = _name.text.trim();
    if (trimmed.isEmpty) return;
    widget.onConfirm(trimmed, _isEdit ? _muted : null);
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    return AylaModalOverlay(
      // tsx 42：busy 时遮罩不可关闭
      onDismiss: widget.busy ? null : widget.onClose,
      padding: AylaSpacing.sp4, // .subgroup-dialog-overlay { padding: var(--sp-4) }
      // 两档都居中（web 无窄屏媒体查询）；遮罩 .18 + blur(3px)
      centerBoth: true,
      maskColor: const Color(0x2E465B92), // rgba(70,91,146,.18)
      maskBlur: 3,
      child: AylaModalCard(
        cardMaxWidth: 360, // width: min(360px, 100%)
        narrowCentered: true, // 窄屏同形（全圆角 + 四边边框）
        padding: const EdgeInsets.all(AylaSpacing.sp6), // padding: var(--sp-6)
        scrollable: false, // web 无 overflow-y（见文件头「有意偏离」）
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp4, // gap: var(--sp-4)
          children: <Widget>[
            _head(),
            // input.field（auroraqua 502–531：radius-input 12 / glass-bg / inset / blur24）
            AylaGlassInput(
              controller: _name,
              hintText: AylaSubGroupDialog.namePlaceholder,
              semanticLabel: AylaSubGroupDialog.namePlaceholder,
              autofocus: true, // tsx 62
              // ⚠️ 必须随文本 setState：确定键的可用性由 _name.text 决定，
              //    漏掉这一步会出现「输入了名字按钮仍禁用」（chat 域 MessageInput 的真实事故）。
              onChanged: (_) => setState(() {}),
              inputFormatters: <TextInputFormatter>[
                // tsx 61：用 formatter 表达 64 上限（maxLength 会多出计数器）
                LengthLimitingTextInputFormatter(
                  AylaSubGroupDialog.nameMaxLength,
                ),
              ],
            ),
            if (_isEdit) _muteRow(t), // tsx 64–77：仅编辑态
            if ((widget.error ?? '').isNotEmpty)
              Text(
                widget.error!,
                // .subgroup-dialog-error { font-size: 13px; color: var(--destructive) }
                style: t.body.copyWith(
                  fontSize: 13,
                  color: AylaColors.destructive,
                ),
              ),
            _actions(),
          ],
        ),
      ),
    );
  }

  /// .subgroup-dialog-head：标题 + 关闭键（无 margin-bottom，间距由容器 gap 给）。
  Widget _head() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _isEdit ? '编辑子群' : '添加子群', // tsx 50
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AylaFonts.display, // --font-display
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 18,
              fontWeight: FontWeight.w500, // w500（不是 create-sheet-title 的 w600）
              color: AylaColors.textPrimary,
            ),
          ),
        ),
        AylaIconButton(
          // .icon-btn-40 + IconClose 18（tsx 51–53）
          icon: AylaIcon(aylaIconByName('iconClose')!, size: 18),
          onPressed: widget.busy ? null : widget.onClose,
          semanticLabel: '关闭',
        ),
      ],
    );
  }

  /// .subgroup-dialog-mute：整行可点（web 是 label 包 checkbox）。
  Widget _muteRow(AylaTextStyles t) {
    return GestureDetector(
      onTap: widget.busy ? null : () => setState(() => _muted = !_muted),
      child: Container(
        padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
        decoration: BoxDecoration(
          color: const Color(0x99FFFAFB), // rgba(255,250,251,.6)
          borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius-input
          border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
        ),
        child: Row(
          spacing: AylaSpacing.sp3, // gap: var(--sp-3)
          children: <Widget>[
            AylaCheckbox(
              checked: _muted,
              size: 18, // .subgroup-dialog-mute input 18×18（visibility selector 是 16）
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2, // gap: 2px
                children: <Widget>[
                  Text(
                    '禁言该子群', // tsx 73
                    style: t.body.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AylaColors.textPrimary,
                    ),
                  ),
                  Text(
                    '开启后仅群主/管理员可发言', // tsx 74
                    style: t.body.copyWith(
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
    );
  }

  /// .subgroup-dialog-actions：删除靠左（margin-right auto），取消/确定靠右，等宽 72。
  Widget _actions() {
    return Row(
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        if (_isEdit)
          AylaGlassButton(
            label: '删除', // tsx 88
            variant: AylaGlassButtonVariant.destructive,
            minWidth: 72, // .subgroup-dialog-actions .btn { min-width: 72px }
            // disabled = busy || !canDelete；不可删时给出「默认组不可删除」语义
            onPressed: (widget.busy || !_canDelete) ? null : widget.onDelete,
            semanticLabel: _canDelete ? '删除' : '默认组不可删除',
          ),
        const Spacer(), // .btn-destructive { margin-right: auto }
        AylaGlassButton(
          label: '取消', // tsx 92
          variant: AylaGlassButtonVariant.ghost,
          minWidth: 72,
          onPressed: widget.busy ? null : widget.onClose,
        ),
        AylaGlassButton(
          label: widget.busy ? '保存中…' : '确定', // tsx 104
          variant: AylaGlassButtonVariant.primary,
          minWidth: 72,
          // disabled = busy || !name.trim()（输入变化要重建 ⇒ 见 build 里的 controller 监听）
          onPressed: (widget.busy || _name.text.trim().isEmpty)
              ? null
              : _confirm,
        ),
      ],
    );
  }
}

// ======================= 样张 =======================

/// 子群弹窗样张。
///
/// 三档：添加（空名 ⇒ 确定禁用）· 编辑（预填名 + 禁言行 + 删除键靠左）· 编辑+错误（默认组
/// 时删除键禁用，语义「默认组不可删除」）。
Widget aylaSubGroupDialogSamples() => const _SubGroupDialogDemo();

class _SubGroupDialogDemo extends StatefulWidget {
  const _SubGroupDialogDemo();

  @override
  State<_SubGroupDialogDemo> createState() => _SubGroupDialogDemoState();
}

class _SubGroupDialogDemoState extends State<_SubGroupDialogDemo> {
  String _log = '—';
  bool _busy = false;

  static const AylaSubGroup _custom = AylaSubGroup(
    id: 's1',
    conversationId: 'g1',
    name: '深夜组',
    isDefault: false,
    unreadCount: 3,
    muted: true,
  );
  static const AylaSubGroup _defaultGroup = AylaSubGroup(
    id: 's0',
    conversationId: 'g1',
    name: '默认组',
    isDefault: true,
    unreadCount: 0,
  );

  Widget _stage(String label, double width, double height, Widget child) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 11)),
          SizedBox(
            width: width,
            height: height,
            // 不裁圆角：弹窗样张的遮罩要铺满舞台（否则四角露背景）
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: Size(width, height)),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        Text('最近操作：$_log', style: const TextStyle(fontSize: 12)),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp3,
          children: <Widget>[
            AylaGlassButton(
              label: _busy ? 'busy：开' : 'busy：关',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 32,
              fontSize: 12,
              onPressed: () => setState(() => _busy = !_busy),
            ),
          ],
        ),
        Wrap(
          spacing: AylaSpacing.sp6,
          runSpacing: AylaSpacing.sp6,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _stage(
              '添加子群（宽屏 400 · 空名 ⇒ 确定禁用）',
              400,
              420,
              AylaSubGroupDialog(
                state: const AylaSubGroupDialogState.add(),
                busy: _busy,
                error: _busy ? '创建失败：请稍后重试' : null,
                onClose: () => setState(() => _log = '关闭（添加）'),
                onConfirm: (String name, bool? muted) =>
                    setState(() => _log = '添加 name=$name'),
              ),
            ),
            _stage(
              '编辑子群（窄屏 375 · 预填名 + 禁言行 + 删除靠左）',
              375,
              520,
              AylaSubGroupDialog(
                state: const AylaSubGroupDialogState.edit(_custom),
                busy: _busy,
                onClose: () => setState(() => _log = '关闭（编辑）'),
                onConfirm: (String name, bool? muted) =>
                    setState(() => _log = '保存 name=$name muted=$muted'),
                onDelete: () => setState(() => _log = '删除（调用方二次确认）'),
              ),
            ),
            _stage(
              '编辑默认组（删除键禁用 · 语义「默认组不可删除」）',
              400,
              460,
              AylaSubGroupDialog(
                state: const AylaSubGroupDialogState.edit(_defaultGroup),
                onClose: () => setState(() => _log = '关闭（默认组）'),
                onConfirm: (String name, bool? muted) =>
                    setState(() => _log = '保存 name=$name muted=$muted'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
