/// 群资料卡（web `pages/group/GroupInfo.tsx:461–520` + `styles/group.css 1382–1610 / 2235–2240`）。
///
/// ## 事实源
/// ```
/// tsx 461           <section className="group-info-profile glass-card">
/// group.css 1468–1490  .group-info-profile：column · align-items center · gap sp3 ·
///                      padding sp8 sp6 sp6 · text-align center
///                      ≤768 ⇒ padding sp8 sp4 sp4；≥769 ⇒ gap sp2 · padding sp6 sp4 sp4
/// group.css 1404–1414  .group-info-profile-top：**absolute** top sp3 / left sp3（z 1）—— 返回键浮在卡左上
/// group.css 1412–1420  .group-info-back：glass 底 + blur18 sat1.4 + 1px 边 + inset 阴影 + text-primary
/// tsx 466–493          头像块：Avatar(label=群名, size = 窄 76 / 宽 92, online, imageUrl) ·
///                      canManage ⇒ ghost「更换群头像 / 上传中…」（`.group-info-avatar-btn`：12px / padding sp1 sp3 /
///                      min-h 36）· avatarPreview ⇒ hint「新头像将在保存后生效」+ primary「保存群头像 / 保存中…」·
///                      avatarError ⇒ `.group-info-avatar-error`（13 / destructive / **role=alert**）
/// group.css 1492–1513  .group-info-avatar-block { column · center · gap sp2 }
/// tsx 495–520          编辑态：input placeholder「群名」(aria 群名) + textarea placeholder「群简介」rows 3 +
///                      error(`.group-info-error` 13/destructive) + actions：primary「保存 / 保存中…」+ ghost「取消」
///                      （`.group-info-edit-actions .btn { flex: 1 }` —— **两键等宽**）
/// tsx 496–516          展示态：h3 群名（Display 24/600/1.25）· `.group-info-about`（label「群简介」12/700/ls .4 +
///                      `<p>` = announcement **或「暂无简介」**，max-width 420）·
///                      `.group-info-created`「创建于 {日期}」（Utility 12；`formatDate`：无值 ⇒ **「—」**，
///                      否则 `toLocaleDateString("zh-CN")` = `y/M/d`）·
///                      统计三格：成员 / **已载入在线** / 子群（`.group-info-stats`：3 列 grid · gap sp2 ·
///                      padding sp3 0 sp2 · **上下 1px rgba(157,191,230,.28) 分隔线**；
///                      num = Utility 22/500，label = 12/secondary）·
///                      `.group-info-actions-row`（flex · gap sp3 · margin-top sp3）：分享群聊 + canManage ⇒「编辑群资料」
/// ```
///
/// ## 机制差异（登记）
/// ① `.group-info-profile-top` 是 `position: absolute` ⇒ Flutter 用 `Stack` + `Positioned`（返回键浮左上）；
/// ② 编辑态的两个受控输入（React `value/onChange`）⇒ Flutter 用内部 `TextEditingController`，
///    由 [editing] 变化同步初值，保存时通过 [onSaveEdit] 回传 `(群名, 群简介)`。
///
/// ## 公开面
/// `AylaGroupInfoProfile` · `AylaGroupInfoStat` · `aylaFormatGroupDate`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';

/// 统计格（num + label）。
class AylaGroupInfoStat {
  const AylaGroupInfoStat({required this.value, required this.label});

  /// 数字（web 用 `memberCount` / `onlineCount` / `subgroupPage.total`）。
  final String value;

  /// 标签（成员 / 已载入在线 / 子群）。
  final String label;
}

/// 日期文案（web `GroupInfo.tsx:61–69` 的 `formatDate`）：无值 ⇒「—」，否则 `y/M/d`（zh-CN）。
String aylaFormatGroupDate(DateTime? date) {
  if (date == null) return '—';
  return '${date.year}/${date.month}/${date.day}';
}

/// 群资料卡：返回 + 头像块 + （展示 | 编辑）+ 统计 + 动作行。
class AylaGroupInfoProfile extends StatefulWidget {
  const AylaGroupInfoProfile({
    super.key,
    required this.title,
    this.about,
    this.aboutLabel = '群简介',
    this.aboutEmptyLabel = '暂无简介',
    this.createdAt,
    this.createdTemplate = '创建于 {date}',
    this.stats = const <AylaGroupInfoStat>[],
    this.avatarUrl,
    this.avatarNarrowSize = 76,
    this.avatarWideSize = 92,
    this.canManage = false,
    this.onBack,
    this.onChangeAvatar,
    this.avatarPreview = false,
    this.avatarSaving = false,
    this.onSaveAvatar,
    this.avatarHintLabel = '新头像将在保存后生效',
    this.avatarError,
    this.changeAvatarLabel = '更换群头像',
    this.uploadingLabel = '上传中…',
    this.saveAvatarLabel = '保存群头像',
    this.savingLabel = '保存中…',
    this.editing = false,
    this.initialTitle,
    this.initialAbout,
    this.editTitleHint = '群名',
    this.editAboutHint = '群简介',
    this.onSaveEdit,
    this.onCancelEdit,
    this.saving = false,
    this.error,
    this.onEdit,
    this.editLabel = '编辑群资料',
    this.saveLabel = '保存',
    this.cancelLabel = '取消',
    this.share,
  });

  /// 群名。
  final String title;

  /// 群简介（`conv.announcement`）。
  final String? about;

  /// 简介标签（web 原文「群简介」）。
  final String aboutLabel;

  /// 简介为空时的占位（web 原文「暂无简介」）。
  final String aboutEmptyLabel;

  /// 创建时间（null ⇒ 文案里显示「—」）。
  final DateTime? createdAt;

  /// 创建时间模板（web 原文「创建于 {date}」）。
  final String createdTemplate;

  /// 统计格（web 恒 3 格：成员 / 已载入在线 / 子群）。
  final List<AylaGroupInfoStat> stats;

  /// 群头像。
  final String? avatarUrl;

  /// 头像直径（web：窄 76 / 宽 92）。
  final double avatarNarrowSize;
  final double avatarWideSize;

  /// 可管理（显「更换群头像」「编辑群资料」）。
  final bool canManage;

  /// 返回键（`.group-info-back`，浮在卡左上）。
  final VoidCallback? onBack;

  /// 选新头像（web `<label>` + hidden file input）。
  final VoidCallback? onChangeAvatar;

  /// 已选新头像（显示提示行 + 保存键）。
  final bool avatarPreview;

  /// 头像上传/保存中（按钮文案与禁用）。
  final bool avatarSaving;

  /// 保存群头像。
  final VoidCallback? onSaveAvatar;

  /// 头像提示（web 原文「新头像将在保存后生效」）。
  final String avatarHintLabel;

  /// 头像校验错误（`role=alert`）。
  final String? avatarError;

  final String changeAvatarLabel;
  final String uploadingLabel;
  final String saveAvatarLabel;
  final String savingLabel;

  /// 编辑态。
  final bool editing;

  /// 编辑初值（web `startEdit()` 用当前值填入）。
  final String? initialTitle;
  final String? initialAbout;

  final String editTitleHint;
  final String editAboutHint;

  /// 保存编辑（回传 (群名, 群简介)）。
  final void Function(String title, String about)? onSaveEdit;

  /// 取消编辑。
  final VoidCallback? onCancelEdit;

  /// 保存中（primary 文案换「保存中…」且禁用）。
  final bool saving;

  /// 保存失败文案（`.group-info-error`）。
  final String? error;

  /// 点「编辑群资料」。
  final VoidCallback? onEdit;

  final String editLabel;
  final String saveLabel;
  final String cancelLabel;

  /// 分享槽位（web：`ShareButton label="分享群聊"`）。
  final Widget? share;

  @override
  State<AylaGroupInfoProfile> createState() => _AylaGroupInfoProfileState();
}

class _AylaGroupInfoProfileState extends State<AylaGroupInfoProfile> {
  late final TextEditingController _title = TextEditingController(
    text: widget.initialTitle ?? widget.title,
  );
  late final TextEditingController _about = TextEditingController(
    text: widget.initialAbout ?? widget.about ?? '',
  );

  @override
  void didUpdateWidget(AylaGroupInfoProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入编辑态时同步一次初值（web `startEdit()` 用当前值填入）
    if (!oldWidget.editing && widget.editing) {
      _title.text = widget.initialTitle ?? widget.title;
      _about.text = widget.initialAbout ?? widget.about ?? '';
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool wide = MediaQuery.sizeOf(context).width >= 769;
    final double avatarSize = wide ? widget.avatarWideSize : widget.avatarNarrowSize;
    // `.group-info-profile`：窄 gap sp3 / 宽 gap sp2；padding 窄 sp8 sp4 sp4 / 宽 sp6 sp4 sp4
    final double gap = wide ? AylaSpacing.sp2 : AylaSpacing.sp3;
    final EdgeInsets padding = wide
        ? const EdgeInsets.fromLTRB(
            AylaSpacing.sp4,
            AylaSpacing.sp6,
            AylaSpacing.sp4,
            AylaSpacing.sp4,
          )
        : const EdgeInsets.fromLTRB(
            AylaSpacing.sp4,
            AylaSpacing.sp8,
            AylaSpacing.sp4,
            AylaSpacing.sp4,
          );
    final String aboutText = (widget.about == null || widget.about!.isEmpty)
        ? widget.aboutEmptyLabel
        : widget.about!;
    final String createdText = widget.createdTemplate.replaceFirst(
      '{date}',
      aylaFormatGroupDate(widget.createdAt),
    );
    final String? avatarError = widget.avatarError;
    final String? error = widget.error;
    return Stack(
      children: <Widget>[
        AylaGlassCard(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            spacing: gap,
            children: <Widget>[
              // ---- 头像块 ----
              Column(
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                children: <Widget>[
                  AylaAvatarHalo(
                    label: widget.title,
                    size: avatarSize,
                    online: true, // web：群头像恒 online
                    resourceUrl: widget.avatarUrl,
                  ),
                  if (widget.canManage)
                    AylaGlassButton(
                      label: widget.avatarSaving
                          ? widget.uploadingLabel
                          : widget.changeAvatarLabel,
                      variant: AylaGlassButtonVariant.ghost,
                      fontSize: 12,
                      minHeight: 36, // `.group-info-avatar-btn { min-height: 36 }`
                      padding: const EdgeInsets.symmetric(
                        horizontal: AylaSpacing.sp3,
                        vertical: AylaSpacing.sp1,
                      ),
                      onPressed: widget.avatarSaving
                          ? null
                          : widget.onChangeAvatar,
                    ),
                  if (widget.avatarPreview) ...<Widget>[
                    Text(
                      widget.avatarHintLabel,
                      style: t.timestamp.copyWith(
                        fontSize: 12,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                    AylaGlassButton(
                      label: widget.avatarSaving
                          ? widget.savingLabel
                          : widget.saveAvatarLabel,
                      onPressed: widget.avatarSaving ? null : widget.onSaveAvatar,
                    ),
                  ],
                  if (avatarError != null)
                    Semantics(
                      liveRegion: true, // web：role="alert"
                      child: Text(
                        avatarError,
                        textAlign: TextAlign.center,
                        style: t.timestamp.copyWith(
                          fontSize: 13,
                          color: AylaColors.destructive,
                        ),
                      ),
                    ),
                ],
              ),
              // ---- 编辑态 / 展示态 ----
              if (widget.editing) ...<Widget>[
                SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    spacing: AylaSpacing.sp2,
                    children: <Widget>[
                      AylaGlassInput(
                        controller: _title,
                        hintText: widget.editTitleHint,
                        semanticLabel: widget.editTitleHint,
                      ),
                      AylaGlassInput(
                        controller: _about,
                        hintText: widget.editAboutHint,
                        semanticLabel: widget.editAboutHint,
                        maxLines: 3, // rows={3}（web 禁用手动 resize）
                      ),
                      if (error != null)
                        Text(
                          error,
                          style: t.label.copyWith(
                            fontSize: 13,
                            color: AylaColors.destructive,
                          ),
                        ),
                      Row(
                        spacing: AylaSpacing.sp2,
                        children: <Widget>[
                          // `.group-info-edit-actions .btn { flex: 1 }`
                          Expanded(
                            child: AylaGlassButton(
                              // ⚠️ 必须 expand：`Expanded` 只给等宽**槽位**，按钮内部视觉盒
                              // 按内容宽度排 ⇒ 不 expand 时「保存」会明显左偏（用户实测指出）
                              expand: true,
                              label: widget.saving
                                  ? widget.savingLabel
                                  : widget.saveLabel,
                              onPressed: widget.saving
                                  ? null
                                  : () => widget.onSaveEdit?.call(
                                      _title.text,
                                      _about.text,
                                    ),
                            ),
                          ),
                          Expanded(
                            child: AylaGlassButton(
                              expand: true, // 同上：视觉撑满槽位
                              label: widget.cancelLabel,
                              variant: AylaGlassButtonVariant.ghost,
                              onPressed: widget.onCancelEdit,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else ...<Widget>[
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: t.pageTitle.copyWith(
                    fontSize: 24, // Display 24 / 600 / 1.25
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    color: AylaColors.textPrimary,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420), // max-width: 420px
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    spacing: AylaSpacing.sp1, // gap: var(--sp-1)
                    children: <Widget>[
                      Text(
                        widget.aboutLabel, // 12 / 700 / ls .4 / secondary
                        style: t.label.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                      Text(
                        aboutText,
                        textAlign: TextAlign.center,
                        style: t.body.copyWith(
                          fontSize: 14,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  createdText,
                  style: t.timestamp.copyWith(
                    fontSize: 12, // Utility 12
                    color: AylaColors.textSecondary,
                  ),
                ),
                if (widget.stats.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(
                      top: AylaSpacing.sp3,
                      bottom: AylaSpacing.sp2,
                    ),
                    decoration: const BoxDecoration(
                      // border-block: 1px solid rgba(157,191,230,.28)
                      border: Border.symmetric(
                        horizontal: BorderSide(color: Color(0x479DBFE6)),
                      ),
                    ),
                    child: Row(
                      spacing: AylaSpacing.sp2,
                      children: <Widget>[
                        for (final AylaGroupInfoStat stat in widget.stats)
                          Expanded(child: _Stat(stat: stat)),
                      ],
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: AylaSpacing.sp3,
                  children: <Widget>[
                    if (widget.share != null) widget.share!,
                    if (widget.canManage)
                      AylaGlassButton(
                        label: widget.editLabel,
                        variant: AylaGlassButtonVariant.ghost,
                        onPressed: widget.onEdit,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // `.group-info-profile-top`：absolute top sp3 / left sp3
        if (widget.onBack != null)
          Positioned(
            top: AylaSpacing.sp3,
            left: AylaSpacing.sp3,
            child: AylaIconButton(
              icon: AylaIcon(aylaIconByName('iconBack')!, size: 22),
              semanticLabel: '返回群聊',
              onPressed: widget.onBack,
            ),
          ),
      ],
    );
  }
}

/// 统计格：num（Utility 22/500）+ label（12/secondary），`gap: 2px`。
class _Stat extends StatelessWidget {
  const _Stat({required this.stat});

  final AylaGroupInfoStat stat;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: <Widget>[
        Text(
          stat.value,
          style: t.timestamp.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            height: 1.2,
            color: AylaColors.textPrimary,
          ),
        ),
        Text(
          stat.label,
          style: t.timestamp.copyWith(
            fontSize: 12,
            color: AylaColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
