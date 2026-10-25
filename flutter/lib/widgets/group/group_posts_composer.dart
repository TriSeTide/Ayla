/// AylaGroupPostsComposer —— 群内帖子的**底部玻璃输入容器 + 展开态贴底**。
///
/// 本件是「壳」：编辑器本体一律复用 [AylaPostEditor]（`compact` + `collapsible` +
/// 半受控 `expanded` + `composerShell`），本文件**不重写编辑器**，只负责
/// web 上由 GroupPosts.tsx 与 .group-posts-input 承担的两件事：
/// ① 输入容器的玻璃材质与两档几何；② 展开态脱离文档流贴底。
///
/// ⚠️ **展开态没有黑色遮罩，但保留点击收起区**（2026-10-12 用户两轮反馈定型）：
/// 本件照搬 `.group-posts-scrim` 的**命中语义**（盖住列表与标题栏、点击 ⇒ 收起），
/// 但**不铺任何颜色** —— 该层原先的 rgba(70,91,146,.25)（--overlay-dim 弹窗压暗）
/// 在浅色极光底上偏暗，且只盖到面板顶边 ⇒ 面板上方一条戛然而止的深色带
/// （用户实报「遮罩截断」）。第一轮误把点击收起一并删除，第二轮用户纠正：
/// 「展开时点击这块区域应该收起输入框」⇒ **层留、色去**。
/// 原 `group-posts-scrim-in` 200ms 淡入随颜色删除（零绘制 ⇒ 无可淡入内容）。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// posts.css 923–929     .group-posts：height 100% · flex column · overflow hidden · position relative
/// posts.css 933–939     .group-posts-scrim：**absolute inset 0 · z-index 45**（与面板 z50 平级、
///                       夹在列表与面板之间）· 点击 ⇒ 收起；**无 background、无 animation**
///                       （2026-10-12 去色留层，见上）
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
/// GroupPosts.tsx 476–484 遮罩节点**保留**（editorExpanded 时渲染、点击 ⇒ setEditorExpanded(false)、
///                       aria-hidden="true"）；**零绘制**（posts.css 已去色）
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

import '../../core/media/media_actions.dart' show AylaMediaActions;
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

  /// 编辑器子树的**稳定身份**（跨「收起态在流内 ↔ 展开态贴底」的重挂载保护）。
  ///
  /// ⚠️ 本键是**焦点与草稿不丢的决定性条件**（2026-10-12 用户实报「点击输入框
  /// 展开后光标没进内容、收起后已输入的内容消失」）：
  ///
  /// web 的 `<textarea>` 是**同一个 DOM 节点**贯穿两态（`PostEditor.tsx:229–239`
  /// 只改 `rows` 1↔4，元素不重建）⇒ 焦点与 `value` 天然保留。
  /// 而 Flutter 侧两态的面板位于**不同槽位**（收起 = `Column` 的末子；展开 =
  /// `Stack` 的 `Positioned`），且外层 `AylaRevealItem` 还带
  /// `key: ValueKey<bool>(expanded)` 主动换键重播入场 ⇒ 整棵子树重挂载
  /// ⇒ `_AylaPostEditorState` 里的 `TextEditingController`/`FocusNode` 全部重建
  /// ⇒ 输入内容清空 + 焦点丢失（实测：展开后三个字段 `hasFocus` 全 false，
  /// 打字后收起文本回空）。
  ///
  /// 用 `GlobalKey` 让 Flutter 在**同一帧内**把该元素**搬移**（reparent）到新槽位，
  /// 而不是销毁重建 ⇒ `State` 连同控制器与焦点节点原样保留，
  /// 从而与 web「同一节点、只换行数」的语义等价。
  /// （重挂载仍会发生在外层 `AylaRevealItem` 上 —— 那正是**入场动画重播**所需，
  /// 与 `ValueKey<bool>(expanded)` 的既有意图一致。）
  final GlobalKey _editorAnchor = GlobalKey(
    debugLabel: 'group-posts-editor-anchor',
  );
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
            // z-index 45：**点击收起区**（透明，不铺任何颜色）。
            //
            // 语义与 web 的 `.group-posts-scrim` 一致：盖住列表与标题栏、点击 ⇒ 收起。
            // 两轮用户反馈共同定型（2026-10-12）：
            // ① 「直接去掉黑色遮罩」—— 该层原先铺 `AylaColors.overlayDim`
            //    （rgba(70,91,146,.25)，**弹窗压暗**语义），在浅色极光底上偏暗，
            //    且只盖到面板顶边 ⇒ 面板上方一条戛然而止的深色带（「遮罩截断」）；
            // ② 「展开时点击这块区域应该收起输入框」—— 所以**层要留、颜色要去**。
            // ⇒ 现在是无色 `HitTestBehavior.opaque` 命中层：观感全无、交互完整。
            // 与 web 的差异仅剩「不压暗」这一条，正是用户裁决的结果。
            if (_expanded)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: MouseRegion(
                    // web 的 `.group-posts-scrim` 是只挂 onClick 的 `<div>`、
                    // **无 cursor 声明** ⇒ 浏览器默认箭头（不显手型）。
                    cursor: SystemMouseCursors.basic,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setExpanded(false),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
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
            // ⚠️ 跨两态共用的稳定身份 ⇒ 展开/收起时元素**搬家**而非重建，
            // `TextEditingController`/`FocusNode` 与已输入内容原样保留（见 _editorAnchor）。
            key: _editorAnchor,
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
            // 未注入 ⇒ 落到库内组合动作（web `GroupPosts.tsx` 的编辑器同样自带
            // `uploadMediaFile`/`deleteMedia`，不需要调用方接线）。
            // 之前这三项 null 原样透传 ⇒ 群内发帖图片钮恒不可点。
            onPickMedia: widget.onPickMedia ??
                (int remaining, ValueChanged<double?> onProgress) =>
                    AylaMediaActions.pickMedia(
                      remaining: remaining,
                      onProgress: onProgress,
                    ),
            onRetryFailedMedia: widget.onRetryFailedMedia ??
                () => AylaMediaActions.pickMedia(
                      remaining: AylaMediaActions.maxPostMedia,
                    ),
            onRemoveMedia: widget.onRemoveMedia ?? AylaMediaActions.removeDraft,
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
                '窄屏 375 · 展开态（**无黑色遮罩**（点击层保留）+ 面板贴底 + 250ms rise '
                '+ 面板底提档 .78；点空白或右上收起键回收起态）',
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
                '宽屏 820 · 展开态（无黑色遮罩 · 面板底 .78 · '
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
