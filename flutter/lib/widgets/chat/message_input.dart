/// 消息输入区（`components/chat/MessageInput.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMessageInput] | `MessageInput.tsx:329–593`（两形态布局 + 状态行 + 工具键 + 发送键） |
/// | 外壳（窄屏） | `.composer`：column + gap 8 + padding 12/24/16 + `--glass-bg` + blur18 sat1.4 + 上边框（app.css 1983–1993 / 3206–3209） |
/// | 外壳（宽屏） | auroraqua.css 347–358：padding **8** + 1px 边 + **radius-card 16** + `--glass-shadow` + blur24 sat1.4；`margin: var(--sidebar-gutter)` = **12px**（`tokens.css:132` **确有定义** —— 2026-09-28 更正原「死声明」误判）⇒ 本件当前未表达该 12px 外边距，属待裁决偏离 |
/// | 引用条 | `.quote-bar`（左 3px `--ice-500` + `rgba(255,250,251,.6)` + radius 12 + label 12/700 + text 13 省略 + 28 圆取消键）（2484–2527） |
/// | 待发媒体 | `.composer-picked`（44×44 缩略图 / 视频 58 宽 / 文件条 120–180 + 18 圆移除键）（2001–2093） |
/// | 状态行 | `.composer-uploading`（1995–1998）/ `.composer-error`（2096–2103）/ `.composer-muted-hint` |
/// | 工具键 | `.composer-tool-btn`：40×40 / **radius 12**（auroraqua 105–112 覆写 pill）/ `--glass-bg` + 1px 边 + compact 阴影 + blur8；hover → 边 `--glow-500` + `--glow-shadow` → 复用 [AylaToolButton] |
/// | 编辑器 | `.field.composer-input.composer-editor`：min-h 40 / max-h 140 / padding 8/12 / line-height 22（2131–2165） |
/// | 发送键 | `.btn.btn-primary.composer-send`（宽屏带「发送」，窄屏只图标）（2166–2168） |
/// | 窄屏工具行 | `.composer-tools-narrow`：等宽占满整行（图片/语音/表情/文件）（2171–2185） |
/// | 录音态 | `.voice-recording-hint`（红点 10 呼吸 + 「正在录音 m:ss」）+ `.composer-voice-stop`（destructive 档）/`.composer-voice-cancel`（2431–2483） |
/// | @ / 表情面板 | `MentionPicker`（anchor = 编辑器）/ `EmojiPackPanel`（宽屏贴 composer 上方、窄屏向下展开） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **@ 编辑器**：web 是 `contentEditable` + `contenteditable=false` span；Flutter 用
///    单字符占位符 `\uFFFC` + [AylaMentionTextController]（胶囊渲染 + 整块删除），
///    草稿仍走 `@[user_id]`（两端格式一致）——见 `mention_editor.dart`；
/// 2. **粘贴媒体**：Flutter 桌面端没有标准「从剪贴板取图片文件」API（`Clipboard` 只有文本）
///    ⇒ **不做粘贴进队列**（保留图片/视频/文件三个选择入口）；web 的 `onPaste` 分支未实现；
/// 3. **表情面板定位**：web 是相对 `.composer` 的 `absolute bottom: calc(100% + 8px)`；
///    Flutter 宽屏改由 **root Overlay** 承载（溢出父边界的浮层收不到指针，§6.36 真 bug 4），
///    窄屏走 `position: static` 档（向下展开）——与 `AylaMentionPickerHost` 同口径；
/// 4. **上传不在这里**：web 的 `sendOptimistic`（hook 层）负责上传 + 乐观发送 ⇒
///    本件只把 [AylaMessageInputSubmission] 交回调用方（语音路径除外：web 也在组件内上传发送）。
///
/// ## 公开面
/// `AylaPickedMedia` · `AylaMessageInputSubmission` · `AylaMessageInput` · 样张 `aylaMessageInputSamples()`

library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../core/media/media_picker.dart'
    show AylaMediaPicker, AylaPickedFile, AylaPickResult;
import '../../core/media/voice_recorder.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/conversation.dart';
import '../../core/models/media_kind.dart';
import '../../core/models/mention.dart';
import '../../core/models/user_public.dart';
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import 'mention_editor.dart';
import 'mention_picker.dart';
import '../base/overlays.dart';
import '../base/tooltip.dart';

/// 待发媒体项（web `PickedMediaItem`）：本地文件 + 类型（未上传）。
class AylaPickedMedia {
  const AylaPickedMedia({
    required this.id,
    required this.kind,
    required this.file,
  });

  final String id;

  /// `image` / `video` / `file`（web：`kind`）。
  final AylaMediaKind kind;

  final AylaPickedFile file;
}

/// 一次提交（web `sendOptimistic(convId, { blocks, picked, replyTo }, subgroupId)`）。
class AylaMessageInputSubmission {
  const AylaMessageInputSubmission({
    required this.blocks,
    required this.picked,
    this.replyToId,
  });

  final List<AylaDraftBlock> blocks;
  final List<AylaPickedMedia> picked;
  final String? replyToId;

  /// 空提交判定（tsx 248：无文本、无媒体、无 @ ⇒ 不发）。
  bool get isEmpty =>
      aylaBlocksText(blocks).trim().isEmpty &&
      picked.isEmpty &&
      !aylaBlocksHasMention(blocks);
}

/// 消息输入区。
class AylaMessageInput extends StatefulWidget {
  const AylaMessageInput({
    super.key,
    required this.onSubmit,
    this.quote,
    this.onQuoteClear,
    this.members = const <AylaConversationMember>[],
    this.groupId,
    this.subgroupId,
    this.disabled = false,
    this.disabledHint,
    this.narrow = false,
    this.draftKey = '',
    this.initialDraft = '',
    this.onDraftChanged,
    this.onTyping,
    this.voiceRecorder,
    this.onUploadVoice,
    this.onSendVoice,
    this.emojiPanel,
    this.pickImages,
    this.pickVideo,
    this.pickFile,
    this.showEmojiButton = false,
  });

  /// 提交（页面层负责上传 + 乐观发送）。
  final void Function(AylaMessageInputSubmission submission) onSubmit;

  /// 正在引用的消息（null = 无）。
  final AylaChatMessage? quote;
  final VoidCallback? onQuoteClear;

  /// 群成员（仅群聊启用 @；私聊传空）。
  final List<AylaConversationMember> members;
  final String? groupId;
  final String? subgroupId;

  /// 子群禁言：禁用输入与发送（普通成员视角）。
  final bool disabled;
  final String? disabledHint;

  /// 窄屏形态（工具键在输入框下方一行）。
  final bool narrow;

  /// 草稿键（会话 + 子群）与初始草稿字符串（`@[user_id]` 序列化格式）。
  final String draftKey;
  final String initialDraft;

  /// 草稿变化（等价 web `setDraft(draftKey, serializeBlocks(blocks))`）。
  final void Function(String draftKey, String serialized)? onDraftChanged;

  /// typing 上报（私聊；web `useTyping(convId).onInput`）。
  final VoidCallback? onTyping;

  /// 语音录制器（null = 隐藏录音入口；生产传 [AylaRecordVoiceRecorder]）。
  final AylaVoiceRecorder? voiceRecorder;

  /// 语音上传（web `uploadMediaFile(file, "voice")`）→ media_id。
  final Future<String> Function(AylaPickedFile file)? onUploadVoice;

  /// 语音发送（web `sendMessage(convId, "", { type: voice, mediaId, replyTo, idempotencyKey })`）。
  final Future<void> Function({
    required String mediaId,
    int? replyTo,
    required String idempotencyKey,
  })? onSendVoice;

  /// 群表情包面板（调用方构造 [AylaEmojiPackPanel]，本件只负责开合与定位）。
  final Widget? emojiPanel;

  /// 选媒体（默认用 `AylaMediaPicker`；测试/预览注入替身）。
  final Future<AylaPickResult> Function()? pickImages;
  final Future<AylaPickResult> Function()? pickVideo;
  final Future<AylaPickResult> Function()? pickFile;

  /// 是否显示群表情包键（web：`isGroup`）。
  final bool showEmojiButton;

  @override
  State<AylaMessageInput> createState() => _AylaMessageInputState();
}

class _AylaMessageInputState extends State<AylaMessageInput> {
  final AylaMentionTextController _controller = AylaMentionTextController();
  final GlobalKey _editorKey = GlobalKey();
  final GlobalKey _composerKey = GlobalKey();
  final AylaMentionPickerHost _mentionHost = AylaMentionPickerHost();
  final List<AylaPickedMedia> _picked = <AylaPickedMedia>[];

  OverlayEntry? _emojiEntry;
  String? _error;
  bool _mentionOpen = false;
  String _mentionQuery = '';
  bool _emojiOpen = false;
  bool _voiceUploading = false;
  _FailedVoice? _failedVoice;

  /// 未注入 [AylaMessageInput.voiceRecorder] 时**懒创建**的录音器。
  ///
  /// web 是 hook 内部持有录音器实例、由 `isVoiceRecordingSupported()` 决定是否渲染入口；
  /// 本件同口径：**入口按平台支持显示**，实例在首次点击录音键时才创建
  /// （避免预览/测试环境构造时就碰平台通道）。
  AylaVoiceRecorder? _ownRecorder;

  /// 当前录音器（注入优先，否则懒创建的那一个）。
  AylaVoiceRecorder? get _recorder => widget.voiceRecorder ?? _ownRecorder;

  /// 是否渲染录音入口（web `isVoiceRecordingSupported()`）。
  bool get _voiceAvailable =>
      _recorder?.isSupported ?? aylaVoiceRecordingSupported();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEditorChanged);
    if (widget.initialDraft.isNotEmpty) {
      _controller.setBlocks(
        aylaParseBlocks(widget.initialDraft, _nameOf),
      );
    }
    widget.voiceRecorder?.listenable.addListener(_onVoiceChanged);
  }

  @override
  void didUpdateWidget(covariant AylaMessageInput old) {
    super.didUpdateWidget(old);
    if (old.draftKey != widget.draftKey) {
      // 切换会话/子群 → 恢复草稿并重置面板（tsx 134–146）
      _controller.setBlocks(aylaParseBlocks(widget.initialDraft, _nameOf));
      _closeMention();
      _closeEmoji();
      setState(() {
        _error = null;
        _failedVoice = null;
      });
    }
    if (old.voiceRecorder != widget.voiceRecorder) {
      old.voiceRecorder?.listenable.removeListener(_onVoiceChanged);
      widget.voiceRecorder?.listenable.addListener(_onVoiceChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onEditorChanged);
    widget.voiceRecorder?.listenable.removeListener(_onVoiceChanged);
    _ownRecorder?.listenable.removeListener(_onVoiceChanged);
    unawaited(_ownRecorder?.close());
    _mentionHost.close();
    _emojiEntry?.remove();
    _emojiEntry = null;
    _controller.dispose();
    super.dispose();
  }

  void _onVoiceChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String? _nameOf(String id) {
    for (final AylaConversationMember m in widget.members) {
      if (m.user.id == id) return m.user.displayName;
    }
    return null;
  }

  bool get _canMention => widget.groupId != null && widget.members.isNotEmpty;

  /// 编辑器输入 → 存草稿 + typing + @ 检测（tsx 194–210）。
  ///
  /// ⚠️ 纯文本输入路径**必须 setState**：发送键的可用性 `canSend` 依赖
  /// 「文本/媒体/@ 三条件」（tsx 321–324），不重建则按钮永远停留在初始禁用态
  /// （实测：输入文本后点「发送」无反应）。
  void _onEditorChanged() {
    if (!mounted) return;
    final List<AylaDraftBlock> blocks = _controller.extractBlocks();
    widget.onDraftChanged?.call(widget.draftKey, aylaSerializeBlocks(blocks));
    widget.onTyping?.call();
    final ({int atIndex, String query})? detected =
        _canMention ? _controller.detectMention() : null;
    if (detected != null) {
      setState(() {
        _mentionQuery = detected.query;
        _mentionOpen = true;
      });
      _mentionHost.open(
        context,
        anchorKey: _editorKey,
        members: widget.members,
        query: detected.query,
        groupId: widget.groupId,
        onSelect: _selectMention,
      );
      return;
    }
    if (_mentionOpen) {
      _closeMention();
      return;
    }
    setState(() {});
  }

  /// 选中成员 → 插入不可拆分 @Token（tsx 213–224）。
  void _selectMention(AylaConversationMember member) {
    final String? name = member.user.displayName;
    if (name == null) return;
    _controller.insertMention(userId: member.user.id, name: name);
    widget.onDraftChanged?.call(
      widget.draftKey,
      aylaSerializeBlocks(_controller.extractBlocks()),
    );
    _closeMention();
  }

  void _closeMention() {
    _mentionHost.close();
    if (!mounted) return;
    if (_mentionOpen || _mentionQuery.isNotEmpty) {
      setState(() {
        _mentionOpen = false;
        _mentionQuery = '';
      });
    }
  }

  /// 长按头像 @ 的插入路径（web `insertMentionToken`，由父级 ref 调用）。
  void insertMention(String userId, String name) {
    _controller.insertMentionToken(userId: userId, name: name);
    widget.onDraftChanged?.call(
      widget.draftKey,
      aylaSerializeBlocks(_controller.extractBlocks()),
    );
    _closeMention();
  }

  // ======================= 媒体入队（tsx 149–191） =======================

  Future<void> _enqueue(Future<AylaPickResult> Function() picker) async {
    final AylaPickResult result = await picker();
    if (!mounted) return;
    final String? error = result.error;
    if (error != null) {
      setState(() => _error = error);
    }
    if (result.files.isEmpty) return;
    final List<AylaPickedMedia> added = <AylaPickedMedia>[
      for (final AylaPickedFile f in result.files)
        AylaPickedMedia(
          id: '${DateTime.now().microsecondsSinceEpoch}-${f.name}',
          kind: _kindOf(f),
          file: f,
        ),
    ];
    // 单文件互斥：file 与图片/视频不能混排（file 是单媒体消息契约，tsx 169–180）
    final bool hasFile = added.any((AylaPickedMedia p) => p.kind == AylaMediaKind.file);
    final bool prevHasFile = _picked.any((AylaPickedMedia p) => p.kind == AylaMediaKind.file);
    setState(() {
      if (hasFile || prevHasFile) {
        _picked
          ..clear()
          ..addAll(added);
      } else {
        _picked.addAll(added);
      }
      _error = null;
    });
  }

  static AylaMediaKind _kindOf(AylaPickedFile f) {
    final String mime = f.mimeType;
    if (mime.startsWith('image/')) return AylaMediaKind.image;
    if (mime.startsWith('video/')) return AylaMediaKind.video;
    return AylaMediaKind.file;
  }

  void _removePicked(String id) {
    setState(() => _picked.removeWhere((AylaPickedMedia p) => p.id == id));
  }

  // ======================= 提交（tsx 245–262） =======================

  bool get _canSend {
    if (widget.disabled) return false;
    if (_recorder?.recording ?? false) return false;
    final List<AylaDraftBlock> blocks = _controller.extractBlocks();
    return aylaBlocksText(blocks).trim().isNotEmpty ||
        aylaBlocksHasMention(blocks) ||
        _picked.isNotEmpty;
  }

  void _submit() {
    if (!_canSend) return;
    final List<AylaDraftBlock> blocks = _controller.extractBlocks();
    widget.onSubmit(
      AylaMessageInputSubmission(
        blocks: blocks,
        picked: List<AylaPickedMedia>.of(_picked),
        replyToId: widget.quote?.id,
      ),
    );
    // 发送即清空（消息已进列表），可立即输入下一条
    _controller.setBlocks(const <AylaDraftBlock>[]);
    widget.onDraftChanged?.call(widget.draftKey, '');
    setState(() {
      _picked.clear();
      _error = null;
    });
    if (widget.quote != null) widget.onQuoteClear?.call();
  }

  // ======================= 语音（tsx 264–318） =======================

  Future<void> _startVoice() async {
    // 懒创建（首次点击才构造，避免预览/测试环境碰平台通道）
    if (widget.voiceRecorder == null && _ownRecorder == null) {
      final AylaRecordVoiceRecorder created = AylaRecordVoiceRecorder();
      created.listenable.addListener(_onVoiceChanged);
      setState(() => _ownRecorder = created);
    }
    final AylaVoiceRecorder? rec = _recorder;
    if (rec == null) return;
    await rec.start();
  }

  Future<void> _stopAndSendVoice() async {
    final AylaVoiceRecorder? rec = _recorder;
    if (rec == null) return;
    final AylaVoiceRecording? recording = await rec.stop();
    if (!mounted || recording == null) return;
    // 过短（< 0.8s）视为无效丢弃（tsx 308）
    if (recording.duration < 0.8) {
      setState(() => _error = null);
      return;
    }
    await _sendVoice(recording);
  }

  Future<void> _sendVoice(AylaVoiceRecording recording, {_FailedVoice? previous}) async {
    final Future<String> Function(AylaPickedFile)? upload = widget.onUploadVoice;
    final Future<void> Function({
      required String mediaId,
      int? replyTo,
      required String idempotencyKey,
    })? send = widget.onSendVoice;
    if (upload == null || send == null) return;
    final _FailedVoice attempt = previous ??
        _FailedVoice(
          recording: recording,
          idempotencyKey: _newId(),
          replyTo: int.tryParse(widget.quote?.id ?? ''),
        );
    setState(() {
      _voiceUploading = true;
      _error = null;
      _failedVoice = null;
    });
    try {
      String? mediaId = attempt.mediaId;
      if (mediaId == null) {
        final AylaPickedFile file = AylaPickedFile(
          name: recording.fileName,
          size: recording.size,
          mimeType: recording.mimeType,
          readBytes: () => _readFile(recording.path),
          path: recording.path,
        );
        mediaId = await upload(file);
        attempt.mediaId = mediaId;
      }
      if (!mounted) return;
      await send(
        mediaId: mediaId,
        replyTo: attempt.replyTo,
        idempotencyKey: attempt.idempotencyKey,
      );
      if (!mounted) return;
      if (attempt.replyTo != null &&
          int.tryParse(widget.quote?.id ?? '') == attempt.replyTo) {
        widget.onQuoteClear?.call();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failedVoice = attempt;
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _voiceUploading = false);
    }
  }

  Future<void> _retryVoice() async {
    final _FailedVoice? failed = _failedVoice;
    if (failed == null) return;
    setState(() {
      _failedVoice = null;
      _error = null;
    });
    await _sendVoice(failed.recording, previous: failed);
  }

  static Future<Uint8List> _readFile(String path) async {
    final File file = File(path);
    return file.readAsBytes();
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  // ======================= 表情面板（宽屏 overlay / 窄屏 inline） =======================

  void _toggleEmoji() {
    if (_emojiOpen) {
      _closeEmoji();
      return;
    }
    final Widget? panel = widget.emojiPanel;
    if (panel == null) return;
    setState(() => _emojiOpen = true);
    if (widget.narrow) return; // 窄屏 inline（向下展开）
    final RenderObject? anchor = _composerKey.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.hasSize) return;
    final Rect rect = anchor.localToGlobal(Offset.zero) & anchor.size;
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => Positioned(
        // web：`left/right: sp3; bottom: calc(100% + 8px)`（相对 composer）
        left: rect.left + AylaSpacing.sp3,
        width: rect.width - AylaSpacing.sp3 * 2,
        bottom: MediaQuery.sizeOf(ctx).height - rect.top + 8,
        child: panel,
      ),
    );
    _emojiEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closeEmoji() {
    _emojiEntry?.remove();
    _emojiEntry = null;
    if (mounted && _emojiOpen) setState(() => _emojiOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = widget.narrow ? _narrowBody() : _wideBody();

    final Widget shell = widget.narrow
        // 窄屏：`.composer` 方角 + 上边框 + blur18 sat1.4 + `--glass-bg`
        ? AylaGlassSurface(
            radiusOverride: BorderRadius.zero,
            borderOverride: const Border(
              top: BorderSide(color: AylaColors.glassBorder),
            ),
            blur: AylaGlass.blurNav,
            shadow: const <BoxShadow>[],
            padding: const EdgeInsets.fromLTRB(
              AylaSpacing.sp3,
              AylaSpacing.sp2,
              AylaSpacing.sp3,
              AylaSpacing.sp3,
            ),
            child: body,
          )
        // 宽屏：auroraqua 347–358 的浮动卡（padding 8 / radius 16 / glass-shadow / blur24）
        : AylaGlassSurface(
            radius: AylaRadii.rCard,
            blur: AylaGlass.blurCard,
            shadow: AylaShadows.glass,
            padding: const EdgeInsets.all(AylaSpacing.sp2),
            child: body,
          );

    return KeyedSubtree(key: _composerKey, child: shell);
  }

  Widget _wideBody() => _content(
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            _tools(isNarrowRow: false),
            const SizedBox(width: AylaSpacing.sp3),
            Expanded(child: _editor()),
            const SizedBox(width: AylaSpacing.sp3),
            _sendButton(showLabel: true),
          ],
        ),
      );

  Widget _narrowBody() => _content(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(child: _editor()),
                const SizedBox(width: AylaSpacing.sp3),
                _sendButton(showLabel: false),
              ],
            ),
            const SizedBox(height: AylaSpacing.sp2),
            _tools(isNarrowRow: true),
            if (_emojiOpen && widget.emojiPanel != null) ...<Widget>[
              const SizedBox(height: AylaSpacing.sp2),
              widget.emojiPanel!,
            ],
          ],
        ),
      );

  /// 状态行 + 引用条 + 待发媒体 + 录音/上传/错误（tsx 331–397）。
  Widget _content(Widget row) {
    final AylaChatMessage? quote = widget.quote;
    final AylaVoiceRecorder? rec = _recorder;
    final bool recording = rec?.recording ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.disabled && widget.disabledHint != null) ...<Widget>[
          Text(
            widget.disabledHint!,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (quote != null) ...<Widget>[
          _quoteBar(quote),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (_picked.isNotEmpty) ...<Widget>[
          _pickedStrip(),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (_voiceUploading) ...<Widget>[
          const Text(
            '语音上传中…',
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (rec?.starting ?? false) ...<Widget>[
          const Text(
            '正在请求麦克风…',
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (_error != null) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 13,
                    color: AylaColors.destructive,
                  ),
                ),
              ),
              if (_failedVoice != null) ...<Widget>[
                const SizedBox(width: AylaSpacing.sp2),
                AylaMsgActionButton(
                  label: '重试语音',
                  onPressed: _voiceUploading ? null : () => _retryVoice(),
                ),
              ],
            ],
          ),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (rec != null && rec.error != null && _error == null) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  rec.error!,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 13,
                    color: AylaColors.destructive,
                  ),
                ),
              ),
              const SizedBox(width: AylaSpacing.sp2),
              AylaMsgActionButton(label: '关闭', onPressed: rec.clearError),
            ],
          ),
          const SizedBox(height: AylaSpacing.sp2),
        ],
        if (recording) _recordingRow(rec!) else row,
      ],
    );
  }

  /// `.quote-bar`（app.css 2484–2527）。
  Widget _quoteBar(AylaChatMessage quote) {
    final String text = quote.content.trim().isEmpty ? '…' : quote.content.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AylaRadii.rInput),
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: AylaColors.ice500),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(
              AylaSpacing.sp3 + 3,
              AylaSpacing.sp2,
              AylaSpacing.sp2,
              AylaSpacing.sp2,
            ),
            color: const Color(0x99FFFAFB), // rgba(255,250,251,.6)
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        '引用回复',
                        style: TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 13,
                          color: AylaColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AylaSpacing.sp3),
                _roundIconButton(
                  icon: 'iconClose',
                  size: 28,
                  iconSize: 14,
                  semanticLabel: '取消引用',
                  onTap: widget.onQuoteClear,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `.composer-picked`（app.css 2001–2093）：44 缩略图 / 视频 58 / 文件条 120–180。
  Widget _pickedStrip() {
    return Wrap(
      spacing: AylaSpacing.sp2,
      runSpacing: AylaSpacing.sp2,
      children: <Widget>[
        for (final AylaPickedMedia item in _picked) _pickedCell(item),
      ],
    );
  }

  Widget _pickedCell(AylaPickedMedia item) {
    final bool isVideo = item.kind == AylaMediaKind.video;
    final bool isFile = item.kind == AylaMediaKind.file;
    final double width = isFile ? 150 : (isVideo ? 58 : 44);
    return SizedBox(
      width: width,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: Container(
              padding: isFile
                  ? const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2)
                  : null,
              decoration: BoxDecoration(
                color: AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
                border: Border.all(color: AylaColors.glassBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: isFile
                  ? Row(
                      children: <Widget>[
                        AylaIcon(aylaIconByName('iconFile')!, size: 16),
                        const SizedBox(width: AylaSpacing.sp1),
                        Expanded(
                          // web «MessageInput.tsx:359»：待发文件 «span.picked-file title={p.file.name}»
                          child: AylaTooltip(
                            message: item.file.name,
                            child: Text(
                              item.file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: AylaFonts.body,
                                fontFamilyFallback: AylaFonts.cjkFallback,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AylaColors.indigo700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _pickedPreview(item, isVideo: isVideo),
            ),
          ),
          if (isVideo)
            const Positioned.fill(
              child: Center(
                child: Text(
                  '▶',
                  style: TextStyle(fontSize: 9, color: AylaColors.indigo700),
                ),
              ),
            ),
          Positioned(
            top: -5,
            right: -5,
            child: _roundIconButton(
              icon: 'iconClose',
              size: 18,
              iconSize: 10,
              semanticLabel: '移除',
              onTap: () => _removePicked(item.id),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickedPreview(AylaPickedMedia item, {required bool isVideo}) {
    final String? path = item.file.path;
    if (path == null) {
      return const ColoredBox(color: AylaColors.glassBg);
    }
    if (isVideo) {
      // web 用 `<video preload=metadata muted>` 首帧；Flutter 侧本地视频首帧需播放器
      // ⇒ 用文件图标占位（登记：视频待发缩略图不做首帧，见文件头差异说明）
      return const Center(
        child: Icon(Icons.movie_outlined, size: 18, color: AylaColors.indigo700),
      );
    }
    return Image.file(File(path), fit: BoxFit.cover);
  }

  /// 录音态行（tsx 399–423）。
  Widget _recordingRow(AylaVoiceRecorder rec) {
    return Row(
      children: <Widget>[
        const _RecDot(),
        const SizedBox(width: AylaSpacing.sp2),
        Expanded(
          child: Text(
            '正在录音 ${_formatDuration(rec.elapsed.inMilliseconds / 1000)}',
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AylaColors.destructive,
            ),
          ),
        ),
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 18),
          danger: true,
          semanticLabel: '停止并发送语音',
          onPressed: _voiceUploading ? null : () => _stopAndSendVoice(),
        ),
        const SizedBox(width: AylaSpacing.sp2),
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconClose')!, size: 16),
          semanticLabel: '取消录音',
          onPressed: _voiceUploading ? null : () => rec.cancel(),
        ),
      ],
    );
  }

  /// 工具键组（宽屏在输入框左；窄屏在下方等宽一行）。
  Widget _tools({required bool isNarrowRow}) {
    // web：`isVoiceRecordingSupported()` 为真即渲染录音键（未注入时按平台支持判断）
    final bool voiceAvailable = _voiceAvailable;
    final List<Widget> buttons = <Widget>[
      AylaToolButton(
        icon: AylaIcon(aylaIconByName('iconImage')!, size: 18),
        semanticLabel: '发送图片或视频',
        onPressed: widget.disabled
            ? null
            : () => _enqueue(widget.pickImages ?? () => AylaMediaPicker.pickImages()),
      ),
      if (!isNarrowRow)
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconFile')!, size: 18),
          semanticLabel: '发送文件',
          onPressed: widget.disabled
              ? null
              : () => _enqueue(widget.pickFile ?? () => AylaMediaPicker.pickFile()),
        ),
      if (voiceAvailable)
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconMic')!, size: 18),
          semanticLabel: '发送语音',
          onPressed: widget.disabled ||
                  (_recorder?.recording ?? false) ||
                  (_recorder?.starting ?? false) ||
                  _voiceUploading
              ? null
              : () => _startVoice(),
        ),
      if (widget.showEmojiButton && widget.emojiPanel != null)
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconEmoji')!, size: 18),
          semanticLabel: '群表情包',
          onPressed: widget.disabled ? null : _toggleEmoji,
        ),
      // 窄屏顺序：图片 / 语音 / 表情 / 文件（tsx 536–587）
      if (isNarrowRow)
        AylaToolButton(
          icon: AylaIcon(aylaIconByName('iconFile')!, size: 18),
          semanticLabel: '发送文件',
          onPressed: widget.disabled
              ? null
              : () => _enqueue(widget.pickFile ?? () => AylaMediaPicker.pickFile()),
        ),
    ];
    if (!isNarrowRow) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < buttons.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: AylaSpacing.sp2),
            buttons[i],
          ],
        ],
      );
    }
    // `.composer-tools-narrow { justify-content: space-between; padding: 0 sp1 }`
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: buttons,
      ),
    );
  }

  /// 编辑器（`.field.composer-input.composer-editor`：min-h 40 / max-h 140 / padding 8 12 / lh 22）。
  Widget _editor() {
    final String placeholder = widget.narrow
        ? '输入消息'
        : '输入消息，回车发送（Shift+Enter 换行）；群聊输入 @ 可提及成员';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 140),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          // Enter 发送；Shift+Enter 不在此处（落到 TextField 换行），tsx 501–504
          const SingleActivator(LogicalKeyboardKey.enter): _submit,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_mentionOpen) {
              _closeMention();
            } else if (_emojiOpen) {
              _closeEmoji();
            }
          },
        },
        child: AylaGlassInput(
          key: _editorKey,
          controller: _controller,
          hintText: placeholder,
          enabled: !widget.disabled,
          minHeight: 40,
          minLines: 1,
          maxLines: null,
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3,
            vertical: AylaSpacing.sp2,
          ),
          textStyle: const TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 15,
            height: 22 / 15, // line-height: 22px
            color: AylaColors.textPrimary,
          ),
          semanticLabel: '消息输入框',
        ),
      ),
    );
  }

  /// `.btn.btn-primary.composer-send`（宽屏带「发送」；窄屏只图标）。
  Widget _sendButton({required bool showLabel}) {
    return AylaGlassButton(
      label: showLabel ? '发送' : '',
      variant: AylaGlassButtonVariant.primary,
      icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
      minHeight: 40,
      onPressed: _canSend ? _submit : null,
      semanticLabel: '发送',
    );
  }

  /// 小圆图标键（`.picked-remove` / `.quote-bar-cancel`）。
  Widget _roundIconButton({
    required String icon,
    required double size,
    required double iconSize,
    required String semanticLabel,
    VoidCallback? onTap,
  }) {
    final AylaIconData? data = aylaIconByName(icon);
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AylaColors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: Center(
            child: data == null
                ? const SizedBox.shrink()
                : AylaIcon(data, size: iconSize, color: AylaColors.textSecondary),
          ),
        ),
      ),
    );
  }

  static String _formatDuration(double seconds) {
    final int total = seconds < 0 ? 0 : seconds.round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// 失败待重试的语音（tsx 34–41 `FailedVoice`）。
class _FailedVoice {
  _FailedVoice({
    required this.recording,
    required this.idempotencyKey,
    required this.replyTo,
  });

  final AylaVoiceRecording recording;
  final String idempotencyKey;
  final int? replyTo;
  String? mediaId;
}

/// `.voice-rec-dot`（10 圆 + 1.2s 呼吸；reduced-motion 停）。
class _RecDot extends StatefulWidget {
  const _RecDot();

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget dot = AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        // 0%/100% opacity 1 ↔ 50% opacity .35（每帧只重建这一层 Opacity）
        final double t = 1 - 0.65 * (1 - (2 * _controller.value - 1).abs());
        return Opacity(opacity: t, child: child);
      },
      // 静态子树（尺寸 / 颜色 / 圆角都是常量）提到 child：**零视觉代价**，
      // 每帧不再新建 Container 与 BoxDecoration，也不再重跑它的布局
      //（2026-09-27 §8.17 的 AnimatedBuilder 审计项）。
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AylaColors.destructive,
          borderRadius: AylaRadii.pill,
        ),
      ),
    );

    // 录音红点的呼吸是**持续循环动画**（1.2s reverse 循环）：包一层重绘边界，让每帧的
    // markNeedsPaint 止步于此 —— 否则录音态下的输入区/整页会跟着每帧重绘。
    // 2026-09-25 全库审计：动画组件此前**没有一个** RepaintBoundary。
    return RepaintBoundary(child: dot);
  }
}

// ======================= 样张 =======================

AylaChatMessage _previewQuote() => AylaChatMessage(
      id: 'q1',
      conversationId: 'c1',
      senderId: 'u1',
      type: AylaMessageType.text,
      content: '晚上一起看直播吗？我这边刚开播。',
      status: AylaMessageStatus.sent,
      seq: 3,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );

AylaConversationMember _previewMember(String id, String name) =>
    AylaConversationMember(
      id: 'm-$id',
      user: AylaUserPublic(id: id, nickname: name, username: 'user_$id'),
    );

/// 输入区样张：
/// 宽屏（工具键横排）/ 窄屏（工具键在下方一行）/ 引用条 / 待发媒体（图+文件）/ 禁用态。
Widget aylaMessageInputSamples() {
  aylaEnableSampleMedia();
  Widget cell(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          child,
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      cell(
        '宽屏（工具键横排 + 发送带文字）',
        Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          child: SizedBox(
            width: 720,
            child: AylaMessageInput(
              onSubmit: (_) {},
              draftKey: 'preview-wide',
              groupId: 'g1',
              showEmojiButton: true,
              emojiPanel: const SizedBox.shrink(),
              members: <AylaConversationMember>[_previewMember('u1', '小樱')],
            ),
          ),
        ),
      ),
      cell(
        '引用条 + 待发媒体（图片/视频/文件单媒体互斥）',
        Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          child: SizedBox(
            width: 720,
            child: AylaMessageInput(
              onSubmit: (_) {},
              draftKey: 'preview-quote',
              quote: _previewQuote(),
              onQuoteClear: () {},
            ),
          ),
        ),
      ),
      cell(
        '窄屏（工具键在输入框下方一行，space-between）',
        Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          child: SizedBox(
            width: 375,
            child: AylaMessageInput(
              onSubmit: (_) {},
              narrow: true,
              draftKey: 'preview-narrow',
              groupId: 'g1',
              showEmojiButton: true,
              emojiPanel: const SizedBox.shrink(),
              members: <AylaConversationMember>[_previewMember('u1', '小樱')],
            ),
          ),
        ),
      ),
      cell(
        '禁用态（子群禁言：提示在输入区上方）',
        Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          child: SizedBox(
            width: 720,
            child: AylaMessageInput(
              onSubmit: (_) {},
              disabled: true,
              disabledHint: '本子群已禁言，仅管理员可发言',
              draftKey: 'preview-disabled',
            ),
          ),
        ),
      ),
    ],
  );
}
