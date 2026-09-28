/// AylaGroupPostsComposer —— 群内帖子的**底部玻璃输入容器 + 展开遮罩 + 展开态贴底**。
///
/// 本件是「壳」：编辑器本体一律复用 [AylaPostEditor]（`compact` + `collapsible` +
/// 半受控 `expanded` + `composerShell`），本文件**不重写编辑器**，只负责
/// web 上由 GroupPosts.tsx 与 .group-posts-input / .group-posts-scrim 承担的三件事：
/// ① 输入容器的玻璃材质与两档几何；② 展开遮罩（点击收起）；③ 展开态脱离文档流贴底。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// posts.css 923–929     .group-posts：height 100% · flex column · overflow hidden · position relative
/// posts.css 933–939     .group-posts-scrim：**absolute inset 0** · z-index **45** ·
///                       background rgba(70,91,146,.25) · animation group-posts-scrim-in 200ms
///                       var(--ease-out)（= cubic-bezier(.22,.61,.36,1)）
/// posts.css 941–948     关键帧：opacity 0 → 1
/// posts.css 950–954     reduced-motion ⇒ animation: none
/// posts.css 1011–1024   .group-posts-input：flex none · position relative · min-width 0 ·
///                       z-index **50** · padding **sp2 sp3 sp3**(8/12/12) · **border-top 1px
///                       --glass-border** · background --glass-bg(.55) ·
///                       backdrop-filter **blur(18px) saturate(1.4)** ·
///                       animation auroraqua-panel-from-bottom **300ms** easeOut（0 +20px → 0,0）
/// posts.css 1027–1031   .group-posts-input > .post-editor.is-collapsible { min-width 0; padding 0;
///                       gap sp2 }   ← 编辑器让位（Flutter 侧 = composerShell 档，见该档文档）
/// posts.css 1033–1040   .group-posts-input .field { min-width 0 · padding **sp2 sp3** ·
///                       **line-height 22px** · background --glass-bg · border-color --glass-border ·
///                       box-shadow **--glass-inset** }
/// posts.css 1042–1045   .group-posts-input .field:focus { border-color --glow-500 ·
///                       box-shadow --glow-shadow }   ← 基类 AylaGlassInput 已含
/// posts.css 1047–1049   .group-posts-input .post-editor:not(.is-expanded) .post-editor-body
///                       { height **40px** }
/// posts.css 1051–1057   .group-posts-input .post-editor-image-btn { radius-input · glass-bg ·
///                       --glass-shadow-compact · backdrop blur(8px) }
/// posts.css 1071–1080   .is-expanded：**position absolute · left 0 · right 0 · bottom 0 ·
///                       max-height 100% · overflow-y auto** · animation group-posts-editor-rise
///                       **250ms** var(--ease-out)
/// posts.css 1082–1089   ≥769：.group-content .group-posts { overflow: visible }；
///                       .is-expanded { max-height calc(100% − 2 × --sidebar-gutter(12)) }
/// posts.css 1091–1100   关键帧 group-posts-editor-rise：opacity 0 + translateY(20px) → 1 + 0
/// posts.css 1102–1107   reduced-motion ⇒ 两档 animation: none
/// auroraqua.css 347–359 **≥769 覆写**（后加载，同特异性胜出）：:is(.composer, **.group-posts-input**,
///                       …) ⇒ flex none · width auto · min-width 0 · **margin --sidebar-gutter(12)** ·
///                       **padding sp2(8)** · background --glass-bg · **1px --glass-border（四边）** ·
///                       **border-radius --radius-card(16)** · box-shadow **--glass-shadow** ·
///                       backdrop-filter **--glass-filter(blur24 sat1.4)**
/// auroraqua.css 361–368 同段再压：.group-content .group-posts > .group-posts-input
///                       ⇒ **margin-left: 0**（左邻侧栏已有 12px 空隙，避免双份）
/// GroupPosts.tsx 477–483 遮罩**只在 editorExpanded 时渲染**、点击 ⇒ setEditorExpanded(false)、
///                       aria-hidden="true"
/// GroupPosts.tsx 484–493 div.group-posts-input[.is-expanded] 内是
///                       PostEditor group={groupId} onCreated compact collapsible
///                       expanded={editorExpanded} onExpandedChange={setEditorExpanded}
/// ```
///
/// ## 覆盖关系（三处 grep 结论，层叠顺序 main.tsx：posts.css → auroraqua.css）
/// 1. 窄屏（≤768）只有 posts.css 命中：方角 · 仅上边框 · padding 8/12/12 · blur18 sat1.4 · **无外阴影**；
/// 2. 宽屏（≥769）auroraqua 347–359 覆写：四边 1px 边 + radius 16 + padding 8 + margin 12 +
///    --glass-shadow + blur24 sat1.4（**padding / 边框 / 圆角 / 模糊四者都被换档**）；
/// 3. auroraqua 364 再把 margin-left 归 0（只在本件位于 .group-content .group-posts 内时命中
///    —— 本件的固定位置即该结构 ⇒ 恒命中）；
/// 4. .group-posts-scrim **只有 posts.css 命中**（auroraqua 无任何 scrim 规则）。
///
/// ## 公开面
/// AylaGroupPostsComposer · 样张 aylaGroupPostsComposerSamples()

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/post.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/loading.dart' show AylaSkeleton;
import '../base/reveal.dart';
import '../posts/post_editor.dart';
import 'group_scene.dart';

/// 群内帖子底部输入容器（posts.css 1011–1108 + auroraqua.css 347–368）。
class AylaGroupPostsComposer extends StatefulWidget {
  const AylaGroupPostsComposer({
    super.key,
    required this.child,
    required this.onSubmit,
    this.groupId,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.expanded,
    this.onExpandedChange,
    this.onPickMedia,
    this.onRetryFailedMedia,
    this.onRemoveMedia,
    this.initialTitle = '',
    this.initialBody = '',
    this.initialImages = const <AylaPostMediaDraft>[],
  });

  /// 内容轨道（.group-posts-list：通常是 [AylaGroupSceneStickyHead] 包住的帖子流）。
  final Widget child;

  /// 发布（透传 [AylaPostEditor.onSubmit]）。
  final Future<void> Function(AylaPostDraft draft) onSubmit;

  /// 群 id（web group={groupId}：群内发帖锁定本群可见性）。
  final String? groupId;

  /// 可见性选择器可选群列表（透传）。
  final List<({String id, String title})> groups;

  /// 群列表加载中（透传）。
  final bool groupsLoading;

  /// 半受控展开态（web editorExpanded；null ⇒ 内部自持，默认收起）。
  final bool? expanded;

  /// 展开/收起变化通知（web setEditorExpanded）。
  final ValueChanged<bool>? onExpandedChange;

  /// 选媒体 + 上传（透传）。
  final Future<AylaMediaPickResult> Function(
    int remaining,
    ValueChanged<double?> onProgress,
  )? onPickMedia;

  /// 重试失败媒体（透传）。
  final Future<AylaMediaPickResult> Function()? onRetryFailedMedia;

  /// 移除媒体（透传）。
  final Future<void> Function(AylaPostMediaDraft draft)? onRemoveMedia;

  /// 初始标题（样张/编辑场景）。
  final String initialTitle;

  /// 初始正文（样张/编辑场景）。
  final String initialBody;

  /// 初始媒体（样张/编辑场景）。
  final List<AylaPostMediaDraft> initialImages;

  /// @media (min-width: 769px) 断点（auroraqua 347 段）。
  static const double wideBreakpoint = 769;

  @override
  State<AylaGroupPostsComposer> createState() => _AylaGroupPostsComposerState();
}

class _AylaGroupPostsComposerState extends State<AylaGroupPostsComposer> {
  /// 内部展开态（widget.expanded == null 时生效；默认收起 = web useState(false)）。
  bool _internalExpanded = false;

  bool get _expanded => widget.expanded ?? _internalExpanded;

  void _setExpanded(bool value) {
    if (value == _expanded) return;
    if (widget.expanded == null) setState(() => _internalExpanded = value);
    widget.onExpandedChange?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final bool wide =
        MediaQuery.sizeOf(context).width >=
        AylaGroupPostsComposer.wideBreakpoint;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // .group-posts-input.is-expanded { max-height: 100% }；
        // ≥769 ⇒ calc(100% − 2 × --sidebar-gutter)
        final double maxHeight = wide
            ? math.max(0, c.maxHeight - 2 * AylaSpacing.sidebarGutter)
            : c.maxHeight;
        return Stack(
          children: <Widget>[
            // .group-posts（flex column）：列表占满，收起态输入区在其下方占位
            Positioned.fill(
              child: Column(
                children: <Widget>[
                  Expanded(child: widget.child), // .group-posts-list { flex: 1 }
                  if (!_expanded) _inputPanel(wide: wide, expanded: false),
                ],
              ),
            ),
            // z-index 45：遮罩（只在展开态渲染；点击收起；aria-hidden ⇒ 不进语义树）
            if (_expanded)
              Positioned.fill(child: ExcludeSemantics(child: _scrim())),
            // z-index 50：展开态贴底（脱离文档流，盖住标题栏与列表）
            if (_expanded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    // overflow-y: auto
                    child: _inputPanel(wide: wide, expanded: true),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 展开遮罩（posts.css 933–948）。
  Widget _scrim() {
    return AylaRevealItem(
      // group-posts-scrim-in：opacity 0 → 1，200ms var(--ease-out)（位移为 0，纯淡入）
      offset: Offset.zero,
      duration: const Duration(milliseconds: 200),
      curve: AylaCurves.easeOut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setExpanded(false), // onClick ⇒ setEditorExpanded(false)
        child: const ColoredBox(
          color: AylaColors.overlayDim, // rgba(70, 91, 146, .25)
        ),
      ),
    );
  }

  /// 输入容器（.group-posts-input，两档材质 + 入场）。
  Widget _inputPanel({required bool wide, required bool expanded}) {
    // 入场：
    // · 基础档 auroraqua-panel-from-bottom（300ms easeOut，0 +20px → 0,0）—— 两档都挂；
    // · 展开档 group-posts-editor-rise（250ms easeOut，translateY 20 → 0 + 淡入）
    //   —— web 是**换 animation-name** ⇒ 展开时按新动画重播；key 变化等价复刻。
    final Widget surface = Padding(
      // ≥769：margin: var(--sidebar-gutter) + margin-left: 0（auroraqua 351 / 367）
      padding: wide
          ? const EdgeInsets.only(
              top: AylaSpacing.sidebarGutter,
              right: AylaSpacing.sidebarGutter,
              bottom: AylaSpacing.sidebarGutter,
            )
          : EdgeInsets.zero,
      child: AylaGlassSurface(
        // 窄屏无 radius 声明 ⇒ 方角；≥769 ⇒ --radius-card 16
        radiusOverride: wide ? null : BorderRadius.zero,
        radius: AylaRadii.rCard,
        // 窄屏 blur(18px) sat1.4（posts.css 1020）；≥769 --glass-filter(blur24 sat1.4)
        blur: wide ? AylaGlass.blurCard : AylaGlass.blurNav,
        // 窄屏未声明 box-shadow ⇒ 无；≥769 --glass-shadow（auroraqua 356）
        shadow: wide ? AylaShadows.glass : const <BoxShadow>[],
        // 窄屏只有 border-top；≥769 四边 1px --glass-border（默认 border: true）
        borderOverride: wide
            ? null
            : const Border(top: BorderSide(color: AylaColors.glassBorder)),
        padding: EdgeInsets.zero,
        child: Padding(
          // 窄屏 padding: sp2 sp3 sp3；≥769 padding: sp2（编辑器 composerShell 档已让出内沿）
          padding: wide
              ? const EdgeInsets.all(AylaSpacing.sp2)
              : const EdgeInsets.fromLTRB(
                  AylaSpacing.sp3,
                  AylaSpacing.sp2,
                  AylaSpacing.sp3,
                  AylaSpacing.sp3,
                ),
          child: AylaPostEditor(
            // GroupPosts.tsx 485–492：group + compact + collapsible + 半受控 expanded
            onSubmit: widget.onSubmit,
            group: widget.groupId,
            groups: widget.groups,
            groupsLoading: widget.groupsLoading,
            compact: true,
            collapsible: true,
            composerShell: true, // posts.css 1027–1049 的覆写组（内沿归外壳）
            expanded: _expanded,
            onExpandedChange: _setExpanded,
            onPickMedia: widget.onPickMedia,
            onRetryFailedMedia: widget.onRetryFailedMedia,
            onRemoveMedia: widget.onRemoveMedia,
            initialTitle: widget.initialTitle,
            initialBody: widget.initialBody,
            initialImages: widget.initialImages,
          ),
        ),
      ),
    );

    return AylaRevealItem(
      key: ValueKey<bool>(expanded),
      offset: const Offset(0, 20), // translateY(20px) → 0
      duration: expanded
          ? const Duration(milliseconds: 250) // group-posts-editor-rise 250ms
          : AylaDurations.auroraqua, // auroraqua-panel-from-bottom 300ms
      curve: AylaCurves.easeOut, // var(--ease-out)（两档同曲线）
      child: surface,
    );
  }
}


// ======================= 样张 =======================

/// 群内帖子输入容器样张（收起 / 展开 · 窄屏 / 宽屏四格）。
///
/// 头部与描述用 web 原文（GroupPosts.tsx:393–394）；列表区用骨架块模拟（不伪造帖子文案）。
Widget aylaGroupPostsComposerSamples() => const _GroupPostsComposerSamples();

class _GroupPostsComposerSamples extends StatefulWidget {
  const _GroupPostsComposerSamples();

  @override
  State<_GroupPostsComposerSamples> createState() =>
      _GroupPostsComposerSamplesState();
}

class _GroupPostsComposerSamplesState
    extends State<_GroupPostsComposerSamples> {
  bool _narrowExpanded = false;
  bool _wideExpanded = false;

  static Future<void> _submit(AylaPostDraft draft) async {}

  /// 模拟 .group-posts-list 内容（sticky 场景头 + 骨架卡）。
  Widget _list() {
    return AylaGroupSceneStickyHead(
      // .group-posts-list { padding: sp3 sp4; gap: 0 }（posts.css 960/963）
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
      gap: 0,
      head: const AylaGroupSceneHead(
        title: '群内帖子',
        description: '浏览本群的最新动态',
        enter: false,
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < 4; i++)
            const Padding(
              padding: EdgeInsets.only(top: AylaSpacing.sp4),
              child: AylaSkeleton(height: 120),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AylaSpacing.sp6,
        children: <Widget>[
          Wrap(
            spacing: AylaSpacing.sp6,
            runSpacing: AylaSpacing.sp6,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: <Widget>[
              _stage(
                '窄屏 375 · 收起态（方角 + 仅上边框 + padding 8/12/12 + blur18 · 无外阴影）',
                width: 375,
                height: 360,
                composer: AylaGroupPostsComposer(
                  onSubmit: _submit,
                  groupId: 'g1',
                  expanded: _narrowExpanded,
                  onExpandedChange: (bool value) =>
                      setState(() => _narrowExpanded = value),
                  child: _list(),
                ),
              ),
              _stage(
                '窄屏 375 · 展开态（遮罩 z45 + 面板贴底 z50 + 250ms rise；'
                '点遮罩或右上收起键回收起态）',
                width: 375,
                height: 360,
                composer: AylaGroupPostsComposer(
                  onSubmit: _submit,
                  groupId: 'g1',
                  expanded: _wideExpanded,
                  onExpandedChange: (bool value) =>
                      setState(() => _wideExpanded = value),
                  child: _list(),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: AylaSpacing.sp6,
            runSpacing: AylaSpacing.sp6,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: <Widget>[
              _stage(
                '宽屏 820 · 收起态（auroraqua ≥769 覆写：margin 12/左 0 + radius 16 + '
                'padding 8 + 四边亮边 + --glass-shadow + blur24）',
                width: 820,
                height: 420,
                composer: AylaGroupPostsComposer(
                  onSubmit: _submit,
                  groupId: 'g1',
                  child: _list(),
                ),
              ),
              _stage(
                '宽屏 820 · 展开态（max-height calc(100% − 2 × sidebar-gutter)=396）',
                width: 820,
                height: 420,
                composer: AylaGroupPostsComposer(
                  onSubmit: _submit,
                  groupId: 'g1',
                  expanded: true,
                  child: _list(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stage(
    String label, {
    required double width,
    required double height,
    required Widget composer,
  }) {
    return SizedBox(
      width: width + 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AylaTextStyles.of(context).caption),
          const SizedBox(height: AylaSpacing.sp2),
          Builder(
            builder: (BuildContext ctx) => MediaQuery(
              data: MediaQuery.of(
                ctx,
              ).copyWith(size: Size(width, height)),
              child: SizedBox(width: width, height: height, child: composer),
            ),
          ),
        ],
      ),
    );
  }
}
