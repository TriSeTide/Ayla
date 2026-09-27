/// 群表情包面板（`components/chat/EmojiPackPanel.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaEmojiPackPanel] | `EmojiPackPanel.tsx:158–251`（面板内容） |
/// | 面板材质/尺寸 | app.css 2186–2204（`.emoji-pack-panel`：glass-bg-strong + `--glass-filter` + 1px 边 + radius 16 + `--glass-shadow` / max-h 280 / padding sp3 / gap sp2） |
/// | 窄屏档 | app.css 3211–3215（`position: static; max-height: 40vh; box-shadow: none`） |
/// | 头 / 错误 / 网格 / 格 / 加号 / 删除键 / 空态 | app.css 2206–2323 |
/// | 权限兜底 | tsx 61–62（`canUpload = payload ? payload.can_upload : metaLoaded && !metaError && myRole ∈ {owner, admin}`） |
/// | 上传链 | tsx 99–129（多选 → 跳过非图片提示 → 逐张三步上传 `kind=emoji` → 加入群包 → 刷新） |
/// | 发送 / 删除 | tsx 135–156（发送后**面板不自动收起**） |
///
/// ## 定位（由调用方持有，登记说明）
/// web 的 `.emoji-pack-panel` 是 `position: absolute; left/right sp3; bottom: calc(100% + 8px)`
/// ——相对 `.composer`。Flutter 侧**不让组件自己贴定位**：宽屏由调用方把本件放进 composer 的
/// `Stack`（`Positioned(left: sp3, right: sp3, bottom: composerHeight + 8)`），窄屏按 web 的
/// `position: static` 档正常流向下展开（[AylaEmojiPackPanel.narrow] = true）。
/// 这与 `AylaDanmakuList`「材质归调用方、本件只渲染内容」同口径。
///
/// ## 上传能力
/// 选图+三步上传复用库内 `AylaMediaActions.pickImages`（含本地校验、进度聚合、失败计数），
/// 「加入群包」与「发送表情」是两个注入回调（业务链路属页面层）。
///
/// ## 公开面
/// `AylaEmojiPackData` · `AylaEmojiPackPanel` · 样张 `aylaEmojiPackPanelSamples()`

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media/media_actions.dart';
import '../../core/models/emoji_item.dart';
import '../../core/models/media_kind.dart' show AylaMediaKind;
import '../../core/models/post.dart'
    show AylaMediaDescriptor, AylaMediaPickResult, AylaPostMediaDraft;
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/dashed_border.dart';
import '../base/loading.dart';
import '../base/resource_image.dart';

/// 面板数据面（web：`getGroupEmojiPackSummary` + `usePagedMediaList(listGroupEmojiItemsPage)`）。
class AylaEmojiPackData {
  const AylaEmojiPackData({
    this.packId,
    this.canUploadFromPack,
    this.canDeleteFromPack,
    this.summaryLoaded = false,
    this.summaryError,
    this.items = const <AylaEmojiItem>[],
    this.itemsLoading = false,
    this.itemsError,
    this.hasMore = false,
  });

  /// 群表情包 id（null = 未建包/未加载）。
  final String? packId;

  /// 后端给出的上传权限（null = 未建包，按 [AylaEmojiPackPanel.myRole] 兜底）。
  final bool? canUploadFromPack;

  /// 后端给出的删除权限（默认 false）。
  final bool? canDeleteFromPack;

  /// 摘要是否已加载完成（未完成时权限兜底不生效）。
  final bool summaryLoaded;

  /// 摘要加载错误（null = 无错）。
  final String? summaryError;

  final List<AylaEmojiItem> items;
  final bool itemsLoading;
  final String? itemsError;
  final bool hasMore;

  /// 是否已建包（`packId != null`）。
  bool get hasPack => packId != null;
}

/// 群表情包面板。
class AylaEmojiPackPanel extends StatefulWidget {
  const AylaEmojiPackPanel({
    super.key,
    required this.onClose,
    this.data = const AylaEmojiPackData(),
    this.myRole,
    this.narrow = false,
    this.onSendEmoji,
    this.onAddEmoji,
    this.onDeleteEmoji,
    this.onReload,
    this.pickImages,
  });

  /// 关闭面板（`.icon-btn-32` 关闭钮）。
  final VoidCallback onClose;

  final AylaEmojiPackData data;

  /// 当前用户在群中的角色（`owner` / `admin` / `member`）——包未创建时兜底加号显示。
  final String? myRole;

  /// 窄屏档（`position: static; max-height: 40vh; box-shadow: none`）。
  final bool narrow;

  /// 点击表情 → 发送 emoji 消息（web `sendMessage(convId, "", {type: emoji, mediaId})`）。
  final Future<void> Function(String mediaId)? onSendEmoji;

  /// 上传成功后加入群表情包（web `addGroupEmojiItem(convId, mediaId)`）。
  final Future<void> Function(String mediaId)? onAddEmoji;

  /// 删除表情（web `deleteGroupEmojiItem(convId, itemId)`）。
  final Future<void> Function(String itemId)? onDeleteEmoji;

  /// 上传/删除后刷新（web `refresh()`）。
  final Future<void> Function()? onReload;

  /// 选图+上传（默认 `AylaMediaActions.pickImages`；测试/预览注入替身）。
  final Future<AylaMediaPickResult> Function()? pickImages;

  /// 网格最小列宽（`minmax(56px, 1fr)`）与间距（`gap: var(--sp-2)`）。
  static const double cellMinSize = 56;
  static const double gridGap = AylaSpacing.sp2;

  /// 宽屏 max-height（`.emoji-pack-panel { max-height: 280px }`）。
  static const double wideMaxHeight = 280;

  @override
  State<AylaEmojiPackPanel> createState() => _AylaEmojiPackPanelState();
}

class _AylaEmojiPackPanelState extends State<AylaEmojiPackPanel> {
  bool _uploading = false;
  String _uploadProgress = '';
  String? _error;
  String? _hoveredItemId;

  /// 权限（tsx 61–62）：有包用后端值；未建包时按角色兜底（需摘要已加载且无错）。
  bool get _canUpload {
    final bool? fromPack = widget.data.canUploadFromPack;
    if (widget.data.hasPack && fromPack != null) return fromPack;
    final bool metaReady =
        widget.data.summaryLoaded && widget.data.summaryError == null;
    final String? role = widget.myRole;
    return metaReady && (role == 'owner' || role == 'admin');
  }

  bool get _canDelete => widget.data.canDeleteFromPack ?? false;

  bool get _busy => widget.data.itemsLoading || !widget.data.summaryLoaded;

  Future<void> _handlePick() async {
    if (_uploading) return;
    final Future<AylaMediaPickResult> Function() picker =
        widget.pickImages ?? () => AylaMediaActions.pickImages(remaining: 99);
    setState(() {
      _uploading = true;
      _uploadProgress = '';
      _error = null;
    });
    try {
      final AylaMediaPickResult result = await picker();
      final List<AylaPostMediaDraft> drafts = result.drafts;
      int done = 0;
      final List<String> errors = <String>[];
      for (final AylaPostMediaDraft draft in drafts) {
        if (!mounted) return;
        try {
          // web：逐张 uploadMediaFile → addGroupEmojiItem；单张失败不阻塞其余
          await widget.onAddEmoji?.call(draft.mediaId);
        } catch (e) {
          errors.add(e.toString());
        }
        if (!mounted) return;
        done += 1;
        setState(() {
          _uploadProgress = drafts.length > 1 ? '$done/${drafts.length}' : '';
        });
      }
      if (!mounted) return;
      final int failed = result.failed + errors.length;
      setState(() {
        _uploading = false;
        _uploadProgress = '';
        if (failed > 0) _error = '部分表情上传失败（$failed 张）';
        if (result.overLimit > 0) {
          _error = '最多添加 ${drafts.length + result.overLimit} 张';
        }
      });
      await widget.onReload?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadProgress = '';
        _error = e.toString();
      });
    }
  }

  /// 点击表情 → 发送 emoji 消息；**发送后不自动收起面板**（tsx 131–134）。
  Future<void> _handleSend(AylaEmojiItem item) async {
    final String? mediaId = item.media?.mediaId;
    if (mediaId == null) return;
    setState(() => _error = null);
    try {
      await widget.onSendEmoji?.call(mediaId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _handleDelete(AylaEmojiItem item) async {
    if (!_canDelete) return;
    setState(() => _error = null);
    try {
      await widget.onDeleteEmoji?.call(item.id);
      await widget.onReload?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final double maxHeight = widget.narrow
        ? MediaQuery.sizeOf(context).height * 0.4 // 窄屏 `max-height: 40vh`
        : AylaEmojiPackPanel.wideMaxHeight;
    final String? error = _error ?? widget.data.summaryError ?? widget.data.itemsError;

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _head(),
        if (error != null && error.isNotEmpty) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          Text(
            error,
            // `.emoji-pack-error { font-size: 12px; color: var(--destructive) }`
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontSize: 12,
              color: AylaColors.destructive,
            ),
          ),
        ],
        const SizedBox(height: AylaSpacing.sp2),
        Flexible(child: _grid()),
        if (widget.data.summaryLoaded &&
            widget.data.summaryError == null &&
            !widget.data.itemsLoading &&
            widget.data.itemsError == null &&
            widget.data.items.isEmpty &&
            !_uploading) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          Text(
            // tsx 230–234：按上传权限分两档
            _canUpload ? '还没有表情，点加号上传' : '群内还没有表情包',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontSize: 12,
              color: AylaColors.textSecondary,
            ),
          ),
        ],
        if (_busy) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          const Center(child: AylaLoadingSpinner(size: 18)),
        ],
      ],
    );

    if (widget.narrow) {
      return _shell(
        maxHeight: maxHeight,
        // 窄屏 `.emoji-pack-panel { box-shadow: none }`
        shadow: const <BoxShadow>[],
        child: content,
      );
    }
    return _shell(maxHeight: maxHeight, shadow: AylaShadows.glass, child: content);
  }

  Widget _shell({
    required double maxHeight,
    required List<BoxShadow> shadow,
    required Widget child,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AylaGlassSurface(
        // `.emoji-pack-panel`：`--glass-bg-strong` + `--glass-filter` + 1px 边 +
        // radius 16 + `--glass-shadow` + padding sp3
        strong: true,
        blur: AylaGlass.blurCard,
        radius: AylaRadii.rCard,
        shadow: shadow,
        padding: const EdgeInsets.all(AylaSpacing.sp3),
        child: SingleChildScrollView(
          // web 面板自身 `overflow-y: auto`（app.css 2203）
          child: child,
        ),
      ),
    );
  }

  /// `.emoji-pack-head`（app.css 2206–2217）：标题 13/600 + `.icon-btn-32` 关闭钮。
  Widget _head() {
    return Row(
      children: <Widget>[
        const Expanded(
          child: Text(
            '群表情包',
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AylaColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: AylaSpacing.sp2),
        AylaIconButton(
          // `.icon-btn-32`（32×32 方角档）+ `IconClose` 16（tsx 162–164）
          size: 32,
          square: true,
          icon: AylaIcon(aylaIconByName('iconClose')!, size: 16),
          onPressed: widget.onClose,
          semanticLabel: '关闭表情面板',
        ),
      ],
    );
  }

  /// `.emoji-pack-grid`：`repeat(auto-fill, minmax(56px, 1fr))` + gap 8。
  Widget _grid() {
    final List<AylaEmojiItem> items = widget.data.items;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        const double minSize = AylaEmojiPackPanel.cellMinSize;
        const double gap = AylaEmojiPackPanel.gridGap;
        final int columns = math.max(
          1,
          ((c.maxWidth + gap) / (minSize + gap)).floor(),
        );
        final List<Widget> cells = <Widget>[
          for (final AylaEmojiItem item in items) _cell(item),
          if (_canUpload) _addCell(),
        ];
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final Widget cell in cells)
              SizedBox(
                width: (c.maxWidth - gap * (columns - 1)) / columns,
                child: cell,
              ),
          ],
        );
      },
    );
  }

  Widget _cell(AylaEmojiItem item) {
    final bool hovered = _hoveredItemId == item.id;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        MouseRegion(
          onEnter: (_) => setState(() => _hoveredItemId = item.id),
          onExit: (_) => setState(() {
            if (_hoveredItemId == item.id) _hoveredItemId = null;
          }),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _handleSend(item),
            child: Semantics(
              button: true,
              label: '发送表情',
              child: AspectRatio(
                aspectRatio: 1, // `.emoji-pack-item { aspect-ratio: 1 }`
                child: _cellShell(
                  hovered: hovered,
                  child: item.media == null
                      ? null
                      : AylaResourceImage(
                          src: mediaContentUrl(item.media!.mediaId),
                          alt: '群表情',
                          fit: BoxFit.contain, // `.emoji-pack-item img { object-fit: contain }`
                          fallback: const _EmojiFallback(),
                        ),
                ),
              ),
            ),
          ),
        ),
        if (_canDelete)
          Positioned(
            // `.emoji-pack-remove { top: -5px; right: -5px }`（app.css 2291–2293）
            // ⚠️ 溢出的 5px 在 Flutter 里收不到指针（`RenderBox.hitTest` 只在自身 size
            // 内接受）—— 键的 13×13 主体仍在边界内可点，与 web 观感一致。
            top: -5,
            right: -5,
            child: _RemoveButton(
              visible: hovered,
              onTap: () => _handleDelete(item),
            ),
          ),
      ],
    );
  }

  /// `.emoji-pack-add`：虚线边加号框（`AylaDashedBorder` 复用虚线件）。
  Widget _addCell() {
    return AspectRatio(
      aspectRatio: 1,
      child: AylaDashedBorder(
        radius: AylaRadii.rSm,
        color: AylaColors.glassBorder,
        child: GestureDetector(
          onTap: _uploading ? null : () => _handlePick(),
          child: Semantics(
            button: true,
            label: '添加群表情',
            child: ColoredBox(
              color: AylaColors.surface,
              child: Center(
                child: _uploading
                    ? Text(
                        _uploadProgress.isEmpty ? '上传中…' : '上传中 $_uploadProgress',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: AylaFonts.body,
                          fontSize: 11,
                          color: AylaColors.textSecondary,
                        ),
                      )
                    : AylaIcon(
                        aylaIconByName('iconPlus')!,
                        size: 20,
                        color: AylaColors.textSecondary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.emoji-pack-item { border 1px --glass-border; background: --surface }`；
  /// hover/focus → 边 `--glow-500` + `--glow-shadow`（app.css 2234–2255）。
  Widget _cellShell({required bool hovered, required Widget? child}) {
    return AnimatedContainer(
      duration: AylaDurations.fast,
      curve: AylaCurves.easeOut,
      decoration: BoxDecoration(
        color: AylaColors.surface,
        borderRadius: BorderRadius.circular(AylaRadii.rSm),
        border: Border.all(
          color: hovered ? AylaColors.glow500 : AylaColors.glassBorder,
        ),
        boxShadow: hovered ? AylaShadows.glow : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AylaRadii.rSm),
        child: child ?? const _EmojiFallback(),
      ),
    );
  }
}

/// `.emoji-pack-img-fallback`（app.css 2265–2271）：撑满 + `--glass-bg`
/// （**56px 小格内不显示重试**）。
class _EmojiFallback extends StatelessWidget {
  const _EmojiFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: AylaColors.glassBg);
  }
}

/// `.emoji-pack-remove`（app.css 2289–2316）：18 圆 + 1px 边 + `--surface` 底；
/// 单元格 hover 或自身 focus → 显示；hover 自身 → destructive 底白字。
class _RemoveButton extends StatefulWidget {
  const _RemoveButton({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool shown = widget.visible || _focused;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (bool v) => setState(() => _focused = v),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            label: '删除表情',
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: AylaDurations.fast,
              curve: AylaCurves.easeOut,
              child: IgnorePointer(
                ignoring: !shown,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _hovered ? AylaColors.destructive : AylaColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _hovered ? AylaColors.destructive : AylaColors.glassBorder,
                    ),
                  ),
                  child: Center(
                    child: AylaIcon(
                      aylaIconByName('iconClose')!,
                      size: 10,
                      color: _hovered ? const Color(0xFFFFFFFF) : AylaColors.textSecondary,
                    ),
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

// ======================= 样张 =======================

AylaEmojiItem _previewEmoji(String id) => AylaEmojiItem(
      id: id,
      media: AylaMediaDescriptor(
        mediaId: 'emoji-$id',
        kind: AylaMediaKind.emoji,
        mimeType: 'image/png',
        size: 12000,
        width: 240,
        height: 240,
        status: 'ready',
      ),
    );

/// 群表情包面板样张：
/// 有表情（可删）/ 空态（可上传）/ 加载中 / 错误。
Widget aylaEmojiPackPanelSamples() {
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
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(width: 420, child: child),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      cell(
        '有表情（管理员：加号 + hover 显示删除键）',
        AylaEmojiPackPanel(
          myRole: 'admin',
          onClose: () {},
          onAddEmoji: (_) async {},
          onSendEmoji: (_) async {},
          onDeleteEmoji: (_) async {},
          data: AylaEmojiPackData(
            packId: 'pack-1',
            canUploadFromPack: true,
            canDeleteFromPack: true,
            summaryLoaded: true,
            items: <AylaEmojiItem>[
              for (int i = 0; i < 5; i++) _previewEmoji('$i'),
            ],
          ),
        ),
      ),
      cell(
        '空态（可上传：点加号上传）',
        AylaEmojiPackPanel(
          myRole: 'owner',
          onClose: () {},
          onAddEmoji: (_) async {},
          data: const AylaEmojiPackData(
            summaryLoaded: true,
            items: <AylaEmojiItem>[],
          ),
        ),
      ),
      cell(
        '成员视角（无加号 / 不可删）',
        AylaEmojiPackPanel(
          myRole: 'member',
          onClose: () {},
          onSendEmoji: (_) async {},
          data: AylaEmojiPackData(
            packId: 'pack-1',
            canUploadFromPack: false,
            canDeleteFromPack: false,
            summaryLoaded: true,
            items: <AylaEmojiItem>[_previewEmoji('a'), _previewEmoji('b')],
          ),
        ),
      ),
      cell(
        '错误态（部分上传失败）',
        AylaEmojiPackPanel(
          myRole: 'admin',
          onClose: () {},
          data: const AylaEmojiPackData(
            packId: 'pack-1',
            summaryLoaded: true,
            summaryError: '部分表情上传失败：网络错误',
            items: <AylaEmojiItem>[],
          ),
        ),
      ),
    ],
  );
}
