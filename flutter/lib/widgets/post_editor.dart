/// AylaPostEditor —— 发帖表单（三形态：常规 / collapsible 群内 / compact 群内）。
///
/// 事实源（逐条对应，无自由发挥）：
/// - `Ayla/web/src/components/posts/PostEditor.tsx`（327 行）
/// - `styles/posts.css:219–418`（.post-editor 族全量）
/// - `styles/auroraqua.css:105–112/124–166`（媒体钮与收起钮的材料与交互）
/// - `design.md §12.8.1`（编辑器与 CreateSheet 规格、群内 collapsible 语义）
///
/// 关键事实（回读确认）：
/// 1. 三形态：默认展开（非 collapsible）；`collapsible` 默认收起、**点输入框即展开**、
///    展开后右上角 32px 圆形收起钮；`compact` 只改 placeholder 与 rows。
/// 2. 展开态 `max-height: min(90vh, 1000px)`；collapsible 展开时
///    `.post-editor-extra` 内部滚动（可见性/错误/重试），发布钮与媒体钮固定两端。
/// 3. 媒体预览块 128px 方块 + 右上 28px 圆形移除钮；`.post-editor-image` 的
///    `border-radius: var(--radius-md)` **在 web 全库并无该变量**（只有 sm/input/card/pill）
///    → 该声明 invalid at computed-value time → `border-radius` 回落初始值 **0**（方角）。
///    本组件照**实际渲染**做方角，勿改成 12（如需圆角应先给 web 定义该 token）。
/// 4. 「图片/视频」钮 = `.post-editor-image-btn`：glass-bg + 亮边 + blur(8) +
///    `--glass-shadow-button`，`:hover` → glow 边 + `--glow-shadow`（posts.css 410–414）；
///    auroraqua 另给 200ms / hover 1.02 / active .98 / 600ms 扫光
///    → 用 `GlassButton(variant: ghost, glowHover: true)` 表达（组件库已补该能力）。
/// 5. 收起钮 = `.post-editor-collapse-btn`：32px 圆形玻璃钮（auroraqua 覆写材质与交互）
///    → 用 `AylaIconButton(size: 32)`（默认 pill = 正圆）。
/// 6. 文案逐字：标题（必填）/ 正文（必填）/ 发一条帖子… / 标题不能为空 / 正文不能为空 /
///    请先完成图片上传或重试失败图片 / 最多添加 9 个媒体，还可添加 N 个 /
///    N 个媒体上传失败，可点击重试 / 重试失败媒体（N）/ 上传中 N% / 发布中… / 上传中… /
///    发布 / 图片/视频 N/9 / 移除媒体 / 收起发帖面板。
///
/// **展示型组件**：媒体选择上传、失败重试、移除清理、提交请求全部由页面注入
/// （文件选择插件与三步上传属平台层，对应 web `api/media.ts` 的实现位置）。
library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/media/media_signer.dart' show MediaVariant;
import '../core/models/post.dart';
import '../core/net/dio_client.dart' show ApiException;
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart' show AylaIconButton, AylaMsgActionButton;
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'directory_controls.dart'
    show AylaVisibilitySelector, VisibilitySelection;
import 'resource_image.dart';

/// 发帖编辑器。
class AylaPostEditor extends StatefulWidget {
  const AylaPostEditor({
    super.key,
    required this.onSubmit,
    this.group,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.compact = false,
    this.collapsible = false,
    this.expanded,
    this.onExpandedChange,
    this.onPickMedia,
    this.onRetryFailedMedia,
    this.onRemoveMedia,
    this.initialTitle = '',
    this.initialBody = '',
    this.initialImages = const <AylaPostMediaDraft>[],
  });

  /// 提交（页面注入：`POST /posts/`）。成功返回后本组件负责清空与收起。
  final Future<void> Function(AylaPostDraft draft) onSubmit;

  /// 群内发帖归属群 id；null = 一级 tab（公开）。
  final String? group;

  /// 可见性选择器可选群列表。
  final List<({String id, String title})> groups;

  /// 群列表加载中。
  final bool groupsLoading;

  /// 紧凑模式（群内底部输入框变体）。
  final bool compact;

  /// 可展开/收起模式（默认收起，点输入框展开）。
  final bool collapsible;

  /// 受控展开态（传入后展开/收起完全由外部驱动）。
  final bool? expanded;

  /// 展开/收起变化通知。
  final ValueChanged<bool>? onExpandedChange;

  /// 选媒体 + 上传（页面注入）。[remaining] = 9 减已选；[onProgress] 0..1 或 null。
  final Future<AylaMediaPickResult> Function(
    int remaining,
    ValueChanged<double?> onProgress,
  )? onPickMedia;

  /// 重试上次失败的媒体（页面注入；null = 不显示重试钮）。
  final Future<AylaMediaPickResult> Function()? onRetryFailedMedia;

  /// 移除媒体（页面注入：清理对象存储/上传会话）。移除是乐观的，失败只报错不移回。
  final Future<void> Function(AylaPostMediaDraft draft)? onRemoveMedia;

  /// 初始标题（样张/编辑场景）。
  final String initialTitle;

  /// 初始正文（样张/编辑场景）。
  final String initialBody;

  /// 初始媒体（样张/编辑场景）。
  final List<AylaPostMediaDraft> initialImages;

  @override
  State<AylaPostEditor> createState() => _AylaPostEditorState();
}


class _AylaPostEditorState extends State<AylaPostEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initialTitle);
  late final TextEditingController _body =
      TextEditingController(text: widget.initialBody);
  late final FocusNode _bodyFocus = FocusNode();
  late VisibilitySelection _visibility;
  late List<String> _selectedGroupIds;
  late final List<AylaPostMediaDraft> _images =
      List<AylaPostMediaDraft>.of(widget.initialImages);

  int _failedCount = 0;
  bool _submitting = false;
  bool _uploading = false;

  /// 上传进度 0..1（null = 不显示进度条）。
  double? _progress;
  String? _error;
  bool _internalExpanded = false;

  bool get _expanded => widget.expanded ?? _internalExpanded;

  @override
  void initState() {
    super.initState();
    // web PostEditor.tsx:71–74：群内默认「指定群可见 + 本群勾选」，一级 tab 默认「公开」
    _visibility = widget.group != null
        ? const VisibilitySelection(group: true)
        : const VisibilitySelection(isPublic: true);
    _selectedGroupIds =
        widget.group != null ? <String>[widget.group!] : <String>[];
    _internalExpanded = !widget.collapsible;
    _title.addListener(_onTextChanged);
    _body.addListener(_onTextChanged);
    _bodyFocus.addListener(_onBodyFocus);
  }

  @override
  void dispose() {
    _title.removeListener(_onTextChanged);
    _body.removeListener(_onTextChanged);
    _bodyFocus.removeListener(_onBodyFocus);
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  /// web：textarea `onFocus` → 收起态点输入框直接展开（无独立展开按钮）。
  void _onBodyFocus() {
    if (widget.collapsible && !_expanded && _bodyFocus.hasFocus) {
      _updateExpanded(true);
    }
  }

  void _updateExpanded(bool value) {
    setState(() => _internalExpanded = value);
    widget.onExpandedChange?.call(value);
  }

  String _message(Object error) =>
      error is ApiException ? error.message : '发布失败';

  Future<void> _pick() async {
    final Future<AylaMediaPickResult> Function(int, ValueChanged<double?>)?
        picker = widget.onPickMedia;
    if (picker == null ||
        _uploading ||
        _submitting ||
        _images.length >= 9) {
      return;
    }
    final int remaining = 9 - _images.length;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final AylaMediaPickResult result = await picker(remaining, (double? p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _images.addAll(result.drafts.take(remaining));
        _failedCount = result.failed;
        _progress = null;
        if (result.overLimit > 0) {
          _error = '最多添加 9 个媒体，还可添加 $remaining 个';
        }
        if (result.failed > 0) {
          _error = '${result.failed} 个媒体上传失败，可点击重试';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = _message(error);
        });
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _retryFailed() async {
    final Future<AylaMediaPickResult> Function()? retry =
        widget.onRetryFailedMedia;
    if (retry == null || _uploading || _submitting) return;
    final int remaining = 9 - _images.length;
    setState(() {
      _uploading = true;
      _failedCount = 0;
      _error = null;
    });
    try {
      final AylaMediaPickResult result = await retry();
      if (!mounted) return;
      setState(() {
        _images.addAll(result.drafts.take(remaining));
        _failedCount = result.failed;
        _progress = null;
        if (result.failed > 0) {
          _error = '${result.failed} 个媒体上传失败，可点击重试';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = _message(error);
        });
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// web removeMedia：**乐观移除** + 后台清理对象存储/上传会话（失败只提示）。
  void _remove(AylaPostMediaDraft draft) {
    if (_uploading || _submitting) return;
    setState(() {
      _images.removeWhere((AylaPostMediaDraft d) => d.mediaId == draft.mediaId);
      _error = null;
    });
    final Future<void> Function(AylaPostMediaDraft)? cleanup =
        widget.onRemoveMedia;
    if (cleanup == null) return;
    unawaited(
      cleanup(draft).catchError((Object error) {
        if (mounted) setState(() => _error = _message(error));
      }),
    );
  }

  /// web PostEditor.tsx:171–175：多选 → 后端单值，**public 优先 → friends → group**。
  AylaPostVisibility _backendVisibility() {
    if (_visibility.isPublic) return AylaPostVisibility.public;
    if (_visibility.friends) return AylaPostVisibility.friends;
    return AylaPostVisibility.group;
  }

  Future<void> _submit() async {
    final String title = _title.text.trim();
    final String body = _body.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    if (body.isEmpty) {
      setState(() => _error = '正文不能为空');
      return;
    }
    if (_failedCount > 0 || _uploading) {
      setState(() => _error = '请先完成图片上传或重试失败图片');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        AylaPostDraft(
          title: title,
          body: body,
          groupId: widget.group,
          visibility: _backendVisibility(),
          allowedGroupIds: _selectedGroupIds,
          mediaIds: <String>[
            for (final AylaPostMediaDraft d in _images) d.mediaId,
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _title.clear();
        _body.clear();
        _images.clear();
        _failedCount = 0;
        _error = null;
      });
      // 发布完成收起编辑器（collapsible 模式回到单行输入）
      if (widget.collapsible) _updateExpanded(false);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool expanded = _expanded;
    final bool narrow = MediaQuery.of(context).size.width <= 768;
    final bool busy = _submitting || _uploading;

    // .post-editor-collapse-bar（右对齐 + padding-bottom sp1）+ 32px 圆形收起钮
    final Widget collapseBar = Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp1),
      child: Align(
        alignment: Alignment.centerRight,
        child: AylaIconButton(
          size: 32,
          icon: AylaIcon(
            aylaIconByName('iconChevronDown')!,
            size: 18,
            // web .post-editor-collapse-btn { color: var(--text-secondary) }
            color: AylaColors.textSecondary,
          ),
          onPressed: () => _updateExpanded(false),
          semanticLabel: '收起发帖面板',
        ),
      ),
    );

    final Widget titleField = GlassInput(
      controller: _title,
      hintText: '标题（必填）',
      minHeight: 40, // .post-editor-title { min-height: 40px }
      maxLength: 128,
      enabled: !busy,
      textStyle: t.body.copyWith(color: AylaColors.textPrimary),
      semanticLabel: '标题（必填）',
    );

    final Widget bodyField = GlassInput(
      controller: _body,
      focusNode: _bodyFocus,
      hintText: widget.compact ? '发一条帖子…' : '正文（必填）',
      // 展开：rows=4 + min-height 64；收起：单行 40px（resize:none / overflow hidden）
      minHeight: expanded ? 64 : 40,
      minLines: expanded ? 4 : 1,
      maxLines: expanded ? 4 : 1,
      enabled: !busy,
      textStyle: t.body.copyWith(color: AylaColors.textPrimary),
      semanticLabel: widget.compact ? '发一条帖子' : '正文（必填）',
    );

    final bool canSubmit = !busy &&
        _failedCount == 0 &&
        _title.text.trim().isNotEmpty &&
        _body.text.trim().isNotEmpty;
    final Widget submitButton = GlassButton(
      // 窄屏隐藏文字（web：`{!isNarrow && (...)}`）
      label: narrow
          ? ''
          : (_uploading ? '上传中…' : (_submitting ? '发布中…' : '发布')),
      icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
      minHeight: 40, // .post-editor-submit height 40
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
      onPressed: canSubmit ? () => unawaited(_submit()) : null,
      semanticLabel: '发布',
    );

    final Widget inputRow = Row(
      crossAxisAlignment: CrossAxisAlignment.end, // align-items: flex-end
      children: <Widget>[
        Expanded(child: bodyField),
        const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
        submitButton,
      ],
    );

    final Widget extra = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AylaVisibilitySelector(
          value: _visibility,
          onChange: (VisibilitySelection v) => setState(() => _visibility = v),
          selectedGroupIds: _selectedGroupIds,
          onSelectedGroupIdsChange: (List<String> ids) =>
              setState(() => _selectedGroupIds = ids),
          groups: widget.groups,
          groupsLoading: widget.groupsLoading,
          initialGroupId: widget.group,
          lockGroup: widget.group != null, // 群内发帖锁定本群
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp1),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!, // .post-editor-error：13px + --destructive
                style: t.caption.copyWith(
                  fontSize: 13,
                  color: AylaColors.destructive,
                ),
              ),
            ),
          ),
        if (_failedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp1),
            child: AylaMsgActionButton(
              label: '重试失败媒体（$_failedCount）',
              onPressed: busy ? null : () => unawaited(_retryFailed()),
            ),
          ),
      ],
    );

    final Widget mediaStrip = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 2), // padding-bottom: 2px
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _images.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: AylaSpacing.sp2), // gap: sp2
            _mediaBlock(_images[i], busy: busy),
          ],
        ],
      ),
    );

    final Widget actions = Align(
      alignment: Alignment.centerLeft,
      child: GlassButton(
        label: '图片/视频 ${_images.length}/9',
        icon: AylaIcon(aylaIconByName('iconImage')!, size: 18),
        variant: GlassButtonVariant.ghost,
        glowHover: true, // posts.css 410–414：hover → glow 边 + 粉辉光
        minHeight: 40,
        padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
        onPressed: (widget.onPickMedia == null ||
                busy ||
                _images.length >= 9)
            ? null
            : () => unawaited(_pick()),
        semanticLabel: '添加图片或视频',
      ),
    );

    // 展开态才渲染选项区（web：`{expanded && (<div className="post-editor-extra">…)}`）——
    // 收起态只保留单行输入 + 发布钮（2026-09-20 用户指出群内变体"和群外一模一样"，
    // 根因就是漏了这层 if：收起态把可见性选择器也画出来了）。
    // 展开态 + collapsible → 选项区内部滚动（发布钮与媒体钮固定在上下两端）
    final Widget extraRegion = !expanded
        ? const SizedBox.shrink()
        : (widget.collapsible
            ? Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                    child: extra,
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                child: extra,
              ));

    final double maxHeightCap = math.min(
      MediaQuery.of(context).size.height * 0.9, // min(90vh, 1000px)
      1000,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (widget.collapsible && expanded) ? maxHeightCap : 1000,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: widget.collapsible ? AylaSpacing.sp2 : AylaSpacing.sp3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.collapsible && expanded) collapseBar,
            if (expanded) ...<Widget>[
              titleField,
              const SizedBox(height: AylaSpacing.sp2),
            ],
            inputRow,
            extraRegion,
            if (_images.isNotEmpty) ...<Widget>[
              const SizedBox(height: AylaSpacing.sp1),
              mediaStrip,
            ],
            if (_progress != null) ...<Widget>[
              const SizedBox(height: AylaSpacing.sp1),
              _progressBar(_progress!),
            ],
            if (expanded) ...<Widget>[
              const SizedBox(height: AylaSpacing.sp2),
              actions,
            ],
          ],
        ),
      ),
    );
  }


  /// `.post-editor-image`：128px 方块（**方角**——web 的 `--radius-md` 未定义，
  /// 见文件头事实 3）+ 右上 28px 圆形移除钮。
  Widget _mediaBlock(AylaPostMediaDraft draft, {required bool busy}) {
    final bool isVideo = draft.descriptor.kind == AylaMediaKind.video;
    final String? thumb = draft.descriptor.thumbnail;
    final String? localPath = draft.localPath;

    Widget preview;
    if (isVideo && thumb != null) {
      // 视频：上传时的海报帧（签名缩略图，等价 web <video preload=metadata> 首帧）
      preview = ResourceImage(
        src: thumb,
        alt: '',
        variant: MediaVariant.thumb,
        fit: BoxFit.cover,
      );
    } else if (isVideo) {
      preview = _mediaFallback(draft);
    } else if (localPath != null) {
      // 图片：本地文件即时预览（等价 web 的 objectURL）
      preview = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object e, StackTrace? s) =>
            _mediaFallback(draft),
      );
    } else {
      preview = ResourceImage(
        src: mediaContentUrl(draft.mediaId),
        alt: '',
        variant: MediaVariant.thumb,
        fit: BoxFit.cover,
        fallback: _mediaFallback(draft),
      );
    }

    return SizedBox(
      width: 128, // width: 128px
      height: 128, // aspect-ratio: 1
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg, // background: var(--glass-bg)
                border: Border.all(color: AylaColors.glassBorder),
              ),
              child: ClipRect(child: preview), // overflow: hidden（方角）
            ),
          ),
          Positioned(
            top: AylaSpacing.sp1,
            right: AylaSpacing.sp1,
            child: Opacity(
              opacity: busy ? 0.55 : 1, // button:disabled opacity .55
              child: Semantics(
                button: true,
                label: '移除媒体',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: busy ? null : () => _remove(draft),
                  child: Container(
                    width: 28, // 28×28
                    height: 28,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AylaColors.glassBgStrong, // --glass-bg-strong
                      shape: BoxShape.circle, // border-radius: pill
                    ),
                    child: const Text(
                      '×',
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 16,
                        height: 1,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaFallback(AylaPostMediaDraft draft) => Center(
        child: AylaIcon(
          aylaIconByName(
            draft.descriptor.kind == AylaMediaKind.video
                ? 'iconVideo'
                : 'iconImage',
          )!,
          size: 24,
          color: AylaColors.textSecondary,
        ),
      );

  /// `.post-editor-progress`：上传百分比 + 4px pill 进度条（fill 过渡 200ms ease-out）。
  Widget _progressBar(double progress) {
    final int pct = (progress * 100).round();
    return Semantics(
      label: '上传中 $pct%',
      child: Row(
        children: <Widget>[
          Text(
            '上传中 $pct%',
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              color: AylaColors.textSecondary,
            ),
          ),
          const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
          Expanded(
            child: ClipRRect(
              borderRadius: AylaRadii.pill,
              child: SizedBox(
                height: 4, // height: 4px
                child: ColoredBox(
                  color: AylaColors.glassBorder, // background: --glass-border
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: progress),
                    duration: const Duration(milliseconds: 200), // transition 200ms
                    curve: AylaCurves.easeOut,
                    builder: (
                      BuildContext context,
                      double v,
                      Widget? child,
                    ) {
                      return FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: v.clamp(0.0, 1.0),
                        child: child,
                      );
                    },
                    child: const ColoredBox(color: AylaColors.pink500),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ======================= 预览与样张 =======================

/// 发帖编辑器样张三态（组件画布与 @Preview 共用；**单一来源**）。
///
/// 1. 常规（一级 tab，默认公开）：标题 + 正文 + 可见性 + 图片/视频钮
/// 2. 群内 collapsible **收起态**：单行正文 + 发布钮（点输入框即展开）
/// 3. 群内 collapsible **展开态**：32px 圆形收起钮 + 标题/正文 + 可见性锁定本群 + 媒体预览
Widget aylaPostEditorSamples() {
  const List<({String id, String title})> groups = <({String id, String title})>[
    (id: 'g1', title: '深夜电台'),
    (id: 'g2', title: '星海观测站'),
  ];
  Future<void> submit(AylaPostDraft draft) async {}
  final List<AylaPostMediaDraft> media = <AylaPostMediaDraft>[
    const AylaPostMediaDraft(
      mediaId: 'm-1',
      descriptor: AylaMediaDescriptor(
        mediaId: 'm-1',
        kind: AylaMediaKind.image,
        thumbnail: '/api/v1/media/m-1/thumbnail',
      ),
    ),
    const AylaPostMediaDraft(
      mediaId: 'v-1',
      descriptor: AylaMediaDescriptor(
        mediaId: 'v-1',
        kind: AylaMediaKind.video,
        thumbnail: '/api/v1/media/v-1/thumbnail',
      ),
    ),
  ];

  Widget box(String label, double width, Widget child) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.utility,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 11,
                color: AylaColors.textSecondary,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp2),
            child,
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        box(
          '常规（CreateSheet 480 · 一级 tab · 默认公开）',
          480,
          GlassCard(
            strong: true, // .create-sheet-card：--glass-bg-strong + 20 圆角 + modal 阴影
            radius: AylaRadii.rPanel,
            padding: null,
            shadow: AylaShadows.modal,
            child: AylaPostEditor(onSubmit: submit, groups: groups),
          ),
        ),
        box(
          '群内 collapsible 收起态（单行 · 点输入框展开）',
          420,
          GlassCard(
            radius: AylaRadii.rCard,
            padding: null,
            child: AylaPostEditor(
              onSubmit: submit,
              group: 'g1',
              groups: groups,
              compact: true,
              collapsible: true,
            ),
          ),
        ),
        box(
          '群内 collapsible 展开态（收起钮 + 可见性锁定本群 + 媒体预览）',
          480,
          GlassCard(
            radius: AylaRadii.rCard,
            padding: null,
            child: AylaPostEditor(
              onSubmit: submit,
              group: 'g1',
              groups: groups,
              compact: true,
              collapsible: true,
              expanded: true,
              initialTitle: '今晚的歌单',
              initialBody: '今晚的歌单在这里，欢迎点歌。',
              initialImages: media,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 发帖编辑器三态预览。
@Preview(
  group: 'Cards',
  name: 'AylaPostEditor 常规 / 群内收起 / 群内展开',
  size: Size(1560, 640),
  wrapper: previewScope,
)
Widget aylaPostEditorPreview() => aylaPostEditorSamples();
