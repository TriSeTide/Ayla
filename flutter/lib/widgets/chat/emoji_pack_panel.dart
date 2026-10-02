/// 群表情包面板（`components/chat/EmojiPackPanel.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaEmojiPackPanel] | `EmojiPackPanel.tsx:158–251`（面板内容） |
/// | 面板材质/尺寸 | app.css 2186–2204（`.emoji-pack-panel`：glass-bg-strong + `--glass-filter` + 1px 边 + radius 16 + `--glass-shadow` / max-h 280 / padding sp3 / gap sp2） |
/// | 窄屏档 | app.css 3211–3215（`position: static; max-height: 40vh; box-shadow: none`） |
/// | 头 / 错误 / 网格 / 格 / 加号 / 删除键 | app.css 2206–2323 |
/// | **分页页脚** | tsx 227–228（`DirectoryLoadMore` 六个传参）→ 复用库内 `<base/directory_load_more.dart>` |
/// | **空态** | tsx 230–234（五条件 + 两档文案）+ app.css 2318–2323（`padding: var(--sp-3) 0`） |
/// | 权限兜底 | tsx 61–62（`canUpload = payload ? payload.can_upload : metaLoaded && !metaError && myRole ∈ {owner, admin}`） |
/// | 上传链 | tsx 99–129（多选 → 跳过非图片提示 → 逐张三步上传 `kind=emoji` → 加入群包 → 刷新） |
/// | 发送 / 删除 | tsx 135–156（发送后**面板不自动收起**） |
///
/// ## 与 web 的取舍登记（2026-09-28，B3 分页接线轮）
///
/// 1. **分页页脚已接线**（此前只有数据字段、零 UI 引用）：六个传参逐条对齐 tsx 227–228，
///    见 `_footer()` 的表；`retainCompletedSpace: false` 决定「无更多/不加载时不渲染页脚」。
/// 2. **删掉自造的加载圈**：迁移时页脚缺位，用 `AylaLoadingSpinner` 顶过加载反馈；
///    接线后它与页脚三点**重复**，且 web 面板里没有这个元素（tsx 158–251 无 spinner）⇒ 删除。
/// 3. **空态条件按 tsx 230 逐字**：原实现多一个自加的 `!_uploading`（web 上传中**也**会显示
///    空态文案）⇒ 已删；并补上 app.css 2318 的 `padding: sp3 0`（原实现只靠 flex gap 撑）。
/// 4. **错误文案来源登记（有意偏离）**：web 的 `.emoji-pack-error` 只显示**本地动作错误**
///    （上传跳过/部分失败、发送、删除），`metaError` / `pages.error` 只进页脚（页脚随即不渲染）。
///    Flutter 侧把两者也落到同一行（`_error ?? summaryError ?? itemsError`）——信息更完整，
///    且 `摘要错误：显示错误文案` 用例依赖它；未改回 web 口径，特此登记。
///
/// ## 修复登记（2026-10-02，真机网格溢出）
///
/// **5. 失败/加载态的静默裁剪**（真实 bug 修复，非偏离）：真机面板底部三格各报一次
///    `A RenderFlex overflowed by 17 pixels on the bottom`（红色 `OVERFLOWED BY …` 徽标）。
///    溢出点**不在面板/网格**，而在格子里的图片失败占位（`resource_image.dart` 的
///    `_FailedPlaceholder`：fallback + 芯片纵排 72px > 格子 54.5px）——详见 [_cellShell] 的注释。
///    web 的 `.emoji-pack-item`（`<button>` + `aspect-ratio: 1`）把框外内容**静默裁掉**，
///    app.css 2265–2271 注释原文即「**56px 小格内不显示重试按钮**」⇒ Flutter 侧用
///    `ClipRect + OverflowBox`（同 `live/danmaku.dart:506–516` 已登记技法）表达同一结果。
///    **图片加载链路本身未动**（minio 资源问题按用户口径「暂时不修」）。
///    回归锁：`test/emoji_pack_panel_overflow_test.dart`（真机 1265.6×682.4 复现 + 宽窄两档 + 高度上限）。
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
import '../base/directory_load_more.dart';
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
    this.onLoadMore,
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

  /// 分页下一页（web `usePagedMediaList.loadMore`）。
  ///
  /// ⚠️ 与 [onReload] 是**两条不同的链路**（tsx 227–228）：页脚的
  /// `loadMore={metaError ? refresh : pages.loadMore}` —— 摘要失败时页脚按钮重试的是
  /// **摘要**（refresh），只有摘要正常时才是「加载下一页」。本件按同一规则接线。
  final Future<void> Function()? onLoadMore;

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

  Future<void> _handlePick() async {
    if (_uploading) return;
    // ⚠️ 必须走 `pickEmojiImages`（`kind=emoji`），不是 `pickImages`：
    // web `EmojiPackPanel.tsx:113` 是 `uploadMediaFile(file, "emoji")`，后端
    // `apps/emoji/services.py:118` 硬校验 kind=emoji（否则 media_type_mismatch）。
    final Future<AylaMediaPickResult> Function() picker = widget.pickImages ??
        () => AylaMediaActions.pickEmojiImages(remaining: 99);
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
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              color: AylaColors.destructive,
            ),
          ),
        ],
        const SizedBox(height: AylaSpacing.sp2),
        Flexible(child: _grid()),
        // 面板是 `.emoji-pack-panel { display:flex; flex-direction:column; gap: sp2 }`
        // （app.css 2186–2204）⇒ 页脚与空态**各自**与前一子级相隔 8px；
        // Flutter 无 flex gap ⇒ 显式补 SizedBox。
        const SizedBox(height: AylaSpacing.sp2),
        _footer(),
        if (widget.data.summaryLoaded &&
            widget.data.summaryError == null &&
            !widget.data.itemsLoading &&
            widget.data.itemsError == null &&
            widget.data.items.isEmpty) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          Padding(
            // `.emoji-pack-empty { font-size 12; color secondary; text-align center;
            //  padding: var(--sp-3) 0 }`（app.css 2318–2323）—— 上下各 12
            padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp3),
            child: Text(
              // tsx 230–234：按上传权限分两档
              _canUpload ? '还没有表情，点加号上传' : '群内还没有表情包',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
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
              fontFamilyFallback: AylaFonts.cjkFallback,
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

  /// 分页页脚（tsx 227–228 的 `DirectoryLoadMore` 接线；复用库内 [AylaDirectoryLoadMore]）。
  ///
  /// | 本件传参 | 事实源 |
  /// |---|---|
  /// | `loading: !summaryLoaded \|\| itemsLoading` | tsx 227 `loading={!metaLoaded \|\| pages.loading}` |
  /// | `error: summaryError ?? itemsError` | tsx 227 `error={metaError ?? pages.error}` |
  /// | `hasMore` | `{...pages}` 展开的 `pages.hasMore` |
  /// | `invalidated: false` | tsx 228 **字面量**（本面板不参与目录失效重拉） |
  /// | `refresh: onReload` | tsx 228 `refresh={refresh}` |
  /// | `loadMore: summaryError != null ? onReload : onLoadMore` | tsx 228 `loadMore={metaError ? refresh : pages.loadMore}` |
  /// | `retainCompletedSpace: false` | tsx 228：`!loading && !hasMore && !invalidated` ⇒ **页脚不渲染** |
  ///
  /// ⚠️ `error` 非 null 时 [AylaDirectoryLoadMore] 自身返回 `SizedBox.shrink()`（tsx 29「错误由
  /// 外层 AsyncState 呈现」）——本件的「外层」就是 `.emoji-pack-error` 那一行（见 [build]）。
  Widget _footer() {
    final Future<void> Function() refresh = widget.onReload ?? () async {};
    final String? metaError = widget.data.summaryError;
    return AylaDirectoryLoadMore(
      loading: !widget.data.summaryLoaded || widget.data.itemsLoading,
      error: metaError ?? widget.data.itemsError,
      hasMore: widget.data.hasMore,
      invalidated: false,
      refresh: refresh,
      // 摘要失败 ⇒ 页脚按钮重试的是**摘要**（web `loadMore={metaError ? refresh : pages.loadMore}`）
      loadMore: metaError != null ? refresh : (widget.onLoadMore ?? () async {}),
      retainCompletedSpace: false,
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
                          fontFamilyFallback: AylaFonts.cjkFallback,
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
  ///
  /// ## ⚠️ 失败/加载态的**静默裁剪**（2026-10-02 真机溢出修复）
  ///
  /// **真机现象**：面板底部三格下方出现红色 `OVERFLOWED BY 17 PIXELS` 徽标
  /// （`A RenderFlex overflowed by 17 pixels on the bottom`，三格各一次）。
  ///
  /// **根因**（探针逐帧定位，非猜测）：溢出的 RenderFlex **不是面板、也不是网格**，而是
  /// **格子里的图片失败占位** —— `resource_image.dart:455–503` 的 `_FailedPlaceholder`
  /// 是纵向 Column = 「fallback 块」+「失败芯片 `.resource-image-fallback { min-height: 32px }`」。
  /// 探针实测（1265.6×682.4 真机逻辑尺寸）：格 = `BoxConstraints(w=54.5, h=54.5)`，
  /// 芯片（`font-size: 11` 的「图片加载失败，点击重试」在 54.5 宽里折成 4 行）= **54.5×72**，
  /// 而 fallback 旧实现（无子件 `ColoredBox`）在纵排的无界高里塌成 **0×0** ⇒
  /// Column = 72 > 54.5 ⇒ **overflow 17px**（正是用户截图里的红徽标）。
  ///
  /// **web 侧同一 DOM 为什么不报错**（以 web 为准）：`ResourceImage.tsx:148–167` 失败态是
  /// `span.resource-image-failed-wrap { fallback + 芯片 }`，宿主 `.emoji-pack-item` 是
  /// `<button>` 且 `aspect-ratio: 1`（app.css 2234–2246）——**自身框外的内容被裁掉**
  /// （与 `live/danmaku.dart:415–422` 已拍板的 `.danmaku-image-open { overflow: hidden }` 同源）：
  /// `.emoji-pack-img-fallback { width: 100%; height: 100% }`（app.css 2265–2271）铺满整格，
  /// 其后 72px 高的芯片**整块落在可见区之下 ⇒ 完全不可见**。
  ///
  /// **Flutter 等价**：CSS 的静默裁剪在 Flutter 是 `RenderFlex overflow` 报错 ⇒ 用库内已登记的
  /// 技法（`live/danmaku.dart:506–516` 同款）**`ClipRect + OverflowBox`**：宽度仍取格子的
  /// 紧约束（55），只放开高度轴让 Column 取自然高，再按 `overflow: hidden` 语义裁掉可见区之外的
  /// 部分 ⇒ 芯片不可见、fallback 铺满，与 web **同结果**且不报错。
  /// （**未改** `_FailedPlaceholder` 本身：它在评论/帖子等宿主里高度充裕、
  /// 「失败芯片可见」是 web 的既定行为，改公共件会波及那些宿主。）
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
        // `.emoji-pack-item`（web 的 `<button>`）对超出格子的内容**静默裁剪**
        // —— Flutter 侧由 `ClipRect + OverflowBox` 表达，见 [_cellShell] 的注释。
        child: ClipRect(
          child: OverflowBox(
            // web 是普通块流（自上而下）⇒ 溢出部分落在**下方**被裁。
            alignment: Alignment.topCenter,
            // 只放开高度轴：Column 取自然高（fallback 55 + 芯片 72）；
            // 宽度保持格子的紧约束（不放开 ⇒ 芯片仍按格宽折行，与 web 一致）。
            maxHeight: double.infinity,
            child: child ?? const _EmojiFallback(),
          ),
        ),
      ),
    );
  }
}

/// `.emoji-pack-img-fallback`（app.css 2265–2271）：撑满 + `--glass-bg`
/// （**56px 小格内不显示重试**）。
///
/// `width: 100%; height: 100%` 的宿主是**正方形**的 `.emoji-pack-item`
/// （`aspect-ratio: 1`）⇒ Flutter 等价物 = 「撑满宽度且等高的 1:1 盒」。
/// 不能用 `SizedBox.expand`：失败占位的纵排（`_FailedPlaceholder`）给子件的高度约束是
/// `0..∞`（无界）⇒ `expand` 会直接断言失败；而旧实现的无子件 `ColoredBox` 在无界高里
/// 塌成 **0×0**（这正是 2026-10-02 真机溢出的另一半原因，见 [_cellShell]）。
class _EmojiFallback extends StatelessWidget {
  const _EmojiFallback();

  @override
  Widget build(BuildContext context) {
    return const AspectRatio(
      aspectRatio: 1,
      child: ColoredBox(color: AylaColors.glassBg), // background: var(--glass-bg)
    );
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
                fontFamilyFallback: AylaFonts.cjkFallback,
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
        '分页：有下一页（页脚「加载更多」；点它走 onLoadMore）',
        AylaEmojiPackPanel(
          myRole: 'member',
          onClose: () {},
          onSendEmoji: (_) async {},
          onLoadMore: () async {},
          data: AylaEmojiPackData(
            packId: 'pack-1',
            summaryLoaded: true,
            hasMore: true,
            items: <AylaEmojiItem>[
              for (int i = 0; i < 5; i++) _previewEmoji('p$i'),
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
