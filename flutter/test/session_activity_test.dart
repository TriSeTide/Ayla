/// A5：跨页面媒体会话悬浮球控制组定向测试 —— 逐条对照
/// `layout/SessionActivityIndicator.tsx`（181 行）与 `styles/shell.css:458–575 / 651–660`，
/// 层叠事实取 `auroraqua.css:54–94`（按钮组只含 `.session-activity-toggle`）。
///
/// 覆盖四类（§1.5 要求：结构 / 关键尺寸 / 交互回调 / 易错点断言）：
/// 1. 结构：语音球 → 直播球 → 把手；无活动态零渲染；
/// 2. 尺寸与几何：44 / 28×44 / gap 8；宽屏 right 24 · top 80，窄屏 right 16 ·
///    top calc(56 + safe-top + 48)；`Positioned` 契约；
/// 3. 交互：点把手收起/展开（位移 24、球位移 64 + 淡隐、图标转 180°、aria 翻转）、
///    球的点击回调；5px 拖动阈值、clamp 8…视口高-52、拖动后抑制点击、鼠标非主键不拖；
/// 4. 易错点：hover 底色**透明**（`--glass-bg-hover` 未定义 ⇒ 实渲染为初始值）、
///    球 hover `scale(1.08)` 且**无** 1.02/.98（不在按钮组）、球**无**背板模糊、
///    把手保留 blur18、reduced-motion 立即到位。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/buttons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/session_activity.dart';

void main() {
  const AylaActivitySession voice = AylaActivitySession(
    sessionId: '5',
    sourceRoute: '/voice/5',
    title: '语音房',
  );
  const AylaActivitySession live = AylaActivitySession(
    sessionId: '9',
    sourceRoute: '/live/start/9',
    title: '直播间',
  );

  /// 宿主：预览主题 + 覆写 `MediaQuery`（断点 / `innerHeight` / safe-area 都读它）。
  Widget host(
    Widget child, {
    Size viewport = const Size(1000, 700),
    EdgeInsets padding = EdgeInsets.zero,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: viewport,
              padding: padding,
              disableAnimations: disableAnimations,
            ),
            // 组件返回 Positioned ⇒ 调用方必须给 Stack 宿主
            child: SizedBox.fromSize(
              size: viewport,
              child: Stack(children: <Widget>[child]),
            ),
          ),
        ),
      ),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 组件返回的那层 `Positioned`（子树里还有阴影层的 `Positioned.fill`、TabBadge 等）。
  Positioned groupPositioned(WidgetTester tester) {
    return tester.widget<Positioned>(
      find.byWidgetPredicate(
        (Widget w) => w is Positioned && w.child is TweenAnimationBuilder<double>,
      ),
    );
  }

  /// 球面（底色就是身份色：语音 sakura-100 / 直播 ice-300）。
  Finder ballBox({required bool isVoice}) => find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                (isVoice ? AylaColors.sakura100 : AylaColors.ice300),
      );

  /// 把手面（28×44）。`AnimatedContainer` 没有 width/height getter（构造参数被折进
  /// `constraints`），故按「`›` 字符最近的 `AnimatedContainer` 祖先」定位。
  Finder toggleBox() => find
      .ancestor(of: find.text('›'), matching: find.byType(AnimatedContainer))
      .last;

  /// 是否存在某个 `AnimatedScale` 取到该缩放值（库内 1.02/.98 是按钮组，1.08 只属本件的球）。
  bool hasScale(WidgetTester tester, double scale) => tester
      .widgetList<AnimatedScale>(find.byType(AnimatedScale))
      .any((AnimatedScale w) => (w.scale - scale).abs() < 0.001);

  /// 是否存在平移 dx 的 `Transform`（组位移 24/16、球位移 64）。
  bool hasTranslateX(WidgetTester tester, double dx) => tester
      .widgetList<Transform>(find.byType(Transform))
      .any((Transform t) => (t.transform.storage[12] - dx).abs() < 0.01);

  /// 把手字符的样式宿主。
  ///
  /// ⚠️ 必须限定在把手之内：`previewTheme` 的 `Material` 自己就带一层
  /// `AnimatedDefaultTextStyle`，不限定作用域会 "Too many elements"。
  AnimatedDefaultTextStyle glyphStyleHost(WidgetTester tester) =>
      tester.widget<AnimatedDefaultTextStyle>(
        find.descendant(
          of: toggleBox(),
          matching: find.byType(AnimatedDefaultTextStyle),
        ),
      );

  /// 把手自身的 `AylaPressScale`（语义节点宿主；球也有，故按 `›` 反查最近的）。
  Finder togglePressScale() => find
      .ancestor(of: find.text('›'), matching: find.byType(AylaPressScale))
      .last;

  /// 真实语义树里的全部节点标签。
  ///
  /// ⚠️ 不能用 `find.bySemanticsLabel` 断言「已排除」：它读的是各 render object 的
  /// `debugSemantics`（子树被 `ExcludeSemantics` 摘掉后该引用可能仍在）⇒ 假阳性。
  /// 这里遍历 `SemanticsOwner` 的树，才是「屏幕阅读器真正看得到」的口径。
  ///
  /// ⚠️ 取树的入口必须是 `binding.pipelineOwner`：弃用提示建议的
  /// `RendererBinding.rootPipelineOwner.semanticsOwner` 在 widget test 里读到的是**空树**
  /// （实测 2026-09-21：同一用例换成它之后标签集合 = `{}`，断言随即失败）。
  Set<String> semanticsLabels(WidgetTester tester) {
    // ignore: deprecated_member_use
    final SemanticsOwner? owner = tester.binding.pipelineOwner.semanticsOwner;
    final SemanticsNode? root = owner?.rootSemanticsNode;
    final Set<String> labels = <String>{};
    void walk(SemanticsNode node) {
      if (node.label.isNotEmpty) labels.add(node.label);
      node.visitChildren((SemanticsNode child) {
        walk(child);
        return true;
      });
    }

    if (root != null) walk(root);
    return labels;
  }

  /// 球的**当前**不透明度（淡出层活值）。
  ///
  /// ⚠️ 必须读 `FadeTransition.opacity.value`（活值）：`AnimatedOpacity.opacity` 是**目标值**，
  /// 读它在动画中途也永远是终点（0），会把「有动画」误判成「跳变」。返回列表的第 0 项
  /// 是离球最近的 `FadeTransition`（= 本件的淡出层；已实测，且本函数在终值断言处会自证选对了）。
  double ballFade(WidgetTester tester) => tester
      .widgetList<FadeTransition>(
        find.ancestor(
          of: ballBox(isVoice: true),
          matching: find.byType(FadeTransition),
        ),
      )
      .first
      .opacity
      .value;

  Widget indicator({
    AylaActivitySession? voiceSession = voice,
    AylaActivitySession? liveSession = live,
    ValueChanged<AylaActivitySession>? onOpenSession,
  }) =>
      AylaSessionActivityIndicator(
        voice: voiceSession,
        live: liveSession,
        onOpenSession: onOpenSession,
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  // ======================= 结构 =======================

  testWidgets('无活动态：零渲染（tsx 135 `if (!showVoice && !showLive) return null`）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(
      host(indicator(voiceSession: null, liveSession: null)),
    );
    expect(find.text('›'), findsNothing);
    expect(ballBox(isVoice: true), findsNothing);
    expect(ballBox(isVoice: false), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Positioned && w.child is TweenAnimationBuilder<double>,
      ),
      findsNothing,
    );
  });

  testWidgets('只有一个语音会话：只渲染语音球 + 把手', (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator(liveSession: null)));
    expect(ballBox(isVoice: true), findsOneWidget);
    expect(ballBox(isVoice: false), findsNothing);
    expect(find.text('›'), findsOneWidget);
  });

  // ⚠️ 换参数必须另开一个 `testWidgets`：`previewScope` 的 `Overlay(initialEntries:)`
  // 只在**首次创建**生效，同一用例里第二次 `pumpWidget` 不会把新 child 传进 overlay
  // （`13-工作进度与待办.md` §6.19 已记录，本轮实测再次踩到）。
  testWidgets('只有直播会话：只渲染直播球 + 把手', (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator(voiceSession: null)));
    expect(ballBox(isVoice: true), findsNothing);
    expect(ballBox(isVoice: false), findsOneWidget);
    expect(find.text('›'), findsOneWidget);
  });

  testWidgets('结构顺序：语音球 → 直播球 → 把手（tsx 144–178 的 JSX 顺序）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final double voiceLeft = tester.getRect(ballBox(isVoice: true)).left;
    final double liveLeft = tester.getRect(ballBox(isVoice: false)).left;
    final double toggleLeft = tester.getRect(toggleBox()).left;
    expect(voiceLeft, lessThan(liveLeft));
    expect(liveLeft, lessThan(toggleLeft));
    // gap = var(--sp-2) = 8（.session-activity-group）
    expect(
      tester.getRect(ballBox(isVoice: false)).left -
          tester.getRect(ballBox(isVoice: true)).right,
      AylaSessionActivityIndicator.gap,
    );
    expect(
      tester.getRect(toggleBox()).left -
          tester.getRect(ballBox(isVoice: false)).right,
      AylaSessionActivityIndicator.gap,
    );
  });

  // ======================= 尺寸与几何 =======================

  testWidgets('关键尺寸：球 44×44（圆）、把手 28×44', (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    expect(tester.getSize(ballBox(isVoice: true)), const Size(44, 44));
    expect(tester.getSize(toggleBox()), const Size(28, 44));
  });

  testWidgets('宽屏几何：Positioned right 24 / top 80（shell.css 461–462）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final Positioned pos = groupPositioned(tester);
    expect(pos.right, 24);
    expect(pos.top, 80);
    expect(pos.left, isNull); // web 只给 right/top
    // 展开态：把手右缘贴 right 偏移处（1000 - 24），未发生收起位移
    expect(tester.getRect(toggleBox()).right, 1000 - 24);
  });

  testWidgets('窄屏几何：right 16 / top calc(56 + safe-top + 48)（shell.css 652–655）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(375, 700));
    // safe-area-inset-top = 24 → 56 + 24 + 48 = 128
    await tester.pumpWidget(
      host(indicator(), viewport: const Size(375, 700), padding: const EdgeInsets.only(top: 24)),
    );
    final Positioned pos = groupPositioned(tester);
    expect(pos.right, 16);
    expect(pos.top, 128);
    expect(tester.getRect(toggleBox()).right, 375 - 16);
  });

  testWidgets('窄屏断点 768：走窄屏（web `max-width: 768px`）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(768, 700));
    await tester.pumpWidget(host(indicator(), viewport: const Size(768, 700)));
    expect(groupPositioned(tester).top, 56 + 48);
    expect(groupPositioned(tester).right, 16);
  });

  testWidgets('窄屏断点 769：走宽屏（web 只在 ≤768 命中）', (WidgetTester tester) async {
    setViewport(tester, const Size(769, 700));
    await tester.pumpWidget(host(indicator(), viewport: const Size(769, 700)));
    expect(groupPositioned(tester).top, 80);
    expect(groupPositioned(tester).right, 24);
  });

  // ======================= 球外观 =======================

  testWidgets('球配色：语音 grape-700 字 + sakura-100 底；直播 indigo-700 + ice-300',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    Finder iconOf(Finder ball) => find.descendant(of: ball, matching: find.byType(AylaIcon));
    expect(
      tester.widget<AylaIcon>(iconOf(ballBox(isVoice: true))).color,
      AylaColors.grape700,
    );
    expect(
      tester.widget<AylaIcon>(iconOf(ballBox(isVoice: false))).color,
      AylaColors.indigo700,
    );
    // tsx 152 / 163：`<IconMic width={20} height={20} />`
    expect(tester.widget<AylaIcon>(iconOf(ballBox(isVoice: true))).size, 20);
    expect(tester.widget<AylaIcon>(iconOf(ballBox(isVoice: false))).size, 20);
  });

  testWidgets('球的 1px 亮边 + 静态卡影；球**不带**背板模糊、把手**保留** blur18（用户 2026-09-21 拍板）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    final BoxDecoration voiceDecoration =
        tester.widget<DecoratedBox>(ballBox(isVoice: true)).decoration
            as BoxDecoration;
    expect(voiceDecoration.border, isNotNull);
    expect(voiceDecoration.border!.top.color, AylaColors.glassBorder);

    // 球的底色不透明（sakura-100 / ice-300）⇒ CSS 的 blur(18) 视觉恒为零 → 不加
    expect(
      find.descendant(
        of: ballBox(isVoice: true),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    // 把手是 .78 半透明玻璃 ⇒ 必须保留 BackdropFilter（全组件只有这一处离屏模糊）
    expect(
      find.descendant(
        of: find.byType(AylaSessionActivityIndicator),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: toggleBox(), matching: find.byType(BackdropFilter)),
      findsNothing, // 模糊层是把手面的**兄弟**（Stack），不是它的后代
    );
  });

  testWidgets('把手图标：`›` 16px/w500/line-height 1（shell.css 556–562）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final TextStyle style = glyphStyleHost(tester).style;
    expect(style.fontSize, 16);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.height, 1);
    expect(style.color, AylaColors.textSecondary);
    // base.css 333–335 `button { font-family: inherit }` ⇒ 继承 body 的 --font-body
    expect(style.fontFamily, AylaFonts.body);
  });

  // ======================= 交互：收起 / 展开 =======================

  testWidgets('点把手收起：组位移 24、球位移 64 + 淡隐、图标转 180°、aria 翻转',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    expect(hasTranslateX(tester, 24), isFalse);

    await tester.tap(toggleBox());
    await settle(tester);

    // 组右移 24 ⇒ 把手右缘正好贴住屏幕右缘（web 注释：把手完整贴住屏幕右缘）
    expect(hasTranslateX(tester, 24), isTrue);
    expect(tester.getRect(toggleBox()).right, 1000);
    // 球滑出 64px 并淡隐（活值：收起到位后为 0）
    expect(hasTranslateX(tester, 64), isTrue);
    expect(ballFade(tester), 0.0);
    // 图标 rotate(180deg)（shell.css 565–567）
    expect(
      tester
          .widgetList<RotationTransition>(find.byType(RotationTransition))
          .any((RotationTransition w) => (w.turns.value - 0.5).abs() < 0.001),
      isTrue,
    );

    await tester.tap(toggleBox());
    await settle(tester);
    expect(hasTranslateX(tester, 24), isFalse);
    expect(tester.getRect(toggleBox()).right, 1000 - 24);
  });

  testWidgets('收起是**动画不是跳变**：组位移 / 球自身位移 / 球淡出 三者都要有中间帧',
      (WidgetTester tester) async {
    // 本用例锁的是一个真实事故（用户 2026-09-21 实报「收起时球是瞬间消失的」）：
    // 早前把 `ExcludeFocus/ExcludeSemantics/IgnorePointer` 写成「collapsed 时才包一层」，
    // 根 widget 类型一变 ⇒ Flutter 重建整棵子树 ⇒ `TweenAnimationBuilder` 在 initState
    // 里把 begin 设成 end（立即到位）⇒ 球**没有**滑出/淡隐动画（组位移不受影响，所以只看终值
    // 的断言全绿）。⇒ 这条测试量的是**中间帧**（skill：动画类问题量幅度，不只看终值）。
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final double baseBallLeft = tester.getRect(ballBox(isVoice: true)).left;
    final double baseToggleRight = tester.getRect(toggleBox()).right;
    expect(ballFade(tester), 1.0);

    await tester.tap(toggleBox());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 200ms 动画的中点

    final double groupShift =
        tester.getRect(toggleBox()).right - baseToggleRight;
    // 球自身的位移要从「组位移」里剥离出来（球 left = 起点 + 组位移 + 自身位移）
    final double ballOwnShift =
        tester.getRect(ballBox(isVoice: true)).left - baseBallLeft - groupShift;
    expect(groupShift, greaterThan(0), reason: '组位移（shell.css 470，200ms）要有中间帧');
    expect(groupShift, lessThan(24));
    expect(ballOwnShift, greaterThan(0),
        reason: '球自身 translateX(64px) 要有中间帧（曾被子树重建吃掉 → 直接跳到 64）');
    expect(ballOwnShift, lessThan(64));
    expect(ballFade(tester), lessThan(1.0), reason: '球淡出要有中间帧（不能瞬间到 0）');
    expect(ballFade(tester), greaterThan(0.0));
    // 把手图标 180° 旋转（shell.css 556–567，200ms --ease-out）同样要有中间帧
    final double turns = tester
        .widget<RotationTransition>(find.byType(RotationTransition))
        .turns
        .value;
    expect(turns, greaterThan(0.0));
    expect(turns, lessThan(0.5));

    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(toggleBox()).right, 1000);
    expect(ballFade(tester), 0.0);
    expect(
      tester
          .widget<RotationTransition>(find.byType(RotationTransition))
          .turns
          .value,
      0.5,
    );
  });

  testWidgets('展开：transform 150ms、opacity 200ms（shell.css 495–496 基础规则，与收起不同）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final double baseBallLeft = tester.getRect(ballBox(isVoice: true)).left;
    final double baseToggleRight = tester.getRect(toggleBox()).right;

    await tester.tap(toggleBox());
    await settle(tester);
    expect(ballFade(tester), 0.0);

    await tester.tap(toggleBox());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160)); // > 150ms 但 < 200ms

    final double groupShift =
        tester.getRect(toggleBox()).right - baseToggleRight;
    final double ballOwnShift =
        tester.getRect(ballBox(isVoice: true)).left - baseBallLeft - groupShift;
    expect(ballOwnShift, closeTo(0, 0.5),
        reason: '展开方向的 transform 是 **150ms**（基础规则）⇒ 160ms 时位移已回位');
    expect(ballFade(tester), lessThan(1.0),
        reason: 'opacity 两个方向都是 200ms ⇒ 160ms 时尚未走完');

    await tester.pump(const Duration(milliseconds: 100));
    expect(ballFade(tester), 1.0);
    expect(tester.getRect(ballBox(isVoice: true)).left, baseBallLeft);
  });

  testWidgets('收起态的球不可点、不进语义、不在 tab 序列（web pointer-events:none + visibility:hidden）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator(voiceSession: null)));
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pump();
    // 非空守卫：语义树读不到时必须**响亮失败**，否则下面的「不含…」会变成空断言（假通过）。
    expect(semanticsLabels(tester), isNotEmpty, reason: '语义树观测口径失效');
    expect(semanticsLabels(tester), contains('返回直播间'));

    await tester.tap(toggleBox());
    await settle(tester);

    expect(
      semanticsLabels(tester),
      isNot(contains('返回直播间')),
      reason: '收起态球应被 ExcludeSemantics 排除（真实语义树口径）',
    );
    expect(semanticsLabels(tester), contains('展开媒体控制'));
    expect(
      tester
          .widgetList<IgnorePointer>(find.byType(IgnorePointer))
          .any((IgnorePointer w) => w.ignoring),
      isTrue,
      reason: '收起态球应被 IgnorePointer 挡住',
    );
    expect(
      tester
          .widgetList<ExcludeFocus>(find.byType(ExcludeFocus))
          .any((ExcludeFocus w) => w.excluding),
      isTrue,
      reason: '收起态球不应在 tab 序列里',
    );
    handle.dispose();
  });

  testWidgets('把手语义：label 随状态切换 + aria-expanded（tsx 174–175）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator(voiceSession: null)));
    final SemanticsHandle handle = tester.ensureSemantics();

    SemanticsNode node = tester.getSemantics(togglePressScale());
    expect(node.label, '收起媒体控制');
    // `aria-expanded` → SemanticsFlag.hasExpandedState + isExpanded
    // （本 SDK 版本走 tristate 的 `flagsCollection`；`toBoolOrNull()` 保留"未设置"语义）
    expect(node.flagsCollection.isExpanded.toBoolOrNull(), isNotNull);
    expect(node.flagsCollection.isExpanded.toBoolOrNull(), isTrue);

    await tester.tap(toggleBox());
    await settle(tester);
    node = tester.getSemantics(togglePressScale());
    expect(node.label, '展开媒体控制');
    expect(node.flagsCollection.isExpanded.toBoolOrNull(), isFalse);
    handle.dispose();
  });

  testWidgets('点球：回传对应会话（等价 web navigate(sourceRoute)）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final List<AylaActivitySession> opened = <AylaActivitySession>[];
    await tester.pumpWidget(host(indicator(onOpenSession: opened.add)));

    await tester.tap(ballBox(isVoice: true));
    await settle(tester);
    await tester.tap(ballBox(isVoice: false));
    await settle(tester);
    expect(opened.map((AylaActivitySession s) => s.sessionId), <String>['5', '9']);
    expect(opened.first.sourceRoute, '/voice/5');
    expect(opened.last.sourceRoute, '/live/start/9');
  });

  // ======================= 交互：拖动 =======================

  testWidgets('拖动位移 < 5px：整组不移动，点击仍正常收起（tsx 107 / 125–132）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 4));
    await gesture.up();
    await settle(tester);
    expect(groupPositioned(tester).top, 80, reason: '未超阈值 → 不写成内联 top');

    // 同一次 down/up 的 tap 未被拖动抑制 ⇒ 正常收起
    await tester.tap(toggleBox());
    await settle(tester);
    expect(hasTranslateX(tester, 24), isTrue);
  });

  testWidgets('拖动位移超阈值：top = 起点 + 位移，且随后的合成 click 被抑制',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    // 10px：已超 5px 阈值（判为拖动），但仍在 tap 的 kTouchSlop(18) 内 ⇒ Flutter 侧仍会
    // 产生一次 tap —— 正是 web `suppressClickRef` 要吃掉的那种「合成 click」。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 10));
    await settle(tester);
    expect(groupPositioned(tester).top, 90);
    await gesture.up();
    await settle(tester);

    expect(hasTranslateX(tester, 24), isFalse, reason: '拖动后的 click 必须被抑制');
  });

  testWidgets('拖动长距离（超出 tap slop）：top 实时更新；下一次真实点击照常收起',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 60));
    await settle(tester);
    expect(groupPositioned(tester).top, 140);
    await gesture.up();
    await settle(tester);

    // 这次拖动本身没有产生 tap（drag 赢了竞技场）⇒ 抑制标记在下一次 down 时清零，
    // 行为与 web 一致（web 的合成 click 已在 pointerup 那一刻被消费掉）。
    await tester.tap(toggleBox());
    await settle(tester);
    expect(hasTranslateX(tester, 24), isTrue);
  });

  testWidgets('拖动 clamp：上边界 8 / 下边界 视口高-44-8（tsx 109–110）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -400));
    await settle(tester);
    expect(groupPositioned(tester).top, 8);
    await gesture.up();
    await settle(tester);

    gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 2000));
    await settle(tester);
    expect(groupPositioned(tester).top, 700 - 44 - 8);
    await gesture.up();
    await settle(tester);
  });

  testWidgets('鼠标非主键不触发拖动（tsx 87 `pointerType === mouse && button !== 0`）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.moveBy(const Offset(0, 80));
    await settle(tester);
    expect(groupPositioned(tester).top, 80, reason: '右键拖动不应移动整组');
    await gesture.up();
    await settle(tester);
  });

  testWidgets('窄屏收起位移 = 16（shell.css 658–660）', (WidgetTester tester) async {
    setViewport(tester, const Size(375, 700));
    await tester.pumpWidget(host(indicator(), viewport: const Size(375, 700)));
    await tester.tap(toggleBox());
    await settle(tester);
    expect(hasTranslateX(tester, 16), isTrue);
    expect(tester.getRect(toggleBox()).right, 375, reason: '窄屏 right 16 ⇒ 贴边位移也是 16');
  });

  // ======================= 易错点：hover / focus / reduced-motion =======================

  testWidgets('球 hover：scale(1.08) 且**没有** 1.02/.98（球不在 auroraqua 按钮组）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(ballBox(isVoice: true)));
    await settle(tester);

    expect(hasScale(tester, 1.08), isTrue);
    expect(hasScale(tester, 1.02), isFalse);
    expect(hasScale(tester, 0.98), isFalse);
  });

  testWidgets('把手 hover：底色变**透明**（`--glass-bg-hover` 未定义 ⇒ 实渲染为初始值）+ 字色转主色',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    expect(
      (tester.widget<AnimatedContainer>(toggleBox()).decoration as BoxDecoration)
          .color,
      AylaColors.glassBgStrong,
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(toggleBox()));
    await settle(tester);

    expect(
      (tester.widget<AnimatedContainer>(toggleBox()).decoration as BoxDecoration)
          .color,
      AylaColors.glassBgStrong.withValues(alpha: 0),
      reason: 'web 的 background 简写整体回落初始值 = 透明（1px 亮边 / blur / 阴影保留）',
    );
    expect(
      glyphStyleHost(tester).style.color,
      AylaColors.textPrimary,
    );
  });

  testWidgets('reduced-motion：收起立即到位（shell.css 569–575 `transition: none`）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(
      host(indicator(), disableAnimations: true),
    );
    await tester.tap(toggleBox());
    await tester.pump(); // 不带时长：只重建，不推进动画
    expect(hasTranslateX(tester, 24), isTrue);
    expect(tester.getRect(toggleBox()).right, 1000);
  });

  testWidgets('reduced-motion 的关闭名单**不含**把手本体：底色/字色过渡仍 200ms',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator(), disableAnimations: true));

    // 组位移（`.session-activity-group` 在名单内）→ 归零
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byWidgetPredicate(
              (Widget w) => w is TweenAnimationBuilder<double> && w.child is Row,
            ),
          )
          .duration,
      Duration.zero,
    );
    // 图标旋转（`.session-activity-toggle-icon` 在名单内）→ 归零
    expect(
      tester
          .widget<AnimatedRotation>(
            find.ancestor(
              of: find.text('›'),
              matching: find.byType(AnimatedRotation),
            ),
          )
          .duration,
      Duration.zero,
    );
    // 球（`.session-activity-ball` 在名单内）→ 归零
    expect(
      tester
          .widget<AnimatedScale>(
            find.ancestor(
              of: ballBox(isVoice: true),
              matching: find.byType(AnimatedScale),
            ).last,
          )
          .duration,
      Duration.zero,
    );
    // 把手本体**不在**名单内（auroraqua 的 reduced-motion 段只清 translate/scale）
    expect(
      tester.widget<AnimatedContainer>(toggleBox()).duration,
      AylaDurations.button,
    );
    expect(glyphStyleHost(tester).duration, AylaDurations.button);
  });

  testWidgets('拖把手不滚动页面（web `.session-activity-toggle { touch-action: none }` 的等价实现）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(1000, 700)),
              child: SizedBox.fromSize(
                size: const Size(1000, 700),
                child: Stack(
                  children: <Widget>[
                    // 页面主滚动容器：把手的拖动必须赢下竞技场，页面不得跟着滚
                    ListView.builder(
                      controller: controller,
                      itemCount: 40,
                      itemBuilder: (BuildContext context, int i) =>
                          SizedBox(height: 40, child: Text('条目 $i')),
                    ),
                    indicator(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 触摸设备（`touch-action` 只在触摸/触控笔下有语义）
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(toggleBox()));
    await gesture.moveBy(const Offset(0, 120));
    await settle(tester);
    expect(groupPositioned(tester).top, 200);
    expect(controller.offset, 0, reason: '拖把手期间页面不得滚动');
    await gesture.up();
    await settle(tester);
  });

  // ======================= 键盘焦点（:focus-visible） =======================
  testWidgets('球焦点态与 hover 同款：scale(1.08)（shell.css 513–517 的 :focus-visible）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    expect(hasScale(tester, 1.08), isFalse);

    // 焦点节点的取法：`Focus.of(Text 的 element)` = AylaPressScale 内部的（可聚焦）节点
    Focus.of(tester.element(find.text('›'))).requestFocus();
    await settle(tester);
    expect(hasScale(tester, 1.02), isFalse, reason: '把手在按钮组内 → 1.02 属 AylaPressScale');

    // 球的节点（球内 icon 的最近祖先 Focus）
    Focus.of(
      tester.element(
        find.descendant(
          of: ballBox(isVoice: true),
          matching: find.byType(AylaIcon),
        ),
      ),
    ).requestFocus();
    await settle(tester);
    expect(hasScale(tester, 1.08), isTrue);
  });

  testWidgets('把手 :focus-visible：底色转透明 + 字色转主色（与 hover 同一组规则）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    expect(
      (tester.widget<AnimatedContainer>(toggleBox()).decoration as BoxDecoration)
          .color,
      AylaColors.glassBgStrong,
    );

    Focus.of(tester.element(find.text('›'))).requestFocus();
    await settle(tester);

    expect(
      (tester.widget<AnimatedContainer>(toggleBox()).decoration as BoxDecoration)
          .color,
      AylaColors.glassBgStrong.withValues(alpha: 0),
    );
    expect(glyphStyleHost(tester).style.color, AylaColors.textPrimary);
  });

  testWidgets('拖动后 top 是绝对像素并保持：后续重建（收起/展开）不漂移（web 内联 style.top 同语义）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(indicator()));
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(toggleBox()),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 100));
    await settle(tester);
    await gesture.up();
    await settle(tester);
    expect(groupPositioned(tester).top, 180);

    await tester.tap(toggleBox()); // 收起
    await settle(tester);
    expect(groupPositioned(tester).top, 180);
    await tester.tap(toggleBox()); // 展开
    await settle(tester);
    expect(groupPositioned(tester).top, 180);
    expect(groupPositioned(tester).right, 24);
  });
}
