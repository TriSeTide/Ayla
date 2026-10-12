/// AylaGroupPostsComposer —— 群内帖子的**底部玻璃输入容器 + 展开态贴底**。
///
/// 本件是「壳」：编辑器本体一律复用 [AylaPostEditor]（`compact` + `collapsible` +
/// 半受控 `expanded` + `composerShell`），本文件**不重写编辑器**，只负责
/// web 上由 GroupPosts.tsx 与 .group-posts-input 承担的两件事：
/// ① 输入容器的玻璃材质与两档几何；② 展开态脱离文档流贴底。
///
/// ⚠️ **展开态没有遮罩**（2026-10-12 用户裁决「直接去掉黑色遮罩」，两端同步）：
/// 本件此前照搬过 `.group-posts-scrim`（rgba(70,91,146,.25) + 200ms 淡入），
/// 现已随 web 一并移除，收起只走面板右上角 32px 圆形键。
/// 原规则已从 `posts.css` 与 `GroupPosts.tsx` 删除 ⇒ 事实源里不再有它。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// posts.css 923–929     .group-posts：height 100% · flex column · overflow hidden · position relative
/// posts.css 933–939     ~~.group-posts-scrim~~ —— **2026-10-12 已删除**（无遮罩；见上）
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
/// GroupPosts.tsx 476–484 ~~遮罩节点~~ —— **2026-10-12 已删除**（无遮罩）
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
/// 4. 展开态底（`.group-posts-input.is-expanded`）取 `--glass-bg-strong`(.78)，
///    **一条声明两档通吃**（posts.css 里那条即可，无需 auroraqua 配合）：
///    它的特异性是 **0-2-0**，而 ≥769 的 `:is(.composer, .group-posts-input, …)`
///    取最具体实参 = **0-1-0** ⇒ CSS 级联**特异性优先于源码顺序**（媒体查询不贡献
///    特异性），故与「posts.css 先加载、auroraqua 后加载」无关。
///    Flutter 侧等价物 = [AylaGlassSurface] 的 `strong: expanded`（见 `_inputPanel`）。
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
            // ⚠️ **展开态无遮罩**（2026-10-12 用户裁决：「直接去掉黑色遮罩」）。
            // 原先这里铺一层 `AylaColors.overlayDim`（rgba(70,91,146,.25)）——
            // 它是「弹窗压暗」语义，在浅色极光底上偏暗；又因为只盖到面板顶边，
            // 面板上方会留下一条戛然而止的深色带（用户实报「遮罩截断」）。
            // 收起交互不受影响：面板右上角 32px 圆形收起键（PostEditor collapse-bar）。
            //
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
        // 展开态底**提高一档**（.55 → .78 = --glass-bg-strong），与用户所称
        // 「输入框原本的透明度」对齐（2026-10-12 用户裁决：「弹出输入框透明度
        // 与输入框原本保持一致」）。
        //
        // 事实链：面板内的 `.field` 自身也是 .55（`posts.css:1052–1059`），
        // **叠在面板底上** ⇒ 字段是「两层玻璃」，而 padding 带只有一层：
        //   · 原状 .55 + .55 ⇒ 字段观感 1−(1−.55)² = **.80**，带仅 **.55**
        //     ⇒ 落差 25 个百分点，展开后卡片文字会从带里透出（实机截图取证：
        //     卡片页脚「查看帖子 ○0 👁1」在带内清晰可辨）；
        //   · 改后 .78 + .55 ⇒ 字段 **.90**，带 **.78** ⇒ 落差 12 个百分点。
        // ⚠️ 带与字段不可能严格相等（只有面板 = 1 才有解）；把字段背景改透明虽能
        // 让两者相等，却会抹掉它的白边玻璃井 ⇒ 字段「消失」，故只提带的档。
        // 仍是既有 token（web 侧同一改动 = posts.css 的 `--glass-bg-strong`），
        // **不新增任何色值**。
        strong: expanded,
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
      fadeGlass: false,
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
                '窄屏 375 · 展开态（**无遮罩** + 面板贴底 + 250ms rise + 面板底提档 .78；'
                '右上收起键回收起态）',
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
                '宽屏 820 · 展开态（无遮罩 · 面板底 .78 · '
                'max-height calc(100% − 2 × sidebar-gutter)=396）',
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
