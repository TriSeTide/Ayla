/// 评论族 —— AylaCommentList / AylaCommentComposer。
///
/// 事实源（逐条对应，无自由发挥）：
/// - `Ayla/web/src/components/posts/CommentList.tsx`（203 行）
/// - `Ayla/web/src/components/posts/CommentComposer.tsx`（226 行）
/// - `styles/posts.css:420–583`（.comment-* / .comment-composer / .composer-pending-*）
/// - `styles/app.css:2105–2137`（.composer-row / .composer-input / .composer-tool-btn 基类）
/// - `styles/auroraqua.css:105–112/124–166`（工具钮材质与交互覆写）
///
/// 关键事实（回读确认）：
/// 1. `.comment-image` / `.comment-image-btn` 的 `border-radius: var(--radius-md)` 在 web 全库
///    **未定义** → 声明失效、`border-radius` 回落初始值 **0**（方角）。照实际渲染做方角。
/// 2. 评论图片网格：2 列（`gap: sp1`、`max-width: 280`），单图档 `minmax(0, 200px)`；
///    缩略图统一 `aspect-ratio: 4/3` + `object-fit: cover`。
/// 3. 评论项：头像 32 + 昵称 14/700 + 时间（utility 11，`toLocaleString("zh-CN")`）
///    + 回复提示 12/`slate-500` + 正文 14（`pre-wrap`）+ 操作行 12/600（回复 / 作者可删，删除色
///    `--destructive`）；`.comment-item` 底部 1px `--glass-border`、padding sp3 sp4。
/// 4. 评论输入：`.comment-composer { padding: sp3 sp4; border-top: 1px `--glass-border` }`；
///    `.composer-row { flex; align-items: flex-end; gap: sp3 }`；输入 `.field.composer-input`
///    （flex 1 / min-h 40 / max-h 140 / padding 8×12 / line-height 22）；
///    工具钮 = `.composer-tool-btn`（40×40，auroraqua 覆写为 12 圆角 + 玻璃 + blur8 + glow hover）
///    → 复用 `AylaToolButton`；发送钮 = `.btn.btn-primary`（IconSend 15 + 文案，窄屏只留图标）。
/// 5. 待发图片：≤4 张，64px 方块（radius-sm 8）+ 右上 18px 圆形 ×（`rgba(0,0,0,.55)` 底）。
/// 6. 底部滑入：`transform: translateY(100%) → 0`，250ms `--ease-out`（窄屏详情页复用）。
/// 7. 文案逐字：写评论… / 写评论…（可与图片一起发）/ 添加图片（可多选，与文字一起发送）/
///    最多 4 张图片 / N 张图片上传失败，可重试 / 重试图片（N）/ 移除失败图片 / 发送 / 发送中… /
///    发送失败 / 移除图片失败，请重试 / 图片发送失败 / 还没有评论 / 回复 @N / 取消 / 删除中… / 删除 /
///    查看评论图片 i/N / 回复评论 #N（未在当前列表中）。
///
/// **展示型组件**：图片选择上传、查看器、发送/删除请求由页面注入（同一批的
/// `api/media.ts` 三步上传与 `ImageViewer` 属后续批次）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/media/media_signer.dart' show MediaVariant;
import '../core/models/post.dart';
import '../core/net/dio_client.dart' show ApiException;
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart' show AylaMsgActionButton, AylaToolButton;
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'resource_image.dart';
import 'reveal.dart';

/// 评论时间（web `new Date(iso).toLocaleString("zh-CN")`：`2026/9/20 12:34:56`）。
String aylaCommentTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final DateTime d = parsed.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// 评论输入框（web `CommentComposer.tsx`）。
class AylaCommentComposer extends StatefulWidget {
  const AylaCommentComposer({
    super.key,
    required this.onSend,
    this.replyTarget,
    this.onReplyClear,
    this.inputEntered = true,
    this.inert = false,
    this.onPickImages,
    this.onRemoveImage,
    this.onRetryFailedImages,
    this.initialBody = '',
    this.initialImages = const <AylaPostMediaDraft>[],
  });

  /// 发送（页面注入：body + 图片 mediaId 一起提交，对应 `POST /posts/<id>/comments/`）。
  final Future<void> Function(String body, int? replyTo, List<String> mediaIds)
      onSend;

  /// 回复目标（非空显示回复条）。
  final AylaPostComment? replyTarget;

  /// 取消回复。
  final VoidCallback? onReplyClear;

  /// 底部滑入状态：false → `translateY(100%)`（窄屏详情页复用进直播间的输入框）。
  final bool inputEntered;

  /// 编辑层覆盖时保留草稿、但从焦点与无障碍树隔离（web `inert`）。
  final bool inert;

  /// 选图 + 上传（页面注入；最多 4 张）。[remaining] = 4 减已选。
  final Future<AylaMediaPickResult> Function(
    int remaining,
    ValueChanged<double?> onProgress,
  )? onPickImages;

  /// 移除待发图片（页面注入：deleteMedia）。
  final Future<void> Function(AylaPostMediaDraft draft)? onRemoveImage;

  /// 重试失败图片（页面注入）。
  final Future<AylaMediaPickResult> Function()? onRetryFailedImages;

  /// 初始正文（样张/草稿场景）。
  final String initialBody;

  /// 初始待发图片（样张/草稿场景）。
  final List<AylaPostMediaDraft> initialImages;

  /// 最多图片数（web `MAX_IMAGES = 4`）。
  static const int maxImages = 4;

  @override
  State<AylaCommentComposer> createState() => _AylaCommentComposerState();
}

class _AylaCommentComposerState extends State<AylaCommentComposer> {
  late final TextEditingController _body =
      TextEditingController(text: widget.initialBody);
  late final List<AylaPostMediaDraft> _pending =
      List<AylaPostMediaDraft>.of(widget.initialImages);

  bool _sending = false;
  bool _uploading = false;
  bool _removing = false;
  int _failedCount = 0;
  double? _progress;
  String? _error;

  /// 组件存活守卫（web `active ref`）。
  bool _active = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _body.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _active = false;
    _body.removeListener(_onTextChanged);
    _body.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  String _message(Object error) =>
      error is ApiException ? error.message : '发送失败';

  Future<void> _send() async {
    final String trimmed = _body.text.trim();
    if ((trimmed.isEmpty && _pending.isEmpty) ||
        _busy ||
        _failedCount > 0) {
      return;
    }
    _busy = true;
    final String sentBody = _body.text; // 发送瞬间的正文（用于回写判定）
    final Set<String> sentIds = <String>{
      for (final AylaPostMediaDraft p in _pending) p.mediaId,
    };
    final int? sentReply = widget.replyTarget?.id;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSend(
        trimmed,
        sentReply,
        <String>[for (final AylaPostMediaDraft p in _pending) p.mediaId],
      );
      if (!_active) return;
      setState(() {
        // web：正文只在「本次发送后用户未改动」时清空（~setBody(cur => cur === body ? "" : cur)~）
        if (_body.text == sentBody) _body.clear();
        _pending.removeWhere(
          (AylaPostMediaDraft item) => sentIds.contains(item.mediaId),
        );
        _failedCount = 0;
      });
      // web：回复目标仍是本次发送的目标才清空回复态
      if (sentReply != null && widget.replyTarget?.id == sentReply) {
        widget.onReplyClear?.call();
      }
    } catch (error) {
      if (_active) setState(() => _error = _message(error));
    } finally {
      _busy = false;
      if (_active) setState(() => _sending = false);
    }
  }

  Future<void> _pick() async {
    final Future<AylaMediaPickResult> Function(int, ValueChanged<double?>)?
        picker = widget.onPickImages;
    if (picker == null || _busy || _pending.length >= AylaCommentComposer.maxImages) {
      return;
    }
    final int room = AylaCommentComposer.maxImages - _pending.length;
    _busy = true;
    setState(() {
      _uploading = true;
      _failedCount = 0;
      _error = null;
    });
    try {
      final AylaMediaPickResult result = await picker(room, (double? p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!_active) return;
      setState(() {
        _pending.addAll(result.drafts.take(room));
        _progress = null;
        _failedCount = result.failed;
        if (result.overLimit > 0) {
          _error = '最多 ${AylaCommentComposer.maxImages} 张图片';
        }
        if (result.failed > 0) {
          _error = '${result.failed} 张图片上传失败，可重试';
        }
      });
    } catch (error) {
      if (_active) {
        setState(() {
          _progress = null;
          _error = _message(error);
        });
      }
    } finally {
      _busy = false;
      if (_active) setState(() => _uploading = false);
    }
  }

  Future<void> _retryFailed() async {
    final Future<AylaMediaPickResult> Function()? retry =
        widget.onRetryFailedImages;
    if (retry == null || _busy) return;
    final int room = AylaCommentComposer.maxImages - _pending.length;
    _busy = true;
    setState(() {
      _uploading = true;
      _failedCount = 0;
      _error = null;
    });
    try {
      final AylaMediaPickResult result = await retry();
      if (!_active) return;
      setState(() {
        _pending.addAll(result.drafts.take(room));
        _progress = null;
        _failedCount = result.failed;
        if (result.failed > 0) {
          _error = '${result.failed} 张图片上传失败，可重试';
        }
      });
    } catch (error) {
      if (_active) {
        setState(() {
          _progress = null;
          _error = _message(error);
        });
      }
    } finally {
      _busy = false;
      if (_active) setState(() => _uploading = false);
    }
  }

  /// web removePending：先删服务端对象（deleteMedia），成功才从列表移除。
  Future<void> _remove(AylaPostMediaDraft draft) async {
    if (_busy) return;
    _busy = true;
    setState(() {
      _removing = true;
      _error = null;
    });
    try {
      await widget.onRemoveImage?.call(draft);
      if (!_active) return;
      setState(() {
        _pending.removeWhere(
          (AylaPostMediaDraft p) => p.mediaId == draft.mediaId,
        );
      });
    } catch (error) {
      if (_active) setState(() => _error = _message(error));
    } finally {
      _busy = false;
      if (_active) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool narrow = MediaQuery.of(context).size.width <= 768;
    final bool busy = _sending || _uploading || _removing;
    final AylaPostComment? reply = widget.replyTarget;
    final String replyName = reply == null
        ? ''
        : (reply.author?.displayName ?? '评论');

    // 编辑层覆盖时保留草稿 DOM，但从焦点/无障碍树隔离（web inert）
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (reply != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Row(
              children: <Widget>[
                Text(
                  '回复 @$replyName',
                  style: t.caption.copyWith(
                    fontSize: 13,
                    color: AylaColors.textSecondary,
                  ),
                ),
                const SizedBox(width: AylaSpacing.sp2),
                TextButton(
                  onPressed: widget.onReplyClear,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp1,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '取消', // .comment-action：12/600 slate-500
                    style: t.caption.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AylaColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp1),
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
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Wrap(
              spacing: AylaSpacing.sp2,
              runSpacing: AylaSpacing.sp1,
              children: <Widget>[
                AylaMsgActionButton(
                  label: '重试图片（$_failedCount）',
                  onPressed: busy ? null : () => unawaited(_retryFailed()),
                ),
                AylaMsgActionButton(
                  label: '移除失败图片',
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            _failedCount = 0;
                            _error = null;
                          }),
                ),
              ],
            ),
          ),
        if (_pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Wrap(
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              runSpacing: AylaSpacing.sp2,
              children: <Widget>[
                for (final AylaPostMediaDraft p in _pending)
                  _pendingImage(p, busy: busy),
              ],
            ),
          ),
        if (_progress != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: _progressBar(_progress!),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end, // align-items: flex-end
          children: <Widget>[
            AylaToolButton(
              icon: AylaIcon(aylaIconByName('iconImage')!, size: 18),
              onPressed: (widget.onPickImages == null ||
                      busy ||
                      _pending.length >= AylaCommentComposer.maxImages)
                  ? null
                  : () => unawaited(_pick()),
              semanticLabel: '添加图片（可多选，与文字一起发送）',
            ),
            const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
            Expanded(
              child: GlassInput(
                controller: _body,
                hintText:
                    narrow ? '写评论…' : '写评论…（可与图片一起发）',
                minHeight: 40, // .composer-input min-height 40
                minLines: 1,
                maxLines: 1, // rows={1}（max-height 140 由 web 滚动承担）
                enabled: !busy && !widget.inert,
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp3, // padding: 8px 12px
                  vertical: AylaSpacing.sp2,
                ),
                textStyle: t.body.copyWith(
                  fontSize: 15,
                  height: 22 / 15, // line-height: 22px
                  color: AylaColors.textPrimary,
                ),
                semanticLabel: '写评论',
              ),
            ),
            const SizedBox(width: AylaSpacing.sp3),
            GlassButton(
              label: narrow
                  ? ''
                  : (busy ? '发送中…' : '发送'),
              icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
              minHeight: 40,
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
              onPressed: (busy ||
                      _failedCount > 0 ||
                      (_body.text.trim().isEmpty && _pending.isEmpty))
                  ? null
                  : () => unawaited(_send()),
              semanticLabel: '发送',
            ),
          ],
        ),
      ],
    );

    final Widget padded = Padding(
      // .comment-composer：padding sp3 sp4 + border-top 1px --glass-border
      padding: const EdgeInsets.fromLTRB(
        AylaSpacing.sp4,
        AylaSpacing.sp3,
        AylaSpacing.sp4,
        AylaSpacing.sp3,
      ),
      child: content,
    );

    final Widget bordered = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: padded,
    );

    // transform: translateY(100%) → 0，250ms --ease-out
    final Widget slid = AnimatedSlide(
      offset: widget.inputEntered ? Offset.zero : const Offset(0, 1),
      duration: const Duration(milliseconds: 250),
      curve: AylaCurves.easeOut,
      child: bordered,
    );

    if (!widget.inert) return slid;
    return ExcludeSemantics(
      child: IgnorePointer(child: Opacity(opacity: 1, child: slid)),
    );
  }

  /// `.composer-pending-image`：64px 方块（radius-sm 8）+ 右上 18px 圆形 ×
  /// （`rgba(0,0,0,.55)` 底、白字 12）。
  Widget _pendingImage(AylaPostMediaDraft draft, {required bool busy}) {
    final String thumb = draft.descriptor.thumbnail ??
        mediaContentUrl(draft.mediaId);
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: AylaColors.glassBorder),
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
                child: ResourceImage(
                  src: thumb,
                  alt: '',
                  // variant=thumb：签发 thumbnail 对象（web 同款）
                  variant: draft.descriptor.thumbnail != null
                      ? MediaVariant.thumb
                      : null,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Positioned(
            top: 2, // top: 2px
            right: 2,
            child: Opacity(
              opacity: busy ? 0.55 : 1,
              child: Semantics(
                button: true,
                label: '移除图片（同时从服务器删除）',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: busy ? null : () => unawaited(_remove(draft)),
                  child: Container(
                    width: 18, // 18×18
                    height: 18,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0x8C000000), // rgba(0,0,0,.55)
                      shape: BoxShape.circle,
                    ),
                    child: const Text(
                      '×',
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 12,
                        height: 1,
                        color: Color(0xFFFFFFFF), // #fff
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

  /// 上传进度条（与发帖编辑器同规格：12px 文案 + 4px pill + pink-500 填充）。
  Widget _progressBar(double progress) {
    final int pct = (progress * 100).round();
    return Row(
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
        const SizedBox(width: AylaSpacing.sp2),
        Expanded(
          child: ClipRRect(
            borderRadius: AylaRadii.pill,
            child: SizedBox(
              height: 4,
              child: ColoredBox(
                color: AylaColors.glassBorder,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: const ColoredBox(color: AylaColors.pink500),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}


/// 评论列表（web `CommentList.tsx` + posts.css 420–583）。
///
/// **展示型组件**：发送/删除/看图/作者跳转由页面注入；列表只负责结构与状态
/// （删除中、回复提示、空态、入场）。
class AylaCommentList extends StatefulWidget {
  const AylaCommentList({
    super.key,
    required this.comments,
    required this.onSend,
    this.onDelete,
    this.replyTarget,
    this.onReply,
    this.onReplyClear,
    this.hideComposer = false,
    this.revealItems = false,
    this.suppressEntry = false,
    this.replayKey,
    this.onOpenImages,
    this.onAuthorTap,
    this.isAuthorOnline,
    this.onPickImages,
    this.onRemoveImage,
    this.onRetryFailedImages,
  });

  /// 评论（按 created_at 升序，由页面保证）。
  final List<AylaPostComment> comments;

  /// 发评论（body + 图片 mediaId 一起提交）。
  final Future<void> Function(String body, int? replyTo, List<String> mediaIds)
      onSend;

  /// 删除评论（仅评论作者可删；页面注入）。
  final Future<void> Function(AylaPostComment comment)? onDelete;

  /// 当前回复目标（显示在输入框上方）。
  final AylaPostComment? replyTarget;

  /// 点「回复」。
  final ValueChanged<AylaPostComment>? onReply;

  /// 取消回复。
  final VoidCallback? onReplyClear;

  /// 隐藏输入框（详情页把输入框固定在底部时传 true）。
  final bool hideComposer;

  /// 详情页入场：每条逐条浮入（stagger）。
  final bool revealItems;

  /// 滚动恢复命中：不启动新的入场动画。
  final bool suppressEntry;

  /// 刷新重播键（变化时已入场项整批重播）。
  final Object? replayKey;

  /// 打开评论图片查看器（页面注入 ImageViewer）：[index] 为点击的图片序号。
  final void Function(
    List<AylaMediaDescriptor> images,
    int index,
    String alt,
  )? onOpenImages;

  /// 点评论作者头像。
  final ValueChanged<AylaPostComment>? onAuthorTap;

  /// 作者实时在线（presence 运行事实，页面注入）。
  final bool Function(AylaPostComment comment)? isAuthorOnline;

  /// 输入框的选图/移除/重试回调（透传给内部 [AylaCommentComposer]）。
  final Future<AylaMediaPickResult> Function(
    int remaining,
    ValueChanged<double?> onProgress,
  )? onPickImages;
  final Future<void> Function(AylaPostMediaDraft draft)? onRemoveImage;
  final Future<AylaMediaPickResult> Function()? onRetryFailedImages;

  @override
  State<AylaCommentList> createState() => _AylaCommentListState();
}

class _AylaCommentListState extends State<AylaCommentList> {
  /// 删除中的评论 id（web `deletingRef`：同一评论只发一次请求）。
  final Set<int> _deleting = <int>{};
  final Set<int> _deletingGuard = <int>{};

  Future<void> _delete(AylaPostComment comment) async {
    final Future<void> Function(AylaPostComment)? del = widget.onDelete;
    if (del == null || _deletingGuard.contains(comment.id)) return;
    _deletingGuard.add(comment.id);
    setState(() => _deleting.add(comment.id));
    try {
      await del(comment);
    } finally {
      _deletingGuard.remove(comment.id);
      if (mounted) setState(() => _deleting.remove(comment.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<int, AylaPostComment> byId = <int, AylaPostComment>{
      for (final AylaPostComment c in widget.comments) c.id: c,
    };

    return AylaRevealScope(
      suppress: widget.suppressEntry,
      replayKey: widget.replayKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.comments.isEmpty)
            Padding(
              // .comment-empty：padding sp4 / 13px / text-secondary / 居中
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              child: Text(
                '还没有评论',
                textAlign: TextAlign.center,
                style: AylaTextStyles.of(context).caption.copyWith(
                      fontSize: 13,
                      color: AylaColors.textSecondary,
                    ),
              ),
            )
          else
            for (int i = 0; i < widget.comments.length; i++)
              _item(widget.comments[i], i, byId),
          if (!widget.hideComposer)
            AylaCommentComposer(
              onSend: widget.onSend,
              replyTarget: widget.replyTarget,
              onReplyClear: widget.onReplyClear,
              onPickImages: widget.onPickImages,
              onRemoveImage: widget.onRemoveImage,
              onRetryFailedImages: widget.onRetryFailedImages,
            ),
        ],
      ),
    );
  }

  Widget _item(
    AylaPostComment c,
    int index,
    Map<int, AylaPostComment> byId,
  ) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaPostAuthor? author = c.author;
    final String name = author?.displayName ?? '评论';
    final AylaPostComment? replyTo = c.replyTo == null
        ? null
        : byId[int.tryParse(c.replyTo!) ?? -1];
    final List<AylaMediaDescriptor> imgs = c.allImages;
    final bool isDeleting = _deleting.contains(c.id);

    return AylaRevealItem(
      enabled: widget.revealItems,
      index: index,
      child: DecoratedBox(
        // .comment-item：padding sp3 sp4 + 底部 1px --glass-border
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp4,
            vertical: AylaSpacing.sp3,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AvatarHalo(
                label: name,
                size: 32, // Avatar size={32}
                online: widget.isAuthorOnline?.call(c) ?? false,
                resourceUrl: author?.avatar,
                onTap: author == null
                    ? null
                    : () => widget.onAuthorTap?.call(c),
                semanticLabel: '查看 $name 的个人主页',
              ),
              const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      name, // .comment-nick：14/700 text-primary
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                    Text(
                      aylaCommentTime(c.createdAt), // .comment-time：utility 11
                      style: const TextStyle(
                        fontFamily: AylaFonts.utility,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 11,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                    if (replyTo != null)
                      Text(
                        '回复 @${replyTo.author?.displayName ?? '评论'}', // .comment-reply-hint
                        style: t.caption.copyWith(
                          fontSize: 12,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                    if (c.replyTo != null && replyTo == null)
                      Text(
                        '回复评论 #${c.replyTo!}（未在当前列表中）',
                        style: t.caption.copyWith(
                          fontSize: 12,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                    if (imgs.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AylaSpacing.sp2),
                        child: _images(c, imgs),
                      ),
                    if (c.body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                        child: Text(
                          c.body, // .comment-text：14 / pre-wrap
                          style: t.body.copyWith(
                            fontSize: 14,
                            color: AylaColors.textPrimary,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                      child: Row(
                        children: <Widget>[
                          _action('回复', () => widget.onReply?.call(c)),
                          if (c.isAuthor && widget.onDelete != null) ...<Widget>[
                            const SizedBox(width: AylaSpacing.sp3),
                            _action(
                              isDeleting ? '删除中…' : '删除',
                              isDeleting ? null : () => unawaited(_delete(c)),
                              destructive: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `.comment-action`：12/600 `--slate-500`；删除态 `--destructive`、禁用时 55% 透明。
  Widget _action(String label, VoidCallback? onTap, {bool destructive = false}) {
    final Widget text = Text(
      label,
      style: TextStyle(
        fontFamily: AylaFonts.body,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: destructive ? AylaColors.destructive : AylaColors.textSecondary,
      ),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(opacity: onTap == null ? 0.55 : 1, child: text),
      ),
    );
  }

  /// `.comment-images`：2 列（gap sp1、max-width 280），单图 `minmax(0,200px)`；
  /// 缩略图 4:3 cover，**方角**（web 的 `--radius-md` 未定义，见文件头事实 1）。
  Widget _images(AylaPostComment c, List<AylaMediaDescriptor> imgs) {
    Widget cell(AylaMediaDescriptor media, int i) {
      final String alt = c.body.isEmpty
          ? '评论图片 ${i + 1}'
          : c.body;
      return Semantics(
        button: true,
        label: '查看评论图片 ${i + 1}/${imgs.length}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onOpenImages?.call(imgs, i, alt),
          child: ClipRect(
            child: ResourceImage(
              src: media.thumbnail ?? mediaContentUrl(media.mediaId),
              // 缩略图优先（variant=thumb 签缩略图对象）
              variant: media.thumbnail != null ? MediaVariant.thumb : null,
              alt: '',
              fit: BoxFit.cover, // object-fit: cover
            ),
          ),
        ),
      );
    }

    if (imgs.length == 1) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: AspectRatio(
          aspectRatio: 4 / 3, // aspect-ratio: 4/3
          child: cell(imgs.first, 0),
        ),
      );
    }
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < imgs.length; i += 2) {
      rows.add(
        Row(
          children: <Widget>[
            Expanded(
              child: AspectRatio(aspectRatio: 4 / 3, child: cell(imgs[i], i)),
            ),
            const SizedBox(width: AylaSpacing.sp1), // gap: var(--sp-1)
            Expanded(
              child: i + 1 < imgs.length
                  ? AspectRatio(
                      aspectRatio: 4 / 3,
                      child: cell(imgs[i + 1], i + 1),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280), // max-width: 280px
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: AylaSpacing.sp1),
            rows[i],
          ],
        ],
      ),
    );
  }
}


// ======================= 预览与样张 =======================

/// 评论族样张（组件画布与 @Preview 共用；**单一来源**）。
///
/// 1. 评论列表：3 条（带图 / 带回复提示 / 自己发的可删）+ 底部输入框
/// 2. 评论输入框：回复条 + 待发图片 ×2（64px 方块）
Widget aylaCommentSamples() {
  Future<void> send(String body, int? replyTo, List<String> mediaIds) async {}

  String iso(int minutesAgo) => DateTime.now()
      .subtract(Duration(minutes: minutesAgo))
      .toIso8601String();

  const AylaPostAuthor author = AylaPostAuthor(
    id: 'u1',
    nickname: '星野遥',
    online: true,
  );
  const AylaPostAuthor me = AylaPostAuthor(id: 'me', nickname: '我');
  final AylaPostComment c1 = AylaPostComment(
    id: 1,
    author: author,
    body: '这首歌我也很喜欢，谢谢分享！',
    createdAt: iso(8),
  );
  final AylaPostComment c2 = AylaPostComment(
    id: 2,
    author: author,
    body: '现场版更棒～',
    replyTo: '1',
    images: const <AylaMediaDescriptor>[
      AylaMediaDescriptor(
        mediaId: 'c-img-1',
        kind: AylaMediaKind.image,
        thumbnail: '/api/v1/media/c-img-1/thumbnail',
      ),
      AylaMediaDescriptor(
        mediaId: 'c-img-2',
        kind: AylaMediaKind.image,
        thumbnail: '/api/v1/media/c-img-2/thumbnail',
      ),
    ],
    createdAt: iso(3),
  );
  final AylaPostComment c3 = AylaPostComment(
    id: 3,
    author: me,
    body: '（自己发的评论 → 有删除入口）',
    isAuthor: true,
    createdAt: iso(1),
  );

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
          '评论列表（带图 / 回复提示 / 自己可删 + 输入框）',
          520,
          GlassCard(
            strong: true,
            radius: AylaRadii.rPanel,
            padding: null,
            shadow: AylaShadows.modal,
            child: AylaCommentList(
              comments: <AylaPostComment>[c1, c2, c3],
              onSend: send,
              onDelete: (AylaPostComment c) async {},
              onReply: (AylaPostComment c) {},
              onReplyClear: () {},
              revealItems: true,
              isAuthorOnline: (AylaPostComment c) => c.author?.online ?? false,
            ),
          ),
        ),
        box(
          '评论输入框（回复条 + 待发图片 ×2）',
          520,
          GlassCard(
            strong: true,
            radius: AylaRadii.rPanel,
            padding: null,
            shadow: AylaShadows.modal,
            child: AylaCommentComposer(
              onSend: send,
              replyTarget: c1,
              onReplyClear: () {},
              initialImages: const <AylaPostMediaDraft>[
                AylaPostMediaDraft(
                  mediaId: 'p-1',
                  descriptor: AylaMediaDescriptor(
                    mediaId: 'p-1',
                    kind: AylaMediaKind.image,
                    thumbnail: '/api/v1/media/p-1/thumbnail',
                  ),
                ),
                AylaPostMediaDraft(
                  mediaId: 'p-2',
                  descriptor: AylaMediaDescriptor(
                    mediaId: 'p-2',
                    kind: AylaMediaKind.image,
                    thumbnail: '/api/v1/media/p-2/thumbnail',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// 评论族预览。
@Preview(
  group: 'Cards',
  name: 'AylaCommentList / AylaCommentComposer',
  size: Size(1240, 720),
  wrapper: previewScope,
)
Widget aylaCommentPreview() => aylaCommentSamples();
