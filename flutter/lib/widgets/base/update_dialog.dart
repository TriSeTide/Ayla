/// 客户端更新弹窗（发现新版本 → 下载进度 → 安装/重启）。
///
/// 与既有组件的关系
/// ----------------
/// - 容器复用 [AylaModalOverlay] + [AylaModalCard] + [AylaSheetHead]，与
///   `AylaConfirmDialog` 同规格（480 / 80vh / sp4 / 窄屏贴底上滑）；
/// - 按钮复用 [AylaGlassButton]（primary / ghost / destructive 三档）；
/// - 不在本文件内发请求：`controller` 负责全部状态与副作用，本件只订阅并渲染，
///   这样同一套弹窗可被「登录后主动检查」「设置页手动检查」「强制更新」共用。
library;

import 'package:flutter/material.dart';

import '../../core/update/update_api.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_icons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'dialogs.dart' show AylaModalCard, AylaModalOverlay, AylaSheetHead;
import 'loading.dart' show AylaLoadingSpinner;

/// 更新弹窗阶段。
enum AylaUpdatePhase {
  /// 发现更新，等待用户确认下载。
  available,

  /// 正在下载（含校验）。
  downloading,

  /// 已下载并校验，准备安装（Windows 会提示将退出并重启）。
  ready,

  /// 安装器已启动；Windows 场景应用即将退出。
  applying,

  /// 失败（可重试/可稍后）。
  failed,
}

/// 弹窗状态（不可变；由 controller 产生新实例）。
@immutable
class AylaUpdateDialogState {
  const AylaUpdateDialogState({
    required this.phase,
    required this.release,
    required this.download,
    required this.mandatory,
    this.progress,
    this.error,
    this.note,
  });

  final AylaUpdatePhase phase;
  final AylaUpdateRelease release;
  final AylaUpdateDownload download;
  final bool mandatory;

  /// 下载进度 0..1（null = 未知）。
  final double? progress;
  final String? error;
  final String? note;

  AylaUpdateDialogState copyWith({
    AylaUpdatePhase? phase,
    double? progress,
    String? error,
    String? note,
    bool clearError = false,
    bool clearProgress = false,
  }) {
    return AylaUpdateDialogState(
      phase: phase ?? this.phase,
      release: release,
      download: download,
      mandatory: mandatory,
      progress: clearProgress ? null : (progress ?? this.progress),
      error: clearError ? null : (error ?? this.error),
      note: note ?? this.note,
    );
  }
}

/// 弹窗控制器（下载/安装的 owner；弹窗只渲染）。
abstract class AylaUpdateDialogController extends ChangeNotifier {
  AylaUpdateDialogState get state;

  /// 用户点「立即更新」。
  Future<void> startDownload();

  /// 下载完成后点「安装并重启」。
  Future<void> applyNow();

  /// 用户点「稍后」（强制更新时 UI 不提供该入口，本方法仍幂等）。
  void postpone();
}

/// 更新弹窗本体。
class AylaUpdateDialog extends StatefulWidget {
  const AylaUpdateDialog({
    super.key,
    required this.controller,
    required this.onClose,
    this.showPostpone = true,
  });

  final AylaUpdateDialogController controller;

  /// 关闭弹窗（仅「稍后」/「关闭」触发；强制更新时由调用方传 null 行为）。
  final VoidCallback onClose;

  /// 是否显示「稍后」入口（强制更新传 false）。
  final bool showPostpone;

  @override
  State<AylaUpdateDialog> createState() => _AylaUpdateDialogState();
}

class _AylaUpdateDialogState extends State<AylaUpdateDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(AylaUpdateDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaUpdateDialogState state = widget.controller.state;
    final bool busy =
        state.phase == AylaUpdatePhase.downloading ||
        state.phase == AylaUpdatePhase.applying;

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: AylaModalOverlay(
        onDismiss: busy || state.mandatory ? null : widget.onClose,
        padding: AylaSpacing.sp4,
        child: AylaModalCard(
          cardMaxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          padding: EdgeInsets.fromLTRB(
            AylaSpacing.sp4,
            AylaSpacing.sp4,
            AylaSpacing.sp4,
            AylaSpacing.sp4 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AylaSheetHead(
                title: state.mandatory ? '需要更新' : '发现新版本',
                onClose: busy || state.mandatory ? () {} : widget.onClose,
                closeIconSize: 18,
                disabled: busy || state.mandatory,
              ),
              _versionRow(t, state),
              if (state.release.notes.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: AylaSpacing.sp3),
                _notesBox(t, state.release.notes.trim()),
              ],
              if (state.phase == AylaUpdatePhase.downloading) ...<Widget>[
                const SizedBox(height: AylaSpacing.sp3),
                _progressRow(state.progress),
              ],
              if (state.error != null && state.error!.isNotEmpty) ...<Widget>[
                const SizedBox(height: AylaSpacing.sp3),
                Text(
                  state.error!,
                  style: t.caption.copyWith(
                    color: AylaColors.destructive,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
              if (state.note != null && state.note!.isNotEmpty) ...<Widget>[
                const SizedBox(height: AylaSpacing.sp2),
                Text(
                  state.note!,
                  style: t.caption.copyWith(color: AylaColors.textSecondary),
                ),
              ],
              const SizedBox(height: AylaSpacing.sp4),
              _actions(state, busy),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versionRow(AylaTextStyles t, AylaUpdateDialogState state) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            state.release.display,
            style: t.cardTitle.copyWith(
              fontFamily: AylaFonts.display,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AylaColors.textPrimary,
            ),
          ),
        ),
        if (state.mandatory)
          DecoratedBox(
            decoration: BoxDecoration(
              color: AylaColors.warningSoftBg,
              borderRadius: BorderRadius.circular(AylaRadii.rSm),
              border: Border.all(color: AylaColors.warningSoftBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp2,
                vertical: AylaSpacing.sp1,
              ),
              child: Text(
                '必须更新',
                style: t.caption.copyWith(
                  color: AylaColors.warning,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _notesBox(AylaTextStyles t, String notes) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.28,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AylaColors.glassBg,
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          border: Border.all(color: AylaColors.glassBorder),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AylaSpacing.sp3),
          child: Text(notes, style: t.body.copyWith(fontSize: 14, height: 1.6)),
        ),
      ),
    );
  }

  Widget _progressRow(double? progress) {
    final int percent = progress == null
        ? 0
        : (progress * 100).clamp(0, 100).round();
    return Row(
      children: <Widget>[
        const AylaLoadingSpinner(size: 16),
        const SizedBox(width: AylaSpacing.sp2),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: AylaColors.ice300,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AylaColors.pink500,
              ),
            ),
          ),
        ),
        const SizedBox(width: AylaSpacing.sp2),
        Text(
          progress == null ? '下载中' : '$percent%',
          style: AylaTextStyles.of(context).caption.copyWith(
            color: AylaColors.textSecondary,
            fontFamily: AylaFonts.utility,
          ),
        ),
      ],
    );
  }

  Widget _actions(AylaUpdateDialogState state, bool busy) {
    final List<Widget> buttons = switch (state.phase) {
      AylaUpdatePhase.available => <Widget>[
        if (widget.showPostpone && !state.mandatory)
          AylaGlassButton(
            label: '稍后',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: widget.onClose,
          ),
        AylaGlassButton(
          label: '立即更新',
          variant: AylaGlassButtonVariant.primary,
          icon: AylaIcon(aylaIconByName('iconDownload')!, size: 16),
          onPressed: widget.controller.startDownload,
        ),
      ],
      AylaUpdatePhase.downloading => <Widget>[
        AylaGlassButton(
          label: '下载中…',
          variant: AylaGlassButtonVariant.primary,
          onPressed: null,
        ),
      ],
      AylaUpdatePhase.ready => <Widget>[
        if (widget.showPostpone && !state.mandatory)
          AylaGlassButton(
            label: '稍后',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: widget.onClose,
          ),
        AylaGlassButton(
          label: '安装并重启',
          variant: AylaGlassButtonVariant.primary,
          onPressed: widget.controller.applyNow,
        ),
      ],
      AylaUpdatePhase.applying => <Widget>[
        AylaGlassButton(
          label: '正在安装…',
          variant: AylaGlassButtonVariant.primary,
          onPressed: null,
        ),
      ],
      AylaUpdatePhase.failed => <Widget>[
        AylaGlassButton(
          label: '关闭',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: busy ? null : widget.onClose,
        ),
        AylaGlassButton(
          label: '重试',
          variant: AylaGlassButtonVariant.primary,
          onPressed: widget.controller.startDownload,
        ),
      ],
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: AylaSpacing.sp3,
      children: buttons,
    );
  }
}
