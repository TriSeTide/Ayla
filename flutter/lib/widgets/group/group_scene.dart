/// AylaGroupSceneHead / AylaGroupSceneStickyHead / AylaGroupScenePlaceholder
/// —— 群内子场景（语音 / 帖子 / 桌游 / 直播 / 群信息）统一标题栏与占位壳。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// group.css 358–379   .group-scene-head：position sticky · top 0 · z-index 10 · flex none ·
///                     box-sizing border-box · display flex · align-items center ·
///                     justify-content space-between · gap sp3(12) · min-height 72 · margin 0 ·
///                     padding sp4(16) · background --glass-bg(.55) · backdrop-filter
///                     --glass-filter(blur24 sat1.4) · 1px --glass-border · radius 16 ·
///                     box-shadow --glass-shadow-compact ·
///                     transition box-shadow / border-color / translate 300ms var(--auroraqua-ease)
/// group.css 381–384   .group-scene-head-copy：flex 1 · min-width 0
/// group.css 386–393   .group-scene-title：margin 0 · --text-primary · Fredoka 18 / w500 / lh 1.25
/// group.css 395–403   .group-scene-desc：margin sp1(4) 0 0 · overflow hidden · --text-secondary ·
///                     14 / lh 1.45 · text-overflow ellipsis · white-space nowrap（**单行省略**）
/// group.css 405–407   .group-scene-head > .btn { flex: none }
/// group.css 438–442   @supports not (backdrop-filter) ⇒ background --glass-bg-strong(.78)
/// group.css 444–452   @media (max-width: 480px)：align-items flex-start；> .btn min-height 40
/// auroraqua.css 336 / 419 + 621 / 637
///                     宽窄两段都给 .group-scene-head 挂 auroraqua-panel-from-top
///                     （0 −20px → 0,0 + 淡入，300ms cubic-bezier(0,0,.58,1)）；
///                     reduced-motion 两段都把 animation / translate 关掉
/// auroraqua.css 18–21 关键帧本体
/// group.css 456–465   .group-scene-placeholder：height 100% · flex column · align-items center ·
///                     justify-content center · gap sp3(12) · padding sp6(24) · text-align center
/// group.css 468–475   .group-scene-placeholder-actions：flex row · align-items center ·
///                     justify-content center · gap sp2(8) · margin-top sp1(4) · flex-wrap wrap
/// group.css 433–436   .group-games > .group-games-full { height: auto; min-height: 0 }
///                     —— 占位壳「只占标题以下的剩余区域」档，见 [AylaGroupScenePlaceholder.expandHeight]
/// shell.css 619–624   .placeholder-title：Fredoka 28 / w600 / --text-primary
/// shell.css 626–629   .placeholder-desc：14 / --text-secondary
/// shell.css 631–640   .placeholder-step：inline-block · padding 2px 10px · radius pill ·
///                     background --sakura-300 · color --grape-700 · Fredoka 11 / letter-spacing .8px
/// ```
///
/// ## 头部调用点（grep .group-scene-head 全量，3 处）
/// pages/group/GroupVoice.tsx:207–212（群内语音房）·
/// pages/group/GroupPosts.tsx:391–397（群内帖子，**带 .btn 尾键「我的帖子」**）·
/// pages/group/GroupGames.tsx:83–88（群内桌游）。
///
/// ## 占位调用点（grep .group-scene-placeholder 全量，群内 7 处 + 1 处历史组件）
/// | 调用点 | 文案 / 结构 | 按钮 |
/// |---|---|---|
/// | GroupVoice.tsx:201–203 | 骨架(96×80%) + 「正在加载语音房…」 · role=status | — |
/// | GroupVoice.tsx:221–229 | 「群内还没有语音房」/「建一个群内语音房，一起连麦」 | 「返回聊天」 |
/// | GroupPosts.tsx:406–412 | 「群内还没有帖子」/「在下方输入框发第一条帖子」 | 「返回聊天」 |
/// | GroupGames.tsx:90–93 | {error}（无标题）· role=alert | 「重试」 |
/// | GroupGames.tsx:101–107 | 「群内还没有桌游室」/「建一个群内桌游室吧」 | 「返回聊天」 |
/// | GroupLive.tsx:115–118 | 骨架(160×80%) | — |
/// | GroupLive.tsx:123–128 | 「群内直播加载失败」/{error} · role=alert | 「重试」 |
/// | GroupLive.tsx:134–152 | 「群内还没有直播」/「发起本群的第一场直播吧」 | **actions 行**：「创建群内直播」(.btn-glow) + 「返回聊天」(ghost) |
/// | GroupInfo.tsx:396–400 | 「群信息加载失败」/{loadError} · role=alert | 「重试」 |
/// | GroupScenePlaceholder.tsx:19–23 | F3 历史占位组件（标题 + 描述 + 步骤 chip） | — |
/// （19 号 §7.5 清册记作「群内 6 处空/错/加载壳」= 语音 2 + 帖子 1 + 桌游 2 + 直播 3
///  里的独立空/错/加载块计数口径；此处按 grep 原文逐行列全，**文案一律取自 web，无自编**。）
///
/// ## ⚠️ sticky 的机制差异（与 web 同构，且**不引入第二个滚动容器**）
/// web 的 .group-scene-head 是**滚动内容里的第一个流内子级**：position: sticky; top: 0
/// 让它钉在滚动口顶部（后续内容从玻璃头**下面**穿过），同时在流内保留自身高度。
/// Flutter 没有 sticky ⇒ [AylaGroupSceneStickyHead] 复用库内「自建 sticky」的做法
/// （先例 widgets/shell/channel_sidebar.dart 的 _SidebarStickyRow / _StickyRowRender：
/// **paint 阶段定位 + 同偏移的 applyPaintTransform**），差异如下并逐条登记：
///   ① 侧栏那条把行画在**不滚动的浮层**里，流内只放等高（固定 40px）占位 SizedBox；
///      本件的头部高度**由字体度量决定**（min-height: 72 只是下限，实测 ≈81px），
///      无法预估 ⇒ 头部**留在滚动内容里**（自然占位、零估算、零首帧跳变），
///      paint 时按滚动量平移把它钉住；
///   ② 绘制顺序：**先画正文、后画头部** ⇒ 头部压在滚动内容之上 = web z-index: 10；
///      命中测试同序（头部区域内命中即拦截，与 CSS 中头部元素就是点击目标一致）；
///   ③ 位移量在 paint 里**按几何求**（**不读 ScrollController**）：把头部自然位（layout 位）
///      换算到最近的 RenderAbstractViewport 祖先的坐标系，其 y 为负即"已滚过"，
///      取 max(0, −y) 抬起 ⇒ 恰好钉在滚动口（padding box）上沿 = CSS sticky top: 0。
///      几何在同帧 layout 完成后才求值（`_RenderSingleChildViewport._paintOffset` 同样是
///      paint 时按 offset.pixels 现算）⇒ 零滞后。**实测过的弯路**：第一版读
///      `ScrollController.offset`，在「拖拽末步只改 offset、不再走一帧 layout」时读到落后
///      一帧的值 —— 头部被压在 y = −9.7px 而不是 0（测试当场红），故改为几何口径；
///   ④ 不可等价项（登记）：scroll-padding-top: calc(72px + sp4)（滚动锚点补偿）在 Flutter
///      无对应物 ⇒ 未实现；transition: box-shadow/border-color/translate 在 web 上
///      **没有任何状态会改变这三者**（入场与 sticky 走 animation/位移）⇒ 不挂该组过渡。
///
/// ## @supports not (backdrop-filter) 的降级（登记）
/// web 只对本件把面层换成 --glass-bg-strong(.78)。Flutter 的降级是**全局玻璃质量档**
/// （[AylaGlassConfig.quality]，theme/glass.dart）：实底档统一取 web 另一条 @supports
/// 路径的 --surface（auroraqua.css 527–551），**不按件区分 .78** ⇒ 本件沿用全局档，
/// 不额外覆盖（差异已登记，未改动公共件）。
///
/// ## 公开面
/// AylaGroupSceneHead · AylaGroupSceneStickyHead · AylaGroupScenePlaceholder ·
/// AylaGroupScenePlaceholderRole · 样张 aylaGroupSceneSamples()

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/loading.dart' show AylaSkeleton;
import '../base/reveal.dart';

/// 群内场景统一标题栏（.group-scene-head，group.css 358–452）。
///
/// 语音 / 帖子 / 桌游三个场景共用：内容区独立玻璃卡，与下方场景卡同一条内容轨道。
/// 单独使用时它只是「一张玻璃卡」；需要吸顶时用 [AylaGroupSceneStickyHead] 包住。
class AylaGroupSceneHead extends StatelessWidget {
  const AylaGroupSceneHead({
    super.key,
    required this.title,
    this.description,
    this.trailing,
    this.enter = true,
  });

  /// min-height: 72px（group.css 368）。
  static const double minHeight = 72;

  /// .group-scene-title（Fredoka 18 / w500 / lh 1.25 / --text-primary）。
  final String title;

  /// .group-scene-desc（14 / lh 1.45 / --text-secondary / **单行省略**）。
  final String? description;

  /// 尾键槽（.group-scene-head > .btn：flex: none）。
  ///
  /// 现存唯一调用点：GroupPosts.tsx:396 的 <Link className="btn btn-ghost">我的帖子</Link>。
  final Widget? trailing;

  /// 入场动画：auroraqua-panel-from-top（0 −20px → 0,0 + 淡入，300ms easeOut）。
  ///
  /// web 在 ≥769（auroraqua 336）与 ≤768（419）两段都挂同一个关键帧 ⇒ 全宽度都播；
  /// reduced-motion 关掉（621 / 637）。MediaQuery.disableAnimations 时自动直出。
  final bool enter;

  /// .group-scene-title：Fredoka 18 / w500 / lh 1.25 / --text-primary。
  static TextStyle titleStyle(AylaTextStyles t) =>
      t.cardTitle.copyWith(fontSize: 18, height: 1.25);

  /// .group-scene-desc：14 / lh 1.45 / --text-secondary（字重回落到正文 400）。
  static TextStyle descStyle(AylaTextStyles t) => t.caption.copyWith(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AylaColors.textSecondary,
  );

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // @media (max-width: 480px)：align-items: flex-start（444–447）
    final bool narrow = MediaQuery.sizeOf(context).width <= 480;

    final Widget head = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: minHeight),
      child: AylaGlassSurface(
        radius: AylaRadii.rCard, // border-radius: 16px
        blur: AylaGlass.blurCard, // backdrop-filter: --glass-filter(blur24 sat1.4)
        shadow: AylaShadows.compact, // --glass-shadow-compact
        padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
        child: Row(
          crossAxisAlignment: narrow
              ? CrossAxisAlignment.start // ≤480：align-items flex-start
              : CrossAxisAlignment.center,
          children: <Widget>[
            // .group-scene-head-copy：flex 1 + min-width 0
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // .group-scene-title：**无省略规则**（h3 可换行）
                  Text(title, style: titleStyle(t)),
                  if (description != null)
                    Padding(
                      // .group-scene-desc { margin: var(--sp-1) 0 0 }
                      padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                      child: Text(
                        description!,
                        style: descStyle(t),
                        maxLines: 1, // white-space: nowrap
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            // gap: var(--sp-3)；.group-scene-head > .btn { flex: none }
            if (trailing != null) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp3),
              _IntrinsicSlot(child: trailing!),
            ],
          ],
        ),
      ),
    );

    if (!enter) return head;
    // ⚠️ 不传 enabled：reduced-motion 由 [AylaRevealItem] 内部按
    // 「MediaQuery.disableAnimations」判定（auroraqua 621/637 两段都关动画）。
    // 曾在此显式写 enabled: !MediaQuery.disableAnimationsOf(context) —— 实测在
    // widget test 里该式为 true（头部整段动画被跳过），而同一棵树里 AylaRevealItem
    // 自己的判定为 false（裸 AylaRevealItem 会正常播放）⇒ 两处口径不一致，改用单一口径。
    return AylaRevealItem(
      offset: const Offset(0, -20), // auroraqua-panel-from-top: 0 −20px → 0,0
      duration: AylaDurations.auroraqua,
      curve: AylaCurves.auroraquaEaseOut,
      child: head,
    );
  }
}

/// 尾键槽 —— web `.group-scene-head > .btn { flex: none }` 的等价。
///
/// ⚠️ 为什么不能直接把按钮放进 Row：AylaGlassButton 在**有界松高**约束下会撑满可用高度
/// （根因在 `theme/glass.dart` 的 `Center(widthFactor: 1, child: Text(...))` —— 缺
/// `heightFactor: 1` ⇒ Center 在交叉轴取满 maxHeight；实测 600 高宿主里按钮被拉到
/// 600×106.8，而 web 的 `.btn` 恒为内容高 40）。本槽位给子级**无界高度**、
/// 再按子级自身高度定尺 ⇒ 无论宿主是否限制高度，尾键都保持自身高度（与 web 同语义）。
/// （登记：这属"兜住既有件行为"，不是本件自由发挥；glass.dart 那处若修好，本槽位可退化为直放。）
class _IntrinsicSlot extends SingleChildRenderObjectWidget {
  const _IntrinsicSlot({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _IntrinsicSlotRender();
}

class _IntrinsicSlotRender extends RenderProxyBox {
  @override
  void performLayout() {
    final RenderBox? c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    // 横向仍受父约束（可撑宽），纵向松到无界 ⇒ 子级按自身高度定尺
    c.layout(
      BoxConstraints(
        minWidth: 0,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
      ),
      parentUsesSize: true,
    );
    size = constraints.constrain(c.size);
  }
}

/// 群内场景滚动壳：**单滚动容器** + 吸顶玻璃头部（.group-scene-head 的 sticky 等价）。
///
/// 事实源与机制差异见本文件头「⚠️ sticky 的机制差异」一节（含两处登记的不等价项）。
/// 结构 = SingleChildScrollView(padding, child: [head（流内自然占位）, gap, child])，
/// 头部在 paint 阶段按滚动量平移、并最后绘制（压住滚动内容，等价 z-index: 10）。
class AylaGroupSceneStickyHead extends StatelessWidget {
  const AylaGroupSceneStickyHead({
    super.key,
    required this.head,
    required this.child,
    this.padding = const EdgeInsets.all(AylaSpacing.sp4),
    this.gap = AylaSpacing.sp4,
    this.controller,
  });

  /// 头部（通常是 [AylaGroupSceneHead]）。
  final Widget head;

  /// 头部以下的内容（场景列表 / 网格 / 帖子流 / 占位壳）。
  final Widget child;

  /// 滚动容器四向留白：.group-voice / .group-games 为 sp4（group.css 414），
  /// .group-posts-list 为 padding: sp3 sp4（posts.css 960）。
  final EdgeInsets padding;

  /// 头部与首个内容块之间的距离（父容器 gap：语音/桌游 sp4、帖子列表 0）。
  final double gap;

  /// 外部滚动控制器（可选；吸顶位移由 paint 阶段的几何求值 —— **不读 controller**）。
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: controller,
      padding: padding,
      child: _SceneStickyLayout(gap: gap, head: head, body: child),
    );
  }
}

/// 头部 + 正文的两子级布局：头部自然占位（精确高度），paint 时按滚动几何平移吸顶。
class _SceneStickyLayout extends MultiChildRenderObjectWidget {
  // 非 const：const 构造器不能把参数拼进 const 子级表（children 含参数引用）
  _SceneStickyLayout({
    required this.gap,
    required Widget head,
    required Widget body,
  }) : super(children: <Widget>[head, body]);

  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SceneStickyRender(gap: gap);

  @override
  void updateRenderObject(BuildContext context, _SceneStickyRender renderObject) {
    renderObject.gap = gap;
  }
}

class _SceneStickyRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MultiChildLayoutParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MultiChildLayoutParentData> {
  _SceneStickyRender({required double gap}) : _gap = gap;

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  Size _headSize = Size.zero;
  double _dy = 0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MultiChildLayoutParentData) {
      child.parentData = MultiChildLayoutParentData();
    }
  }

  @override
  void performLayout() {
    final BoxConstraints c = constraints;
    // 交叉轴铺满（等价 flex column 的 stretch）：tight 宽度 + 无界高度。
    final double width = c.hasBoundedWidth ? c.maxWidth : c.minWidth;
    final BoxConstraints inner = BoxConstraints(
      minWidth: width,
      maxWidth: width,
      minHeight: 0,
      maxHeight: double.infinity,
    );
    final RenderBox head = firstChild!;
    final RenderBox body = lastChild!;
    head.layout(inner, parentUsesSize: true);
    _headSize = head.size;
    body.layout(inner, parentUsesSize: true);
    size = constraints.constrain(
      Size(width, _headSize.height + _gap + body.size.height),
    );
    // ⚠️ 这里**不能**求值 topOf()：位置一律在 paint 阶段求值
    // （layout 期间读兄弟/滚动几何会触发 'size accessed beyond the scope of resize'，
    //  先例 channel_sidebar.dart:_StickyRowRender 的实测结论）。
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox head = firstChild!;
    final RenderBox body = lastChild!;
    final double bodyTop = _headSize.height + _gap;
    // ① 先画正文（头部要压在它之上 = web .group-scene-head { z-index: 10 }）
    context.paintChild(body, Offset(offset.dx, offset.dy + bodyTop));
    // ② 再画头部：CSS position: sticky; top: 0（同帧几何求值，不读 ScrollController）
    _dy = _stickyDy();
    context.paintChild(head, Offset(offset.dx, offset.dy + _dy));
  }

  /// 吸顶位移 = max(0, −头部自然位在滚动口坐标系里的 y)。
  ///
  /// 滚动口 = 最近的 [RenderAbstractViewport] 祖先（SingleChildScrollView 的
  /// _RenderSingleChildViewport 即实现该接口）；它的 padding box 上沿就是 CSS
  /// sticky 的约束矩形上沿。几何在 paint 阶段读的是**本帧 layout 的结果**
  /// （viewport 的 paint 偏移同样在 paint 时现算）⇒ 与内容同帧、零滞后。
  double _stickyDy() {
    final RenderBox? viewport = _viewportAncestor();
    if (viewport == null) return 0;
    final Offset inViewport = viewport.globalToLocal(localToGlobal(Offset.zero));
    return math.max(0, -inViewport.dy);
  }

  /// 最近的滚动口祖先（无 ⇒ null）。
  RenderBox? _viewportAncestor() {
    RenderObject? node = parent;
    while (node != null && node is! RenderAbstractViewport) {
      node = node.parent;
    }
    if (node is RenderBox && node.hasSize) return node;
    return null;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    // ⚠️ 必须与 paint 同偏移：否则 localToGlobal / 命中测试 / 语义树 / 测试 getRect
    // 读到的还是布局坐标（先例 channel_sidebar.dart:_StickyRowRender）。
    // 且**不能直接复用上次 paint 的 _dy**：滚动位置变化到本帧 paint 之间若有读者
    // （测试 getRect / 命中测试）会读到跨帧的旧位移（实测差 4px）⇒ 与 paint 同源现算。
    if (identical(child, firstChild)) {
      transform.translateByDouble(0, _dy = _stickyDy(), 0, 1);
    } else {
      transform.translateByDouble(0, _headSize.height + _gap, 0, 1);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox head = firstChild!;
    if (_headSize.height > 0 &&
        (Offset.zero & Size(size.width, _headSize.height))
            .shift(Offset(0, _dy))
            .contains(position)) {
      // 头部在上层：命中头部区域即拦截（等价 CSS 中头部元素自己是点击目标，
      // 挡住下面滚过去的列表），但头部内部的按钮仍需走到。
      result.addWithPaintOffset(
        offset: Offset(0, _dy),
        position: position,
        hitTest: (BoxHitTestResult r, Offset p) => head.hitTest(r, position: p),
      );
      return true;
    }
    return result.addWithPaintOffset(
      offset: Offset(0, _headSize.height + _gap),
      position: position,
      hitTest: (BoxHitTestResult r, Offset p) =>
          lastChild!.hitTest(r, position: p),
    );
  }
}

/// 占位语义（web role）：alert（错误，assertive）/ status（加载，polite）。
enum AylaGroupScenePlaceholderRole { none, status, alert }

/// 子场景占位壳（.group-scene-placeholder，group.css 456–475）。
///
/// 结构逐条对齐 web：
/// Column(center) [ title?, desc?, children…?, actions(单键直出 / 多键进 actions 行) ]；
/// 外层 gap: sp3、padding: sp6、text-align: center。
class AylaGroupScenePlaceholder extends StatelessWidget {
  const AylaGroupScenePlaceholder({
    super.key,
    this.title,
    this.description,
    this.children = const <Widget>[],
    this.actions = const <Widget>[],
    this.expandHeight = true,
    this.role = AylaGroupScenePlaceholderRole.none,
  });

  /// .placeholder-title（Fredoka 28 / w600 / --text-primary）。
  final String? title;

  /// .placeholder-desc（14 / --text-secondary）。
  final String? description;

  /// 标题 / 描述之外的任意块（骨架、加载文案、步骤 chip）：按传入顺序插在描述之后。
  final List<Widget> children;

  /// 操作键：1 个时按 web 直出为容器直接子级；≥2 个时进 .group-scene-placeholder-actions 行。
  final List<Widget> actions;

  /// height: 100% 档（默认开）。
  ///
  /// web 给部分调用点加 .group-games-full（height: auto; min-height: 0，group.css 433–436）
  /// 避免与吸顶头部叠加溢出 ⇒ 传 false。
  final bool expandHeight;

  /// 语义角色（role="alert" / role="status"）：映射为 live region。
  final AylaGroupScenePlaceholderRole role;

  /// .placeholder-title：Fredoka 28 / w600 / --text-primary（shell.css 619–624）。
  static const TextStyle titleStyle = TextStyle(
    fontFamily: AylaFonts.display,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    color: AylaColors.textPrimary,
  );

  /// .placeholder-desc：14 / --text-secondary（shell.css 626–629）。
  static const TextStyle descStyle = TextStyle(
    fontFamily: AylaFonts.body,
    fontFamilyFallback: AylaFonts.cjkFallback,
    fontSize: 14,
    color: AylaColors.textSecondary,
  );

  /// .placeholder-step：sakura-300 底 + grape-700 字 + Fredoka 11 / ls .8（shell.css 631–640）。
  static Widget stepChip(String step) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AylaColors.sakura300,
      borderRadius: AylaRadii.pill,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Text(
        step,
        style: const TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          letterSpacing: 0.8,
          color: AylaColors.grape700,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final List<Widget> column = <Widget>[
      if (title != null)
        Text(title!, style: titleStyle, textAlign: TextAlign.center),
      if (description != null)
        Text(description!, style: descStyle, textAlign: TextAlign.center),
      ...children,
      // 单键直出 / 多键进 actions 行（含 margin-top sp1 与 flex-wrap）
      if (actions.length == 1)
        actions.first
      else if (actions.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: AylaSpacing.sp1),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AylaSpacing.sp2,
            runSpacing: AylaSpacing.sp2,
            children: actions,
          ),
        ),
    ];

    final Widget box = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // height: 100%：父高确定时撑满（MainAxisSize.max ⇒ 内容在其中居中）；
        // 父高不定（滚动内容里）或 .group-games-full 档 ⇒ 自然高度（CSS 同语义）
        final bool fill = expandHeight && c.hasBoundedHeight;
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: fill ? c.maxHeight : 0),
          child: Padding(
            padding: const EdgeInsets.all(AylaSpacing.sp6),
            // justify-content: center + align-items: center
            child: Column(
              mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: AylaSpacing.sp3,
              children: column,
            ),
          ),
        );
      },
    );

    if (role == AylaGroupScenePlaceholderRole.none) return box;
    return Semantics(
      container: true,
      liveRegion: true, // role="alert"（assertive）/ role="status"（polite）
      child: box,
    );
  }
}


// ======================= 样张 =======================

/// 群内场景标题栏 / 占位壳样张（文案**逐字取自 web**，见本文件头调用点表）。
Widget aylaGroupSceneSamples() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp6,
      children: <Widget>[
        // ---- 头部：三个场景的**原文**（GroupVoice 207 / GroupPosts 391 / GroupGames 83）----
        _SampleRow(
          children: <Widget>[
            _SampleBox(
              label: '语音场景头（GroupVoice.tsx:207–212 · sticky 玻璃卡 min-h 72）',
              width: 520,
              child: const AylaGroupSceneHead(
                title: '群内语音房',
                description: '选择一个房间加入，或点击右下角创建新的群内语音房',
                enter: false,
              ),
            ),
            _SampleBox(
              label: '帖子场景头（GroupPosts.tsx:391–397 · 尾键 .btn.btn-ghost「我的帖子」）',
              width: 520,
              child: AylaGroupSceneHead(
                title: '群内帖子',
                description: '浏览本群的最新动态',
                enter: false,
                trailing: AylaGlassButton(
                  label: '我的帖子',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: () {},
                ),
              ),
            ),
          ],
        ),
        _SampleRow(
          children: <Widget>[
            _SampleBox(
              label: '桌游场景头（GroupGames.tsx:83–88）',
              width: 520,
              child: const AylaGroupSceneHead(
                title: '群内桌游',
                description: '选择一个房间加入，或创建新的群内桌游室',
                enter: false,
              ),
            ),
            _SampleBox(
              label: '长描述（.group-scene-desc 单行省略）· 入场动画（auroraqua-panel-from-top）',
              width: 520,
              child: AylaGroupSceneHead(
                title: '群内语音房',
                description: '选择一个房间加入，或点击右下角创建新的群内语音房'
                    '（这段是刻意加长的样张串，用来验证 white-space: nowrap + ellipsis 单行省略）',
                trailing: AylaGlassButton(
                  label: '我的帖子',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: () {},
                ),
              ),
            ),
          ],
        ),
        // ---- ≤480 档：align-items flex-start + 尾键 min-height 40 ----
        _SampleRow(
          children: <Widget>[
            _SampleBox(
              label: '≤480 档（MediaQuery 375：align-items flex-start，尾键 40 高）',
              width: 420,
              child: Builder(
                builder: (BuildContext ctx) => MediaQuery(
                  data: MediaQuery.of(
                    ctx,
                  ).copyWith(size: const Size(375, 812)),
                  child: AylaGroupSceneHead(
                    title: '群内帖子',
                    description: '浏览本群的最新动态',
                    enter: false,
                    trailing: AylaGlassButton(
                      label: '我的帖子',
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ),
                ),
              ),
            ),
            _SampleBox(
              label: '吸顶实测（在 240 高的盒里滚动：头部钉在滚动口上沿，卡片从玻璃头下面穿过）',
              width: 420,
              child: SizedBox(
                height: 240,
                child: AylaGroupSceneStickyHead(
                  head: const AylaGroupSceneHead(
                    title: '群内语音房',
                    description: '滚动看吸顶',
                    enter: false,
                  ),
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < 8; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
                          child: AylaGlassSurface(
                            radius: AylaRadii.rCard,
                            padding: const EdgeInsets.all(AylaSpacing.sp4),
                            child: Text('模拟房间卡 $i'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        // ---- 占位壳：文案逐字取自 web 调用点 ----
        _SampleRow(
          children: <Widget>[
            _SampleBox(
              label: '空态 · 语音（GroupVoice.tsx:221–229）',
              width: 360,
              child: SizedBox(
                height: 260,
                child: AylaGroupScenePlaceholder(
                  title: '群内还没有语音房',
                  description: '建一个群内语音房，一起连麦',
                  actions: <Widget>[
                    AylaGlassButton(
                      label: '返回聊天',
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
            _SampleBox(
              label: '空态 · 帖子（GroupPosts.tsx:406–412）',
              width: 360,
              child: SizedBox(
                height: 260,
                child: AylaGroupScenePlaceholder(
                  title: '群内还没有帖子',
                  description: '在下方输入框发第一条帖子',
                  actions: <Widget>[
                    AylaGlassButton(
                      label: '返回聊天',
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
            _SampleBox(
              label: '空态 · 桌游（GroupGames.tsx:101–107 · .group-games-full 档）',
              width: 360,
              child: SizedBox(
                height: 260,
                child: AylaGroupScenePlaceholder(
                  expandHeight: false, // .group-games-full：height auto
                  title: '群内还没有桌游室',
                  description: '建一个群内桌游室吧',
                  actions: <Widget>[
                    AylaGlassButton(
                      label: '返回聊天',
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        _SampleRow(
          children: <Widget>[
            _SampleBox(
              label: '空态 · 直播 + actions 行（GroupLive.tsx:134–152：.btn-glow + ghost 并排）',
              width: 420,
              child: SizedBox(
                height: 300,
                child: AylaGroupScenePlaceholder(
                  title: '群内还没有直播',
                  description: '发起本群的第一场直播吧',
                  actions: <Widget>[
                    AylaGlassButton(
                      label: '创建群内直播',
                      variant: AylaGlassButtonVariant.glow,
                      onPressed: () {},
                    ),
                    AylaGlassButton(
                      label: '返回聊天',
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
            _SampleBox(
              label: '错误态 · role=alert（GroupLive.tsx:123–128 / GroupInfo.tsx:396–400；'
                  '错误正文取 web 自己的兜底文案「加载直播间失败」/「加载群信息失败」）',
              width: 420,
              child: SizedBox(
                // 两档并排各占一半：单档内容高约 130 ⇒ 盒高 460 才不触发 RenderFlex 溢出
                height: 460,
                child: Column(
                  spacing: AylaSpacing.sp6,
                  children: <Widget>[
                    Expanded(
                      child: AylaGroupScenePlaceholder(
                        role: AylaGroupScenePlaceholderRole.alert,
                        title: '群内直播加载失败',
                        description: '加载直播间失败',
                        actions: <Widget>[
                          AylaGlassButton(
                            label: '重试',
                            variant: AylaGlassButtonVariant.ghost,
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: AylaGroupScenePlaceholder(
                        role: AylaGroupScenePlaceholderRole.alert,
                        title: '群信息加载失败',
                        description: '加载群信息失败',
                        actions: <Widget>[
                          AylaGlassButton(
                            label: '重试',
                            variant: AylaGlassButtonVariant.ghost,
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _SampleBox(
              label: '加载档（GroupVoice.tsx:201–203 role=status 骨架 96/80%；'
                  'GroupLive.tsx:115–118 骨架 160/80%）+ F3 历史档（GroupScenePlaceholder.tsx:19–23）',
              width: 420,
              child: SizedBox(
                height: 460,
                child: Column(
                  spacing: AylaSpacing.sp6,
                  children: <Widget>[
                    Expanded(
                      child: AylaGroupScenePlaceholder(
                        role: AylaGroupScenePlaceholderRole.status,
                        children: <Widget>[
                          FractionallySizedBox(
                            widthFactor: 0.8,
                            child: AylaSkeleton(height: 96),
                          ),
                          const Text('正在加载语音房…'),
                        ],
                      ),
                    ),
                    Expanded(
                      child: AylaGroupScenePlaceholder(
                        title: '群内语音',
                        description: '该群语音房卡片列表，点卡片进房间',
                        children: <Widget>[
                          AylaGroupScenePlaceholder.stepChip('F5'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 样张格子（左侧标签 + 固定宽内容）。
class _SampleBox extends StatelessWidget {
  const _SampleBox({
    required this.label,
    required this.width,
    required this.child,
  });

  final String label;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AylaTextStyles.of(context).caption),
          const SizedBox(height: AylaSpacing.sp2),
          child,
        ],
      ),
    );
  }
}

/// 样张行（自动换行）。
class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: children,
    );
  }
}
