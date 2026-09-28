/// 个人主页**编辑面**（web `pages/ProfilePage.tsx:212–305` + `styles/app.css 2696–2749` +
/// `styles/profile.css 47–51 / 377–440 / 593–596` + `styles/auth.css 79–87` + `styles/base.css 343–370`）。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// ProfilePage.tsx 22–27   STATUS_OPTIONS = auto 自动 / away 离开 / dnd 勿扰 / invisible 隐身
/// ProfilePage.tsx 212–232 「在线状态」行：div.profile-form-row > .status-chips[role=radiogroup][aria-label=在线状态]
///                         > button.status-chip[role=radio][aria-checked]（文案 = label）
/// app.css 2697–2701       .status-chips：display flex · flex-wrap wrap · gap sp2(8)
/// app.css 2703–2715       .status-chip：padding sp2 sp4(8×16) · radius pill · bg --sakura-300 · color --grape-700 ·
///                         font --font-display 11px / w500 / letter-spacing .8px / uppercase ·
///                         transition box-shadow+filter 180ms ease-out
/// app.css 2717–2719       .status-chip.active { box-shadow: var(--glow-shadow) }
/// app.css 2721–2723       .status-chip:hover { filter: brightness(1.04) }
/// profile.css 598–611     **覆盖** app.css（同特异性 0-1-0，profile.css 最后加载 ⇒ 胜出）：
///                           .status-chip { background: rgba(189,212,233,.16)（ice-300 @16%）· color --indigo-700 ·
///                             transition **四字段** background/color/box-shadow/filter 180ms ease-out }
///                           .status-chip.active { background --sakura-300 · color --grape-700 }
///                         （active 的 box-shadow 仍取 app.css 2717，profile.css 未覆写该属性）
/// base.css 366–370        :focus-visible { outline: var(--focus-ring)=glow-500 2px · outline-offset: 2px }
/// ⚠️ .status-chip **不在** auroraqua 按钮组（auroraqua.css 54–94 的 :is() 名单里同族只有 .search-chip）
///    ⇒ 无 hover 1.02 / active .98 / ::after 扫光 / 200ms 组过渡。
///
/// ProfilePage.tsx 261–278 「向他人展示内容」开关行：label.profile-form-row.profile-show-content-row
///                         > span.profile-show-content-label（文案 + <small> 副标题）
///                         + button.profile-switch[role=switch][aria-checked] > span.profile-switch-knob
/// app.css 2731–2738       .profile-form-row：column · gap sp1(4) · 14px / w700 / letter-spacing .2px
/// profile.css 378–383     .profile-show-content-row：**flex-direction: row** · align-items center ·
///                         justify-content space-between · gap sp3(12)
/// profile.css 385–397     .profile-show-content-label：column · gap 2px · 14 / w700 / --text-primary；
///                         small：12 / w400 / --text-secondary
/// profile.css 400–434     .profile-switch：relative · flex none · **48×28** · radius pill · 1px --glass-border ·
///                         background --glass-bg-strong（**无 backdrop-filter**）·
///                         transition background+box-shadow 180ms ease-out
///                         .profile-switch-knob：absolute top 3 / left 3 · 20×20 · pill · bg --ice-300 ·
///                         transition transform+background 180ms ease-out
///                         .profile-switch.is-on：bg --sakura-300 + --glow-shadow；
///                         .is-on .knob：transform translateX(20px)（⇒ left 3→23）+ bg --grape-700
///                         :focus-visible { outline --focus-ring · offset 2 }
/// base.css 6–7            * { box-sizing: border-box } ⇒ 48×28 含 1px 边框（与 Flutter 盒模型一致）
/// ⚠️ 开关行是 <label> 包住 <button>（HTML「label 转发点击」）⇒ 点整行都切换；Flutter 用「整行手势 +
///    开关本体 Focus」表达（本体不另挂手势，避免双重触发）。
///
/// ProfilePage.tsx 212–300 AylaProfileForm 装配（.profile-form 全块）
/// app.css 2725–2729       .profile-form：column · gap sp4(16)
/// profile.css 49          （≥769 且单栏 split）.profile-form { gap sp3 }
/// profile.css 121–128     （≥769 双栏侧栏）.profile-form { flex: 1 · gap **sp4** }（特异性更高，胜出）
///                         .profile-actions { margin-top: auto }（操作行沉底，本件由调用方布局）
/// app.css 2740–2744       .profile-actions：flex · gap sp3 · justify-content flex-end
/// profile.css 50          （≥769）.profile-actions { flex-wrap: wrap }
/// app.css 2746–2749       .profile-saved：13px · --success
/// ProfilePage.tsx 280–284 error ⇒ div.auth-error[role=alert]：auth.css 79–87 padding sp2 sp3 · radius-input ·
///                         bg rgba(214,77,110,.1) · 1px rgba(214,77,110,.35) · --destructive · 13px ·
///                         overflow-wrap anywhere
/// ProfilePage.tsx 286–304 .profile-actions：saved && !dirty ⇒「已保存」· primary「保存修改 / 保存中…」
///                         （disabled = saving || !dirty）· destructive「退出登录」（IconLogout 15）
/// app.css 2764–2771       .btn-destructive：bg --destructive · #fffafb · :hover brightness(1.06)
/// profile.css 437–440     .profile-logout-btn：min-height 36 · padding 0 sp4
/// app.css 70–88           .field（昵称 input / 签名 textarea）：width 100% · padding 12px 16px · radius-input ·
///                         1px --glass-border · bg --glass-bg（auroraqua 502–511 覆写并加 --glass-inset +
///                         blur24 saturate1.4）· focus ⇒ --glow-500 边 + --glow-shadow · ::placeholder --slate-500
/// base.css 350–353        input/textarea { font-family/size/weight/color: inherit } ⇒ 字段文字**继承行样式**
///                         14 / w700 / ls .2（本件按此传 textStyle，不是 .field 自己声明的）
/// profile.css 594–596     .profile-form textarea { resize: none }（⇒ Flutter maxLines 固定 + 无拖拽手柄）
/// base.css 343–346        button:disabled { cursor not-allowed · opacity .55 }
/// ```
///
/// ## 缩放口径
/// 本库为「web CSS px == Flutter 逻辑 px」（DPR 1.25 只影响物理像素，见 theme/aurora_background.dart:43–45）
/// ⇒ 上面所有 web 数值**原样**使用，不再乘 1.25。
///
/// ## 机制差异（有意偏离，登记）
/// ① .profile-actions 窄屏 nowrap / ≥769 wrap；Flutter 统一用 Wrap（对齐 flex-end + gap sp3）——
///    Flutter 的 Row 在窄屏溢出会直接抛错，而 Wrap 的换行只是「宽屏档多一种可能」，视觉同构。
/// ② 开关的「label 转发点击」由 Flutter「整行 GestureDetector + 本体 Focus/键盘」表达；
///    开关**本体不另挂 GestureDetector**（否则一次点击会被内外两层各触发一次 = 状态翻回原位）。
/// ③ <input type="file" hidden>（更换头像）属 AylaProfileAvatarActions（已交付，见 profile_card.dart）。
///
/// ## 公开面
/// AylaStatusOption · kAylaStatusOptions · AylaStatusChips · AylaProfileSwitch ·
/// AylaProfileFormRow · AylaProfileForm
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/switch.dart';

/// 在线状态选项（web ProfilePage.tsx:22–27 的 STATUS_OPTIONS）。
class AylaStatusOption {
  const AylaStatusOption({required this.value, required this.label});

  /// 值（web value）。
  final String value;

  /// 文案（web label）。
  final String label;
}

/// web STATUS_OPTIONS 的 1:1 投影（顺序同 web）。
const List<AylaStatusOption> kAylaStatusOptions = <AylaStatusOption>[
  AylaStatusOption(value: 'auto', label: '自动'),
  AylaStatusOption(value: 'away', label: '离开'),
  AylaStatusOption(value: 'dnd', label: '勿扰'),
  AylaStatusOption(value: 'invisible', label: '隐身'),
];

/// 在线状态单选胶囊组（.status-chips，ProfilePage.tsx:215–231）。
///
/// - 选中 = sakura-300 底 + grape-700 字 + --glow-shadow；
/// - 未选中 = ice-300 @16% 底 + indigo-700 字（**profile.css 覆写 app.css 的默认粉底**）；
/// - hover = brightness(1.04)（整颗胶囊含文字）；**不在 auroraqua 按钮组** ⇒ 无缩放/扫光。
class AylaStatusChips extends StatelessWidget {
  const AylaStatusChips({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = kAylaStatusOptions,
    this.semanticLabel = '在线状态',
    this.enabled = true,
  });

  /// 当前值（web status；null / 不在 [options] 里 ⇒ 四颗全未选中）。
  final String? value;

  /// 选中回调；[enabled] 为 false 时不响应。
  final ValueChanged<String> onChanged;

  /// 选项表（默认 [kAylaStatusOptions] = web 常量）。
  final List<AylaStatusOption> options;

  /// role="radiogroup" 的可访问名（web aria-label="在线状态"）。
  final String semanticLabel;

  /// 是否可用（web 该行**无禁用档**；本档留给调用方）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: Wrap(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        runSpacing: AylaSpacing.sp2, // flex-wrap: wrap（行距同 gap）
        children: <Widget>[
          for (final AylaStatusOption option in options)
            _StatusChip(
              label: option.label,
              selected: option.value == value,
              onTap: enabled ? () => onChanged(option.value) : null,
            ),
        ],
      ),
    );
  }
}

/// 单颗状态胶囊（button.status-chip[role=radio]）。
class _StatusChip extends StatefulWidget {
  const _StatusChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // ⚠️ 这里**不再**需要 `narrow`：`.status-chip.active` 的辉光窄屏不降档
    // （依据 `app.css:2717` + `3195–3199` 的选择器清单，见下方 boxShadow 注释）。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool enabled = widget.onTap != null;
    final bool hovered = _hovered && enabled;
    final Duration dur = reduceMotion ? Duration.zero : AylaDurations.fast;

    // .status-chip：padding sp2 sp4 · radius pill · Display 11 / w500 / ls .8
    // profile.css 600–607 覆写底色与字色（未选中 = ice-300 @16% + indigo-700）
    Widget chip = AnimatedContainer(
      duration: dur,
      curve: AylaCurves.easeOut,
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp2,
      ),
      decoration: BoxDecoration(
        color: widget.selected
            ? AylaColors.sakura300 // .status-chip.active background
            : AylaColors.ice300.withValues(alpha: 0.16), // rgba(189,212,233,.16)
        borderRadius: AylaRadii.pill,
        // `.status-chip.active { box-shadow: var(--glow-shadow) }`（`app.css:2717`）= **满档**：
        // ① `app.css:3195–3199` 的 ≤768 降档只列 `.btn-glow` / `.avatar-halo.is-elysia` /
        //    `.elysia-entry:hover`，**不含 status-chip**；② `profile.css:600–611` 只覆写底/字色与
        //    transition，**没有** box-shadow。
        // ⇒ 2026-09-28 订正：删掉 `narrow ? glowNarrow :` 分支（那是对「§9 通用说法」的错误套用），
        //   恒用满档。
        boxShadow: widget.selected ? AylaShadows.glow : null,
      ),
      child: Text(
        widget.label,
        style: t.microTag.copyWith(
          // display 11 / w500 / ls .8（microTag 即此档）
          color: widget.selected
              ? AylaColors.grape700 // .active color
              : AylaColors.indigo700, // profile.css 覆写色
        ),
      ),
    );

    // .status-chip:hover { filter: brightness(1.04) }：CSS filter = 通道乘法，
    // ColorFilter.matrix 等价（同 .btn-glow / .avatar-halo-btn 的先例）。
    if (hovered) {
      chip = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.04, 0, 0, 0, 0, //
          0, 1.04, 0, 0, 0, //
          0, 0, 1.04, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: chip,
      );
    }

    // :focus-visible { outline: var(--focus-ring) }（glow-500 / 2px / offset 2）。
    // 环画在形状之外（-4 = offset 2 + width 2），不参与布局；胶囊自身圆角仍是 pill
    // （.status-chip 的 radius-pill 与 base.css 的 :focus-visible border-radius 同特异性，
    //   但 app.css/profile.css 后加载 ⇒ pill 胜出）。
    Widget body = chip;
    if (_focused && enabled) {
      body = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: -4,
            top: -4,
            right: -4,
            bottom: -4,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AylaColors.glow500, width: 2),
                  borderRadius: BorderRadius.circular(AylaRadii.rPill + 2),
                ),
              ),
            ),
          ),
          chip,
        ],
      );
    }

    return Semantics(
      button: true,
      checked: widget.selected, // aria-checked
      inMutuallyExclusiveGroup: true, // role=radio
      label: widget.label,
      child: Focus(
        onFocusChange: (bool has) => setState(() => _focused = has),
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final bool activate =
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space;
          if (!activate || widget.onTap == null) return KeyEventResult.ignored;
          widget.onTap!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: body,
          ),
        ),
      ),
    );
  }
}

/// 「向他人展示内容」开关行（.profile-show-content-row + .profile-switch，
/// ProfilePage.tsx:261–278）。
///
/// 开关本体已提升为公共件 [AylaSwitch]（regular 档）——本件只负责「标签 + 副标题 + 控件」的整行装配。
/// 档位差异（与群信息域 AylaGroupInfoSwitch 的 compact 档）：本档 48×28 · --glass-bg-strong 底 +
/// 1px 亮边 · 选中 sakura-300 + 辉光 · 滑钮 ice-300 → grape-700；两处**共用同一实现**（2026-09-28 收尾轮）。
class AylaProfileSwitch extends StatefulWidget {
  const AylaProfileSwitch({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  /// 主文案（web「向他人展示内容」）。
  final String label;

  /// 副标题（web <small>；null ⇒ 不渲染）。
  final String? description;

  /// 开关值（aria-checked）。
  final bool value;

  /// 切换回调；null ⇒ 禁用档（web 无禁用；本档留给调用方）。
  final ValueChanged<bool>? onChanged;

  @override
  State<AylaProfileSwitch> createState() => _AylaProfileSwitchState();
}

class _AylaProfileSwitchState extends State<AylaProfileSwitch> {
  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? description = widget.description;

    // 开关本体 = 公共件 [AylaSwitch] 的 regular 档（个人档，事实源 profile.css 400–434：
    // 48×28 / 1px --glass-border / --glass-bg-strong（**无 backdrop-filter**）/
    // 选中 --sakura-300 + --glow-shadow（**窄屏不降档**：见 switch.dart 的注释与审计依据）/
    // knob 20 ice-300 → grape-700 /
    // :focus-visible --focus-ring）。
    // ⚠️ 1px 边框补偿（用户当场点名的「圆点没上下居中」）：见 switch.dart 库头。
    final Widget rail = AylaSwitch(
      value: widget.value,
      variant: AylaSwitchVariant.regular,
      // web 是 <label class="profile-form-row profile-show-content-row"> 包住 <button role=switch>
      // ⇒ 整行转发；本件整行挂手势，本体 ownTap: false（只保留 Focus 键盘）。
      ownTap: false,
      semanticLabel: widget.label,
      onChanged: widget.onChanged,
    );

    // .profile-show-content-row：row · center · space-between · gap sp3
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _enabled ? _toggle : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            // .profile-show-content-label：column · gap 2px · 14 / w700 / --text-primary
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: <Widget>[
                Text(
                  widget.label,
                  style: t.label.copyWith(color: AylaColors.textPrimary),
                ),
                if (description != null)
                  Text(
                    description,
                    // small：12 / w400 / --text-secondary
                    style: t.label.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AylaColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
          rail,
        ],
      ),
    );
  }
}

/// 表单行（.profile-form-row：column · gap sp1 · 14 / w700 / letter-spacing .2）。
///
/// web 的昵称/签名行是 <label> 包住字段（点标签聚焦字段）；本件在 [label] 上接 [onLabelTap]
/// 表达该转发（调用方传 () => focusNode.requestFocus()）。
class AylaProfileFormRow extends StatelessWidget {
  const AylaProfileFormRow({
    super.key,
    required this.label,
    required this.child,
    this.onLabelTap,
  });

  /// 行标题（web「昵称」/「个性签名」/「在线状态」）。
  final String label;

  /// 行控件（字段 / 胶囊组 / 开关行…）。
  final Widget child;

  /// 点标题时聚焦控件（web <label> 默认行为）。
  final VoidCallback? onLabelTap;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final Widget title = Text(label, style: t.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp1, // gap: var(--sp-1)
      children: <Widget>[
        if (onLabelTap == null)
          title
        else
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onLabelTap,
            child: title,
          ),
        child,
      ],
    );
  }
}

/// 资料编辑表单装配（.profile-form 全块，ProfilePage.tsx:212–305）。
///
/// 结构 = 在线状态 chips → 昵称 → 个性签名 →「向他人展示内容」开关 → 错误行 → 动作行
/// （已保存提示 + 保存键 + 退出键），顺序与 web 一致。
class AylaProfileForm extends StatefulWidget {
  const AylaProfileForm({
    super.key,
    required this.nicknameController,
    required this.signatureController,
    required this.status,
    required this.onStatusChanged,
    required this.showContent,
    required this.onShowContentChanged,
    this.onSave,
    this.onLogout,
    this.nicknamePlaceholder,
    this.signaturePlaceholder = '写点什么…',
    this.showContentLabel = '向他人展示内容',
    this.showContentDescription = '开启后，他人可在你的主页看到「他的内容」（发帖/直播间/桌游）',
    this.logoutLabel = '退出登录',
    this.savedLabel = '已保存',
    this.saveLabel = '保存修改',
    this.savingLabel = '保存中…',
    this.saving = false,
    this.saved = false,
    this.dirty = true,
    this.error,
    this.spacing = AylaSpacing.sp4,
  });

  /// 昵称输入控制器（web nickname state）。
  final TextEditingController nicknameController;

  /// 签名输入控制器（web signature state）。
  final TextEditingController signatureController;

  /// 在线状态值（web status）。
  final String status;

  /// 在线状态变更（web setStatus）。
  final ValueChanged<String> onStatusChanged;

  /// 「向他人展示内容」值（web showContent）。
  final bool showContent;

  /// 开关变更（web setShowContent）。
  final ValueChanged<bool> onShowContentChanged;

  /// 保存回调（web onSave）；null 或 [dirty] 为 false 或 [saving] 时按钮禁用。
  final VoidCallback? onSave;

  /// 退出登录回调（web logout）；null ⇒ 不渲染该键。
  final VoidCallback? onLogout;

  /// 昵称占位（web placeholder={currentUser.username}）。
  final String? nicknamePlaceholder;

  /// 签名占位（web「写点什么…」）。
  final String signaturePlaceholder;

  /// 开关行主文案（web「向他人展示内容」）。
  final String showContentLabel;

  /// 开关行副标题（web <small> 原文）。
  final String showContentDescription;

  /// 退出键文案（web「退出登录」）。
  final String logoutLabel;

  /// 「已保存」文案（web「已保存」）。
  final String savedLabel;

  /// 保存键文案（web「保存修改」）。
  final String saveLabel;

  /// 保存中文案（web「保存中…」）。
  final String savingLabel;

  /// 保存中（web saving）。
  final bool saving;

  /// 刚保存成功（web saved）；与 [dirty] 同真时才显示「已保存」。
  final bool saved;

  /// 有未保存改动（web dirty）。
  final bool dirty;

  /// 保存失败文案（web error ⇒ .auth-error[role=alert]）。
  final String? error;

  /// .profile-form 的 gap：默认 sp4；≥769 单栏档为 sp3（web profile.css 49）。
  final double spacing;

  @override
  State<AylaProfileForm> createState() => _AylaProfileFormState();
}

class _AylaProfileFormState extends State<AylaProfileForm> {
  final FocusNode _nicknameFocus = FocusNode();
  final FocusNode _signatureFocus = FocusNode();

  @override
  void dispose() {
    _nicknameFocus.dispose();
    _signatureFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? error = widget.error;
    final bool saveDisabled = widget.saving || !widget.dirty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: widget.spacing,
      children: <Widget>[
        // ---- 在线状态（div.profile-form-row + .status-chips） ----
        AylaProfileFormRow(
          label: '在线状态',
          child: AylaStatusChips(
            value: widget.status,
            onChanged: widget.onStatusChanged,
          ),
        ),
        // ---- 昵称（label.profile-form-row > input.field） ----
        AylaProfileFormRow(
          label: '昵称',
          onLabelTap: _nicknameFocus.requestFocus,
          child: AylaGlassInput(
            controller: widget.nicknameController,
            focusNode: _nicknameFocus,
            hintText: widget.nicknamePlaceholder,
            // base.css 350–353：字段文字继承行样式 14 / w700 / ls .2
            textStyle: t.label.copyWith(color: AylaColors.textPrimary),
            semanticLabel: '昵称',
          ),
        ),
        // ---- 个性签名（label.profile-form-row > textarea.field rows=3, resize:none） ----
        AylaProfileFormRow(
          label: '个性签名',
          onLabelTap: _signatureFocus.requestFocus,
          child: AylaGlassInput(
            controller: widget.signatureController,
            focusNode: _signatureFocus,
            hintText: widget.signaturePlaceholder,
            textStyle: t.label.copyWith(color: AylaColors.textPrimary),
            minLines: 3,
            maxLines: 3, // rows=3 固定高（resize: none）
            semanticLabel: '个性签名',
          ),
        ),
        // ---- 向他人展示内容（.profile-show-content-row） ----
        AylaProfileSwitch(
          label: widget.showContentLabel,
          description: widget.showContentDescription,
          value: widget.showContent,
          onChanged: widget.onShowContentChanged,
        ),
        // ---- 错误行（.auth-error[role=alert]） ----
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3,
                vertical: AylaSpacing.sp2,
              ),
              decoration: BoxDecoration(
                color: AylaColors.destructive.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(
                  color: AylaColors.destructive.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                error,
                style: t.caption.copyWith(color: AylaColors.destructive),
                softWrap: true,
              ),
            ),
          ),
        // ---- 动作行（.profile-actions：flex · gap sp3 · flex-end；≥769 wrap） ----
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AylaSpacing.sp3,
          runSpacing: AylaSpacing.sp3,
          children: <Widget>[
            if (widget.saved && !widget.dirty)
              Text(
                widget.savedLabel,
                style: t.caption.copyWith(color: AylaColors.success),
              ),
            AylaGlassButton(
              label: widget.saving ? widget.savingLabel : widget.saveLabel,
              onPressed: saveDisabled ? null : widget.onSave,
            ),
            if (widget.onLogout != null)
              AylaGlassButton(
                label: widget.logoutLabel,
                variant: AylaGlassButtonVariant.destructive,
                icon: AylaIcon(aylaIconByName('iconLogout')!, size: 15),
                minHeight: 36, // .profile-logout-btn
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp4, // padding: 0 var(--sp-4)
                ),
                onPressed: widget.onLogout,
              ),
          ],
        ),
      ],
    );
  }
}
