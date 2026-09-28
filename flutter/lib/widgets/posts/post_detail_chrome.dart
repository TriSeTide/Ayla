/// 帖子详情壳 —— `AylaPostDetailChrome` / `AylaPostDetailSkeleton` / `AylaPostDetailEmpty`。
///
/// 依据 19 号 §7.5 range B 的 B 类：**`AylaPostDetailChrome`（详情壳 + 玻璃头 +
/// 评论列 + 底部输入区）与详情骨架在库内没有整件** ⇒ 先补件（画布节）再装配。
///
/// ## 逐条事实源
/// - `posts.css:701–707` `.post-detail { height:100%; display:flex; flex-direction:column;
///   overflow:hidden; position:relative }`（relative 是编辑面板 absolute 的参照）；
/// - `posts.css:709–719` `.post-detail-head { flex:none; display:flex; align-items:center;
///   gap: sp3; padding: sp3 sp4; background: var(--glass-bg); backdrop-filter:
///   blur(18px) saturate(1.4); border-bottom: 1px solid var(--glass-border) }`；
///   **宽屏真正生效** `auroraqua.css:402–409`（@≥769）：`margin: var(--sidebar-gutter)`(12) +
///   四边 `1px --glass-border` + `radius-card`(16) + `--glass-shadow-compact` +
///   `--glass-filter`(blur24 sat1.4)；
///   入场动画 `auroraqua.css:334–344`（@≥769）/ `412–425`（@≤768）：`panel-from-top`（0,−20 → 0）；
/// - `posts.css:721–726` `.post-detail-title { flex:1; font-family: var(--font-display);
///   font-size:18px; color: var(--text-primary) }`；
/// - `posts.css:728–736` `.post-detail-scroll { flex:1; min-height:0; overflow-y:auto;
///   display:flex; flex-direction:column; padding: sp3 sp4; gap: sp3 }`；
/// - `posts.css:771–780` `.post-detail-composer { flex:none; width:100%; box-sizing:border-box;
///   padding: sp3 sp4; background: var(--glass-bg); backdrop-filter: blur(18px) saturate(1.4);
///   border-top: 1px solid var(--glass-border) }`；**宽屏真正生效** `auroraqua.css:347–359`
///   （@≥769）：`width:auto; margin: var(--sidebar-gutter); padding: sp2; 四边 1px 亮边;
///   radius-card; --glass-shadow; --glass-filter`（浮动玻璃卡，不再是整宽页脚）；
///   入场 `auroraqua.css:342–344`：`panel-from-bottom`（0,+20 → 0）；
/// - `posts.css:798–801` `.post-detail.is-editing > .post-detail-background
///   { visibility:hidden; pointer-events:none }` ⇒ Flutter 用
///   `Visibility(maintainState/Animation/Size: true)`（保持布局与状态、只隐藏绘制）
///   + `IgnorePointer` 表达（inert 的等价物）；
/// - 骨架 `posts.css:1111–1136` + 内联几何 `PostDetailPage.tsx:410–424`
///   （40 圆形 / 96×16 r8 / 64×12 r6 → head；h14 100% / h14 92% / h120 三根；
///   评论块 = 12×80 r6 + 13px 88%/76%/82%）；
/// - 空/错态 `PostDetailPage.tsx:430–438`（2026-09-28 用户裁决**修**，不再照抄原 web「无头 + 贴顶无内距」）：
///   顶栏与加载态同构（返回键 + 「帖子」）⇒ 由本件 [AylaPostDetailChrome] 承担（走 `body`）；
///   正文档 = 新增 `posts.css` 的 `.post-detail-state`，内距/间距逐值取自 web 既有空态规范
///   —— `.home-state`（`home.css:622–629`）：`gap: var(--sp-4)` + `padding: var(--sp-12) var(--sp-6)`
///   + 居中列；`.home-wide-empty`（`home.css:673–682`）：整页 `justify-content: center`；
///   出口沿用既有 `.btn.btn-ghost`「返回」（结构同 `MyPostsPage.tsx:187` 的错态）。
///
/// ## 与 web 的机制差异（登记）
/// 1. web 的入场动画 owner 是 CSS（`auroraqua-panel-from-top/bottom`），framer-motion
///    只负责滚动区（`tsx:610–613`）；Flutter 侧三者分离为：头部/输入区 = 本件内的
///    `AylaRevealItem`（±20、300ms），滚动区内容 = 调用方自己的 reveal；
/// 2. `.post-detail-scroll` 在群内（`.group-content` 祖先）另有负 margin 覆写
///    （`auroraqua.css:296–308`）—— 本件按**群外详情**实现（路由 /posts/:postId），
///    群内装配属 GroupPage 批次；
/// 3. `.post-detail-composer .composer-row/.composer-input`（782–793）由注入的
///    `AylaCommentComposer` 自带实现承载，本件只给外层壳。
///
/// ## 公开面
/// `AylaPostDetailChrome` · `AylaPostDetailSkeleton` · `AylaPostDetailEmpty` ·
/// 样张 `aylaPostDetailChromeSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/buttons.dart' show AylaIconButton;
import '../../theme/glass.dart'
    show AylaGlassButton, AylaGlassButtonVariant, AylaGlassSurface;
import '../../theme/tokens.dart';
import '../base/loading.dart' show AylaSkeleton;
import '../base/page_state.dart' show AylaPageState;
import '../base/reveal.dart' show AylaRevealItem;

/// 详情页壳：玻璃头 + 滚动区 + 底部输入区（编辑态时三者只透出背景）。
class AylaPostDetailChrome extends StatelessWidget {
  const AylaPostDetailChrome({
    super.key,
    this.title = '帖子',
    required this.onBack,
    this.share,
    this.ownerActions,
    this.editing = false,
    this.composer,
    this.scrollController,
    this.onScrollNotification,
    this.children = const <Widget>[],
    this.body,
  });

  /// 头部标题（`tsx:408/448` 恒「帖子」）。
  final String title;

  /// 返回（`tsx:405/445` `goBack`）。
  final VoidCallback onBack;

  /// 分享入口（`tsx:449–455`；null 不渲染）。
  final Widget? share;

  /// 作者操作区（`tsx:456–494`「编辑 / 删除」；null 不渲染）。
  final Widget? ownerActions;

  /// 编辑态：三个 `.post-detail-background` 只隐藏绘制、保留状态与滚动位置。
  final bool editing;

  /// 底部输入区（`tsx:709–717` 的 `AylaCommentComposer`；null 不渲染 —— 加载态无 composer）。
  final Widget? composer;

  /// 滚动控制器（页面持有时可用于触底分页）。
  final ScrollController? scrollController;

  /// 滚动通知（评论触底分页用）。
  final bool Function(ScrollNotification notification)? onScrollNotification;

  /// 滚动区内容（详情卡 + 评论列）；[body] 非空时忽略。
  final List<Widget> children;

  /// 非滚动主体（空 / 错态档 `.post-detail-state`）：顶栏之下自撑满、由调用方给
  /// [AylaPostDetailEmpty]；该档不是滚动区，故与 [children] 互斥。
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final double w = MediaQuery.sizeOf(context).width;
    final bool narrow = w <= 768;
    final bool reduced = MediaQuery.disableAnimationsOf(context);

    Widget head = Padding(
      // padding: sp3 sp4
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
      child: Row(
        // gap: var(--sp-3)
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          AylaIconButton(
            // tsx 405–407：icon-btn-40 + IconBack **22**（与 my-posts-head 的 20 不同）
            icon: AylaIcon(aylaIconByName('iconBack')!, size: 22),
            onPressed: onBack,
            semanticLabel: '返回',
          ),
          Expanded(child: _Title(title)),
          if (share != null) share!,
          if (ownerActions != null) ownerActions!,
        ],
      ),
    );
    // ≥769：浮动玻璃卡（margin 12 + 四边亮边 + radius 16 + compact 阴影 + blur24 sat1.4）
    if (!narrow) {
      head = Padding(
        padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
        child: AylaGlassSurface(
          blur: 24, // --glass-filter（blur24 sat1.4）
          radius: AylaRadii.rCard,
          shadow: AylaShadows.compact,
          child: head,
        ),
      );
    } else {
      head = DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AylaColors.glassBorder),
          ),
        ),
        child: AylaGlassSurface(
          blur: 18, // blur(18px) saturate(1.4)
          radius: 0,
          shadow: const <BoxShadow>[], // 窄屏无外阴影（只有 border-bottom）
          child: head,
        ),
      );
    }
    head = AylaRevealItem(
      enabled: !reduced,
      offset: const Offset(0, -20), // panel-from-top（0,−20 → 0）
      duration: AylaDurations.auroraqua,
      curve: AylaCurves.auroraquaEaseOut,
      child: head,
    );

    // 主体：默认滚动区（详情卡 + 评论列）；空 / 错态走 [body]（非滚动，自撑满）。
    final Widget main = body ??
        NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification ?? (ScrollNotification _) => false,
      child: SingleChildScrollView(
        controller: scrollController,
        // padding: sp3 sp4 + gap sp3（gap 由内容自带的上下间隔表达）
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AylaSpacing.sp3,
          children: children,
        ),
      ),
    );

    final List<Widget> column = <Widget>[
      _Background(visible: !editing, child: head),
      _Background(visible: !editing, expand: true, child: main),
      if (composer != null)
        _Background(
          visible: !editing,
          inert: editing,
          child: AylaRevealItem(
            enabled: !reduced,
            offset: const Offset(0, 20), // panel-from-bottom（0,+20 → 0）
            duration: AylaDurations.auroraqua,
            curve: AylaCurves.auroraquaEaseOut,
            child: _ComposerBox(narrow: narrow, child: composer!),
          ),
        ),
    ];

    // .post-detail：height 100% / column / overflow hidden / position relative
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: column,
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: AylaFonts.display,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 18, // .post-detail-title
        color: AylaColors.textPrimary,
      ),
    );
  }
}

/// `.post-detail-background` 的可见性/惰性等价物。
class _Background extends StatelessWidget {
  const _Background({
    required this.visible,
    required this.child,
    this.expand = false,
    this.inert = false,
  });

  final bool visible;
  final Widget child;
  final bool expand;
  final bool inert;

  @override
  Widget build(BuildContext context) {
    Widget box = child;
    if (inert) {
      box = ExcludeSemantics(child: IgnorePointer(child: box));
    }
    final Widget kept = Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true, // visibility:hidden：保留布局与状态，只隐藏绘制
      child: box,
    );
    // ignore: unnecessary_statements
    return expand ? Expanded(child: kept) : kept;
  }
}

/// `.post-detail-composer` 的外壳（窄屏整宽页脚 / 宽屏浮动玻璃卡）。
class _ComposerBox extends StatelessWidget {
  const _ComposerBox({required this.child, required this.narrow});

  final Widget child;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    if (narrow) {
      return DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AylaColors.glassBorder)),
        ),
        child: AylaGlassSurface(
          blur: 18,
          radius: 0,
          shadow: const <BoxShadow>[],
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp4,
            vertical: AylaSpacing.sp3,
          ),
          child: child,
        ),
      );
    }
    // ≥769：width auto + margin 12 + padding sp2 + 四边亮边 + radius 16 + --glass-shadow
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
      child: AylaGlassSurface(
        blur: 24,
        radius: AylaRadii.rCard,
        shadow: AylaShadows.glass,
        padding: const EdgeInsets.all(AylaSpacing.sp2),
        child: child,
      ),
    );
  }
}

/// 详情骨架（`posts.css:1111–1136` + `PostDetailPage.tsx:410–424` 的内联几何）。
class AylaPostDetailSkeleton extends StatelessWidget {
  const AylaPostDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '正在加载帖子',
      child: Center(
        child: ConstrainedBox(
          // max-width: calc(680px + 2 * sp4)
          constraints: const BoxConstraints(maxWidth: 680 + 2 * AylaSpacing.sp4),
          child: Padding(
            // padding: sp3 sp4
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: AylaSpacing.sp3,
              children: <Widget>[
                // .post-detail-skeleton-head：gap sp2
                Row(
                  spacing: AylaSpacing.sp2,
                  children: const <Widget>[
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: AylaSkeleton(shape: BoxShape.circle),
                    ),
                    SizedBox(
                      width: 96,
                      height: 16,
                      child: AylaSkeleton(radius: 8),
                    ),
                    SizedBox(
                      width: 64,
                      height: 12,
                      child: AylaSkeleton(radius: 6),
                    ),
                  ],
                ),
                const SizedBox(height: 14, child: AylaSkeleton(radius: 8)),
                const FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.92,
                  child: SizedBox(height: 14, child: AylaSkeleton(radius: 8)),
                ),
                const SizedBox(height: 120, child: AylaSkeleton(radius: 12)),
                // .post-detail-skeleton-comments：margin-top sp3 + padding-top sp3 + gap sp2
                Padding(
                  padding: const EdgeInsets.only(top: AylaSpacing.sp3),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: AylaColors.glassBorder),
                      ),
                    ),
                    padding: const EdgeInsets.only(top: AylaSpacing.sp3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: AylaSpacing.sp2,
                      children: const <Widget>[
                        SizedBox(width: 80, height: 12, child: AylaSkeleton(radius: 6)),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.88,
                          child: SizedBox(height: 13, child: AylaSkeleton(radius: 8)),
                        ),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.76,
                          child: SizedBox(height: 13, child: AylaSkeleton(radius: 8)),
                        ),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.82,
                          child: SizedBox(height: 13, child: AylaSkeleton(radius: 8)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情空 / 错态档（`PostDetailPage.tsx:430–438` 的空态分支）—— `.post-detail-state` 的等价物。
///
/// **2026-09-28 用户裁决：修**（不再照抄 web 原「无头 + 文案贴顶无内距」）。逐值依据：
/// - 顶栏不在本件：由 [AylaPostDetailChrome] 的 `body` 装配提供（返回键 + 「帖子」，
///   与加载态同构，`tsx:404–409`）；
/// - 正文档 = `.home-state`（`home.css:622–629`）：`padding: sp12 sp6` + `gap: sp4` +
///   居中列（由 [AylaPageState] 承载，数值与 web 同 token）；
/// - 整页居中 = `.home-wide-empty`（`home.css:673–682`）的 `justify-content: center`
///   ⇒ 由 [Center] 表达（`.post-detail-state` 的 `flex: 1` 由 chrome 的 `Expanded` 等价）；
/// - 出口沿用既有 ghost「返回」（`MyPostsPage.tsx:187` 的错态结构：文案 + 动作）。
class AylaPostDetailEmpty extends StatelessWidget {
  const AylaPostDetailEmpty({
    super.key,
    required this.message,
    required this.onBack,
  });

  /// 文案（`error ?? "帖子不存在"`）。
  final String message;

  /// `.btn.btn-ghost` 返回。
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AylaPageState(
        // web 空态 / 错态都带 role（status / alert）⇒ 两者都是 live region。
        liveRegion: true,
        description: message,
        children: <Widget>[
          AylaGlassButton(
            label: '返回',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: onBack,
          ),
        ],
      ),
    );
  }
}

/// 画布样张（骨架 / 空态装配两档）。
///
/// 空态样张给的是**装配态**（chrome 顶栏 + `body` 空态档）——需有界高度，`body` 走
/// `Expanded`；单独渲染 [AylaPostDetailEmpty] 时高度无界、居中无参照。
List<Widget> aylaPostDetailChromeSamples() => <Widget>[
      const SizedBox(height: 360, child: AylaPostDetailSkeleton()),
      SizedBox(
        height: 360,
        child: AylaPostDetailChrome(
          onBack: () {},
          body: AylaPostDetailEmpty(message: '帖子不存在', onBack: () {}),
        ),
      ),
    ];
