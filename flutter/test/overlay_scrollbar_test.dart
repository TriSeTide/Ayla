/// B6-4：全局覆盖层滚动条定向测试（13 号 §6.4 登记的唯一待补项）。
///
/// 逐条对照 `Ayla/web/src/components/overlay/OverlayScrollbar.tsx`（311 行）+
/// `Ayla/web/src/styles/base.css`（385–421）：
/// · 常量与视觉（tsx 31–42 / base.css 389–421）：THICKNESS 4 / OFFSET 2 / PAD 3 /
///   MIN_VERT 28 / MIN_HORZ 48 / HIDE_DELAY 600ms / 过渡 180ms / 窄屏 768 /
///   圆角 THICKNESS/2+PAD / 底色 rgba(126,149,189,.38) → hover .55；
/// · 度量（tsx 168–194）：thumb 长 = max(MIN, round(track²/scrollSize))、位置 = 比例映射 +
///   四舍五入、竖条距容器右缘 OFFSET、横条贴容器底、两端夹紧；
/// · 显隐（tsx 200–223）：滚动即时显示、180ms 过渡（量 FadeTransition **活值**）、
///   停滚 600ms 淡出、悬停/拖拽期间不淡出、淡出后不可点（`.is-visible` 才 pointer-events: auto）；
/// · 拖拽换算（tsx 110–152）：`top = 抓取时的条起点 + 指针位移`，两端夹紧；
/// · 机制差异（tsx 89–94 / 229–234）：容器失效后清掉 thumb、其它容器滚动时统一重算
///   （Flutter 没有 document 级 scroll，等价物是「收到任意滚动通知即重算其余活跃容器」）；
/// · **反向列表**（`reverse: true` ⇒ `axisDirection.up`/`left`）：Flutter 的 `pixels` 0 点在
///   **视觉末端**（底/右），而 web 的 `scrollTop`/`scrollLeft` 恒以**视觉起点**为 0
///   （tsx 172/186 直接拿它算位置）⇒ 本件必须按 `axisDirection` 归一：`pixels=0` ⇒ 条贴视觉末端、
///   `pixels=max` ⇒ 条贴视觉起点；拖拽反算同步镜像（tsx 133/139 的正比映射取补）。
///   这条差异源自 `AylaMessageList` 的 `ListView.builder(reverse: true)`（message_list.dart:1012）。
/// · 其余：窄屏 ≤768 完全不显示（tsx 42/64 + base.css 412–415）、`enabled: false` 透传、
///   内容不可滚不出条（tsx 161–166）、reduced-motion 无过渡（base.css 417–419）、
///   零占位（不挤占内容宽度）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/shell/overlay_scrollbar.dart';

void main() {
  /// 舞台尺寸（= 库内样张 `_OverlayScrollbarDemo`：420×320）。
  const Size stage = Size(420, 320);

  /// 钉死测试视口（默认宽屏 1200×900 ⇒ >768，组件参与计算）。
  void pinView(WidgetTester tester, [Size size = const Size(1200, 900)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 宿主：舞台左上角 + `previewTheme` 三件套（材质/文字/极光语境）。
  Widget shell(
    Widget child, {
    bool enabled = true,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: stage.width,
                height: stage.height,
                child: AylaOverlayScrollbar(
                  enabled: enabled,
                  child: ScrollConfiguration(
                    // 关掉桌面端自动原生条（web 侧由 base.css 372–383 全局隐藏）
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 定长 item 的滚动内容 ⇒ scrollHeight / maxScrollExtent 可精确推算。
  Widget list({
    required ScrollController controller,
    Axis axis = Axis.vertical,
    int items = 40,
    double itemExtent = 50,
    bool reverse = false,
  }) {
    return ListView.builder(
      controller: controller,
      scrollDirection: axis,
      // `reverse: true` 是 AylaMessageList 的锚定手段（message_list.dart:1012）：
      // 让 `pixels` 的 0 点落在**视觉末端**，本组用例锁这条语义差的归一。
      reverse: reverse,
      itemExtent: itemExtent,
      itemCount: items,
      padding: EdgeInsets.zero,
      itemBuilder: (BuildContext context, int i) => Text('第 $i 项'),
    );
  }

  // ---- 定位：thumb = Positioned 槽里的 AnimatedOpacity（件内唯一）----
  Finder thumb() => find.descendant(
    of: find.byType(AylaOverlayScrollbar),
    matching: find.byType(AnimatedOpacity),
  );

  /// 视觉条 = thumb 的 content-box（web `background-clip: content-box`）。
  Finder bar() => find.descendant(of: thumb(), matching: find.byType(DecoratedBox));

  /// 多个容器同时出条时的条矩形集合（嵌套滚动舞台用）。
  List<Rect> barRects(WidgetTester tester) {
    final Finder finder = bar();
    return <Rect>[
      for (int i = 0; i < finder.evaluate().length; i++)
        tester.getRect(finder.at(i)),
    ];
  }

  /// 是否存在与期望位置相符的条（±0.5px）。
  bool hasBar(WidgetTester tester, Offset expectedTopLeft) {
    return barRects(tester).any(
      (Rect r) =>
          (r.top - expectedTopLeft.dy).abs() < 0.5 &&
          (r.left - expectedTopLeft.dx).abs() < 0.5,
    );
  }

  Rect hostRect(WidgetTester tester) =>
      tester.getRect(find.byType(AylaOverlayScrollbar));

  /// 条底色（静息 .38 / hover .55）。
  Color barColor(WidgetTester tester) {
    final DecoratedBox box = tester.widget<DecoratedBox>(bar());
    return (box.decoration as BoxDecoration).color!;
  }

  /// 目标透明度（`AnimatedOpacity.opacity` 是**目标值**，动画中途读它也永远是终点）。
  double targetOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(thumb()).opacity;

  /// 活值：必须读 `FadeTransition.opacity.value`（skill「验证动画要量活值」）。
  double liveOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.descendant(of: thumb(), matching: find.byType(FadeTransition)),
      )
      .opacity
      .value;

  /// web tsx 170 / 183：thumb 长 = max(MIN, round(track² / scrollSize))。
  double expectedLen({
    required double track,
    required double scrollSize,
    bool vertical = true,
  }) {
    final double min = vertical
        ? AylaOverlayScrollbar.minVert
        : AylaOverlayScrollbar.minHorz;
    return math.max(min, (track * track / scrollSize).roundToDouble());
  }

  // ======================= 常量 =======================

  test('常量逐条对齐 web（tsx 31–42 / base.css 389–421）', () {
    expect(AylaOverlayScrollbar.thickness, 4); // tsx 33
    expect(AylaOverlayScrollbar.offset, 2); // tsx 35
    expect(AylaOverlayScrollbar.pad, 3); // tsx 37
    expect(AylaOverlayScrollbar.minVert, 28); // tsx 39
    expect(AylaOverlayScrollbar.minHorz, 48); // tsx 40
    expect(
      AylaOverlayScrollbar.hideDelay,
      const Duration(milliseconds: 600),
    ); // tsx 31
    expect(
      AylaOverlayScrollbar.fadeDuration,
      const Duration(milliseconds: 180),
    ); // base.css 397
    expect(AylaOverlayScrollbar.narrowBreakpoint, 768); // tsx 42
    expect(AylaOverlayScrollbar.thumbRadius, 5); // base.css 391：THICKNESS/2 + PAD
    expect(AylaOverlayScrollbar.thumbColor, const Color(0x617E95BD)); // rgba(126,149,189,.38)
    expect(AylaOverlayScrollbar.thumbHoverColor, const Color(0x8C7E95BD)); // .55
  });

  // ======================= 结构 / 几何 =======================

  testWidgets('未滚动：不渲染 thumb（web 只在 update/show 里 ensureThumb）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    expect(thumb(), findsNothing);
  });

  testWidgets('滚动出条：竖条几何逐项对齐 web（tsx 168–180）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(840);
    await tester.pump();

    // 自检测试前提：track 320 / scrollSize 2000（40 × 50）
    expect(controller.position.viewportDimension, 320);
    expect(controller.position.maxScrollExtent, 1680);

    final Rect host = hostRect(tester);
    expect(host.size, stage);

    // thumb 长 = max(28, round(320²/2000)) = 51；位置 = round(840/1680 × (320−51)) = 135
    final double len = expectedLen(track: 320, scrollSize: 2000);
    expect(len, 51);
    const double top = 135;

    final Rect box = tester.getRect(thumb());
    final Rect barRect = tester.getRect(bar());

    // 盒 = 视觉条 + 四边 3px 透明命中区（base.css 389–392）
    expect(box.width, closeTo(10, 0.001));
    expect(box.height, closeTo(len + 6, 0.001));
    // left = round(rect.right) − OFFSET − THICKNESS − PAD（tsx 179）
    expect(
      box.left,
      closeTo(host.right - AylaOverlayScrollbar.offset - 4 - 3, 0.001),
    );
    // top = round(rect.top) + top − PAD（tsx 180）
    expect(box.top, closeTo(host.top + top - 3, 0.001));
    // 视觉条 4 × 51，右缘距容器右缘正好 OFFSET = 2
    expect(barRect.left, closeTo(host.left + 414, 0.001));
    expect(barRect.top, closeTo(host.top + 135, 0.001));
    expect(barRect.width, closeTo(4, 0.001));
    expect(barRect.height, closeTo(51, 0.001));
    expect(host.right - barRect.right, closeTo(AylaOverlayScrollbar.offset, 0.001));
    // 圆角 + 静息底色
    final BoxDecoration deco =
        tester.widget<DecoratedBox>(bar()).decoration as BoxDecoration;
    expect((deco.borderRadius! as BorderRadius).topLeft.x, 5);
    expect(deco.color, AylaOverlayScrollbar.thumbColor);
  });

  testWidgets('两端夹紧：顶 ⇒ 条起点 0；底 ⇒ 条底边贴容器底（tsx 172 maxTop 夹紧）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    final Rect host = hostRect(tester);

    // ⚠️ 先滚到中间让条建出来：`jumpTo(0)` 在已处于 0 时是 no-op，不会派发滚动通知
    controller.jumpTo(840);
    await tester.pump();
    controller.jumpTo(0);
    await tester.pump();
    expect(tester.getRect(bar()).top, closeTo(host.top, 0.001));

    controller.jumpTo(1680);
    await tester.pump();
    final Rect barRect = tester.getRect(bar());
    expect(barRect.top, closeTo(host.top + 269, 0.001)); // 320 − 51
    expect(barRect.bottom, closeTo(host.bottom, 0.001)); // 贴底
  });

  testWidgets('零占位：条不参与布局，不挤占内容宽度（tsx 3–8 的核心诉求）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    final Rect before = tester.getRect(find.byType(ListView));
    expect(before.size, stage);

    controller.jumpTo(600);
    await tester.pump();

    expect(tester.getRect(find.byType(ListView)), before);
  });

  testWidgets('横向容器：画底部条（tsx 181–194）', (WidgetTester tester) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      shell(
        list(
          controller: controller,
          axis: Axis.horizontal,
          items: 40,
          itemExtent: 80,
        ),
      ),
    );
    await tester.pump();

    controller.jumpTo(1390);
    await tester.pump();

    // 自检前提：track 420 / scrollSize 3200 ⇒ 长 = max(48, round(420²/3200)) = 55
    expect(controller.position.viewportDimension, 420);
    expect(controller.position.maxScrollExtent, 2780);
    final double len = expectedLen(track: 420, scrollSize: 3200, vertical: false);
    expect(len, 55);
    const double left = 183; // round(1390/2780 × (420−55))

    final Rect host = hostRect(tester);
    final Rect box = tester.getRect(thumb());
    final Rect barRect = tester.getRect(bar());
    // 盒宽 = 55 + 6、盒高 = 4 + 6；top = round(rect.bottom) − OFFSET − THICKNESS − PAD
    expect(box.width, closeTo(len + 6, 0.001));
    expect(box.height, closeTo(10, 0.001));
    expect(box.left, closeTo(host.left + left - 3, 0.001));
    expect(box.top, closeTo(host.bottom - 2 - 4 - 3, 0.001));
    expect(barRect.left, closeTo(host.left + left, 0.001));
    expect(barRect.top, closeTo(host.top + 314, 0.001));
    expect(barRect.width, closeTo(55, 0.001));
    expect(barRect.height, closeTo(4, 0.001));
    expect(host.bottom - barRect.bottom, closeTo(AylaOverlayScrollbar.offset, 0.001));
  });

  // ======================= 显隐 =======================

  testWidgets('显隐：滚动即时显示，停 600ms 后淡出（tsx 200–223 + base.css 397–401）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump(); // setState(visible = true)
    expect(targetOpacity(tester), 1);
    // ⚠️ 首次出现是「弹入」不是淡入：条此前不在树上（`rect == null` 不渲染）⇒ AnimatedOpacity
    //    首次构建即终值。web 同理（thumb 元素 createElement + 同帧 add('is-visible')，
    //    没有前一次计算样式 ⇒ 不产生 transition）。淡入只在**后续**显示时成立（见文末）。
    expect(liveOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 400)); // t = 400ms < 600ms
    expect(liveOpacity(tester), closeTo(1, 0.001)); // 停滚 600ms 内仍可见

    await tester.pump(const Duration(milliseconds: 300)); // t = 700ms ⇒ 计时器已触发淡出
    expect(targetOpacity(tester), 0);
    expect(liveOpacity(tester), greaterThan(0)); // 仍在过渡中（不是瞬变）

    await tester.pump(const Duration(milliseconds: 300)); // 过渡走完
    expect(liveOpacity(tester), closeTo(0, 0.001));

    // 淡出后不可点（只有 `.is-visible` 才 pointer-events: auto）
    final Iterable<IgnorePointer> ignoring = tester.widgetList<IgnorePointer>(
      find.ancestor(of: thumb(), matching: find.byType(IgnorePointer)),
    );
    expect(ignoring.any((IgnorePointer w) => w.ignoring), isTrue);
    // 条不消失，只是 opacity 0（web 同）
    expect(thumb(), findsOneWidget);

    // 二次显示：元素已在树上 ⇒ 这一次是**真淡入**（180ms 过渡，base.css 397）
    controller.jumpTo(600);
    await tester.pump();
    expect(targetOpacity(tester), 1);
    expect(liveOpacity(tester), 0); // 从 0 开始
    await tester.pump(const Duration(milliseconds: 180));
    expect(liveOpacity(tester), closeTo(1, 0.001));
  });

  testWidgets('悬停期间不淡出；移出后按 600ms 重新计时（tsx 210–223 / 240–261）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(liveOpacity(tester), closeTo(1, 0.001));

    final Rect host = hostRect(tester);
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    // 先落在舞台外（不构成悬停），再移进容器
    await mouse.addPointer(location: host.topLeft + const Offset(500, 400));
    await mouse.moveTo(host.topLeft + const Offset(20, 20));
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 1500)); // 远超 HIDE_DELAY
    expect(liveOpacity(tester), closeTo(1, 0.001)); // 悬停保持可见

    await mouse.moveTo(host.topLeft + const Offset(500, 400)); // 移出
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700)); // HIDE_DELAY 触发
    await tester.pump(const Duration(milliseconds: 300)); // 180ms 过渡走完
    expect(liveOpacity(tester), closeTo(0, 0.001));

    await mouse.removePointer();
  });

  testWidgets('thumb 悬停：底色升级到 .55（base.css 403–405）', (WidgetTester tester) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(840);
    await tester.pump();
    expect(barColor(tester), AylaOverlayScrollbar.thumbColor);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(bar()));
    await tester.pump();
    expect(barColor(tester), AylaOverlayScrollbar.thumbHoverColor);

    // 移出 thumb（仍在容器内）⇒ 回到静息底色
    await mouse.moveTo(hostRect(tester).topLeft + const Offset(20, 20));
    await tester.pump();
    expect(barColor(tester), AylaOverlayScrollbar.thumbColor);

    await mouse.removePointer();
  });

  testWidgets('reduced-motion：无过渡（base.css 417–419）', (WidgetTester tester) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      shell(list(controller: controller), disableAnimations: true),
    );
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(thumb()).duration,
      Duration.zero, // base.css 417–419：reduced-motion 无过渡
    );
    await tester.pump(const Duration(milliseconds: 700)); // 淡出计时器触发
    await tester.pump(const Duration(milliseconds: 16)); // 一帧即到终值（不是 180ms）
    expect(liveOpacity(tester), closeTo(0, 0.001));
  });

  // ======================= 拖拽 =======================

  /// 抓起条中心（thumb 的 pan 识别器在竞技场里无竞争者 ⇒ 关闭即被接受，
  /// `onPanStart` 拿到的是**按下点**，鼠标 1px slop 不会被吃掉位移）。
  Future<TestGesture> grabThumb(WidgetTester tester) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(bar()),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    return gesture;
  }

  testWidgets('拖拽换算：条起点 + 指针位移（tsx 127–133 / 138）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(840); // 条起点 135
    await tester.pump();

    final TestGesture gesture = await grabThumb(tester);
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();

    // web：top = 抓取时的条起点(135) + 指针位移(60) = 195 ⇒
    // scrollTop = 195/269 × 1680 = 1217.8438…
    expect(controller.offset, closeTo(1217.8438661710037, 0.01));
    expect(
      tester.getRect(bar()).top,
      closeTo(hostRect(tester).top + 195, 0.001),
    );
    await gesture.up();
    await tester.pump();
  });

  testWidgets('拖拽两端夹紧：拖到顶 ⇒ 0；拖到底 ⇒ maxScrollExtent（tsx 132 夹紧）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(840);
    await tester.pump();

    TestGesture gesture = await grabThumb(tester);
    await gesture.moveBy(const Offset(0, -500));
    await tester.pump();
    expect(controller.offset, 0);
    await gesture.up();
    await tester.pump();

    controller.jumpTo(840);
    await tester.pump();
    gesture = await grabThumb(tester);
    await gesture.moveBy(const Offset(0, 500));
    await tester.pump();
    expect(controller.offset, 1680);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('拖拽期间不淡出；抬手后按悬停语义重新计时（tsx 143–149）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(840);
    await tester.pump();

    final TestGesture gesture = await grabThumb(tester);
    await tester.pump(const Duration(milliseconds: 900)); // 超过 HIDE_DELAY
    expect(liveOpacity(tester), closeTo(1, 0.001));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700)); // HIDE_DELAY 触发
    await tester.pump(const Duration(milliseconds: 300)); // 过渡走完
    expect(liveOpacity(tester), closeTo(0, 0.001));
  });

  // ======================= 窄屏 / 停用 / 不可滚 =======================

  testWidgets('窄屏 768：完全不显示、不参与计算（tsx 42/64 + base.css 412–415）', (
    WidgetTester tester,
  ) async {
    pinView(tester, const Size(768, 900)); // 断点值是 ≤768
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    expect(controller.offset, 400); // 内容照常滚动
    expect(thumb(), findsNothing); // 但条完全不出现
  });

  testWidgets('断点外 769：照常显示（边界另一侧）', (WidgetTester tester) async {
    pinView(tester, const Size(769, 900));
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller)));
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    expect(thumb(), findsOneWidget);
  });

  testWidgets('enabled: false：完全透传（不监听、不绘制，内容照常滚）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shell(list(controller: controller), enabled: false));
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    expect(controller.offset, 400);
    expect(thumb(), findsNothing);
  });

  testWidgets('内容变短后不再可滚 ⇒ 条收起（tsx 161–166 的 display:none 分支）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController controller = ScrollController();
    final ValueNotifier<int> items = ValueNotifier<int>(40);
    addTearDown(controller.dispose);
    addTearDown(items.dispose);

    // ⚠️ 不能二次 `pumpWidget` 换参数：`previewScope` 的 `Overlay(initialEntries:)`
    //    只在首次创建生效（skill 既有结论）⇒ 内容变更必须走树内 notifier。
    await tester.pumpWidget(
      shell(
        ValueListenableBuilder<int>(
          valueListenable: items,
          builder: (BuildContext context, int count, Widget? _) =>
              list(controller: controller, items: count),
        ),
      ),
    );
    await tester.pump();

    controller.jumpTo(400);
    await tester.pump();
    expect(thumb(), findsOneWidget);

    items.value = 2; // 内容缩到 2 项（100 < 320 ⇒ 不可滚）
    await tester.pump();

    // 内容变短后 drag 会被 physics 拒绝（shouldAcceptUserOffset = false），
    // 直接派发一次滚动通知（与框架内部同一条路径）
    final ScrollPosition position = controller.position;
    position.didStartScroll();
    position.didUpdateScrollPositionBy(0);
    position.didEndScroll();
    await tester.pump();

    expect(controller.position.maxScrollExtent, 0);
    expect(thumb(), findsNothing);
  });

  // ============ 反向列表（`reverse: true` ⇒ axisDirection.up/left）============

  /// web 侧无此分支：`scrollTop`/`scrollLeft` **恒以视觉起点为 0**（tsx 172 / 186 直接拿它
  /// 算位置），所以 OverlayScrollbar.tsx 不需要任何反向处理。Flutter 的 `pixels` 0 点由
  /// `axisDirection` 决定：`up`/`left` ⇒ 0 在视觉末端（底/右）。
  /// 本组用例锁住「归一后与正向列表同义」：`pixels = 0` 条贴视觉末端、
  /// `pixels = max` 条贴视觉起点，且中间位置的首项公式与 web 完全一致。
  group('反向列表（reverse: true / axisDirection.up·left）', () {
    testWidgets('竖向反列表：pixels=0 ⇒ 贴视觉底；pixels=max ⇒ 贴视觉顶（与正向列表对照）',
        (WidgetTester tester) async {
      pinView(tester);
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(shell(list(controller: controller, reverse: true)));
      await tester.pump();

      // 自检测试前提：与正向用例同一套度量（40 × 50 / 视口 320）
      expect(controller.position.viewportDimension, 320);
      expect(controller.position.maxScrollExtent, 1680);
      // 前提：确实是反向方向（`reverse: true` ⇒ up，而非靠 axis 猜测）
      expect(controller.position.axis, Axis.vertical);
      expect(controller.position.axisDirection, AxisDirection.up);

      final Rect host = hostRect(tester);

      // ① 先滚到中间：jumpTo(0) 在已处于 0 时是 no-op，不派发滚动通知 ⇒ 条不会建出来
      controller.jumpTo(840);
      await tester.pump();
      // 首项公式与正向一致：max(28, round(320²/2000)) = 51；
      // 中间位置取补后同样是「已滚一半」⇒ 与正向用例同一落点 135
      final double len = expectedLen(track: 320, scrollSize: 2000);
      expect(len, 51);
      final Rect mid = tester.getRect(bar());
      expect(mid.top, closeTo(host.top + 135, 0.001));
      expect(mid.height, closeTo(51, 0.001));

      // ② pixels = 0 **就是视觉底部**（reverse 的锚定语义）⇒ 条必须贴底
      controller.jumpTo(0);
      await tester.pump();
      expect(controller.position.pixels, 0);
      final Rect atZero = tester.getRect(bar());
      expect(atZero.top, closeTo(host.top + 269, 0.001)); // 320 − 51
      expect(atZero.bottom, closeTo(host.bottom, 0.001)); // 贴视觉底

      // ③ pixels = maxScrollExtent **是视觉顶部** ⇒ 条必须贴顶
      controller.jumpTo(1680);
      await tester.pump();
      expect(controller.position.pixels, 1680);
      final Rect atMax = tester.getRect(bar());
      expect(atMax.top, closeTo(host.top, 0.001)); // 贴视觉顶
      expect(atMax.bottom, closeTo(host.top + 51, 0.001));
      // 镜像不是「同一条停住」：两端位置必须真的相差 269
      expect((atMax.top - atZero.top).abs(), closeTo(269, 0.001));
    });

    // 对照基准 = 正向列表同一组 pixels 的落点（web 语义，tsx 172）：
    // pixels 0 ⇒ 顶 0 · 中点 ⇒ 135 · max ⇒ 底 269。正列表这三条由上文
    // 「滚动出条」「两端夹紧」两条用例锁死，本条把同一组数值搬到反向列表上取补。
    // ⚠️ 两条用例分开跑是刻意的：同一 testWidgets 里二次 pumpWidget 换
    //    `previewScope` 会拿不到新的 ScrollPosition（实测：'not attached'）。
    testWidgets('对照：反向列表的落点 = 正向列表落点的补（0↔269、135 不变）',
        (WidgetTester tester) async {
      pinView(tester);
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(shell(list(controller: controller, reverse: true)));
      await tester.pump();

      final Rect host = hostRect(tester);
      final double max = controller.position.maxScrollExtent;
      expect(max, 1680); // 与正向用例同一套度量

      controller.jumpTo(max / 2); // 先让条建出来（jumpTo(0) 在 0 时是 no-op）
      await tester.pump();
      expect(tester.getRect(bar()).top - host.top, closeTo(135, 0.001));

      controller.jumpTo(0);
      await tester.pump();
      // 正向列表此处是 0（贴顶）；反向列表必须取补 ⇒ 269（贴底）
      expect(tester.getRect(bar()).top - host.top, closeTo(269, 0.001));

      controller.jumpTo(max);
      await tester.pump();
      // 正向列表此处是 269（贴底）；反向列表必须取补 ⇒ 0（贴顶）
      expect(tester.getRect(bar()).top - host.top, closeTo(0, 0.001));
    });

    testWidgets('横向反列表（axisDirection.left）：pixels=0 ⇒ 贴视觉右端；max ⇒ 贴左端',
        (WidgetTester tester) async {
      pinView(tester);
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        shell(
          list(
            controller: controller,
            axis: Axis.horizontal,
            items: 40,
            itemExtent: 80,
            reverse: true,
          ),
        ),
      );
      await tester.pump();

      expect(controller.position.viewportDimension, 420);
      expect(controller.position.maxScrollExtent, 2780);
      expect(controller.position.axis, Axis.horizontal);
      expect(controller.position.axisDirection, AxisDirection.left);

      final Rect host = hostRect(tester);
      final double len = expectedLen(track: 420, scrollSize: 3200, vertical: false);
      expect(len, 55);
      const double maxLeft = 420 - 55; // 365

      controller.jumpTo(1390); // 先让条建出来
      await tester.pump();
      controller.jumpTo(0); // 视觉右端
      await tester.pump();
      final Rect atZero = tester.getRect(bar());
      expect(atZero.left, closeTo(host.left + maxLeft, 0.001));
      expect(atZero.right, closeTo(host.right, 0.001));

      controller.jumpTo(2780); // 视觉左端
      await tester.pump();
      expect(tester.getRect(bar()).left, closeTo(host.left, 0.001));
    });

    testWidgets('拖拽同步镜像：反向列表里条往下拖 ⇒ 内容朝视觉下方（pixels 减小）',
        (WidgetTester tester) async {
      pinView(tester);
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(shell(list(controller: controller, reverse: true)));
      await tester.pump();

      controller.jumpTo(840); // 条起点 135（与正向用例同落点）
      await tester.pump();

      final TestGesture gesture = await grabThumb(tester);
      await gesture.moveBy(const Offset(0, 60)); // 条下移 60 ⇒ 起点 195
      await tester.pump();

      // web tsx 133 的正比映射在反向列表取补：
      // fraction = 195/269 ⇒ pixels = (1 − 195/269) × 1680 = 462.156…
      // ⚠️ 若漏掉镜像，这里会得到 1217.84（= 正向列表同一手势的值）⇒ 拖拽方向与位置相反。
      expect(controller.position.pixels, closeTo(462.1561338289963, 0.01));
      expect(
        tester.getRect(bar()).top,
        closeTo(hostRect(tester).top + 195, 0.001),
      );
      await gesture.up();
      await tester.pump();

      // 拖到视觉顶 ⇒ pixels 归 max（不是 0）
      controller.jumpTo(840);
      await tester.pump();
      final TestGesture up = await grabThumb(tester);
      await up.moveBy(const Offset(0, -500));
      await tester.pump();
      expect(controller.position.pixels, 1680);
      await up.up();
      await tester.pump();
    });
  });

  // ======================= 机制差异（platform semantics）=======================

  testWidgets('滚动时统一重算其余活跃容器（tsx 229–234 的 document scroll 等价）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController outer = ScrollController();
    final ScrollController inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);

    await tester.pumpWidget(
      shell(
        ListView.builder(
          controller: outer,
          itemExtent: 240,
          itemCount: 6,
          padding: EdgeInsets.zero,
          itemBuilder: (BuildContext context, int i) => i == 0
              ? list(controller: inner, items: 16)
              : const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    inner.jumpTo(280); // 内层条：长 72、起点 84
    await tester.pump();
    final Rect host = hostRect(tester);
    const double barLeft = 414; // 视觉条左缘 = 容器右缘 − OFFSET − THICKNESS
    expect(
      hasBar(tester, Offset(host.left + barLeft, host.top + 84)),
      isTrue,
      reason: '实测条：${barRects(tester)}',
    );

    outer.jumpTo(120); // 外层滚动 ⇒ 内层容器在视口里上移 120
    // 跨容器重算排在**帧后**（滚动通知早于本帧 layout）⇒ 需要「帧后重算 + 再一帧重绘」
    await tester.pump();
    await tester.pump();
    expect(
      hasBar(tester, Offset(host.left + barLeft, host.top + 84 - 120)),
      isTrue,
      reason: '实测条：${barRects(tester)}',
    );
    expect(
      hasBar(tester, Offset(host.left + barLeft, host.top + 84)),
      isFalse, // 旧位置不得残留
      reason: '实测条：${barRects(tester)}',
    );
  });
  testWidgets('容器失效后清掉它的 thumb（tsx 89–94 pruneDetachedOwners 等价）', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    final ScrollController outer = ScrollController();
    final ScrollController inner = ScrollController();
    final ValueNotifier<bool> showInner = ValueNotifier<bool>(true);
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    addTearDown(showInner.dispose);

    await tester.pumpWidget(
      shell(
        ListView.builder(
          controller: outer,
          itemExtent: 240,
          itemCount: 6,
          padding: EdgeInsets.zero,
          itemBuilder: (BuildContext context, int i) => i == 0
              ? ValueListenableBuilder<bool>(
                  valueListenable: showInner,
                  builder: (BuildContext context, bool show, Widget? _) =>
                      show ? list(controller: inner, items: 16) : const SizedBox.shrink(),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    inner.jumpTo(280);
    await tester.pump();
    expect(thumb(), findsOneWidget);

    showInner.value = false; // 内层容器整棵移除 ⇒ 它的 ScrollPosition 被 dispose
    await tester.pump();
    outer.jumpTo(120); // 外层滚动 ⇒ 触发一次重算（旧实现会留一条幽灵条）
    await tester.pump();

    expect(thumb(), findsOneWidget); // 只剩外层自己的条
    final Rect host = hostRect(tester);
    // 外层条：track 320 / scrollSize 1440 ⇒ 长 71、maxTop 249；pixels 120 ⇒ 起点 27
    expect(hasBar(tester, Offset(host.left + 414, host.top + 27)), isTrue);
  });
}
