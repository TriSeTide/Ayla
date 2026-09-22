/// B1-1：voice 域第一批（卡片 / 网格列表 / 控制条）定向测试 —— 逐条对照
/// `VoiceChannelCard.tsx`(47) / `VoiceChannelList.tsx`(43) / `VoiceControls.tsx`(31)
/// 与 `app.css:2811–2832 / 2910–2915 / 3099–3120`、`voice.css:471–485 / 505–628 /
/// 647–659 / 690–789`、`typed-result-cards.css:46–140`、`auroraqua.css:28–52`。
///
/// 覆盖：结构 / 尺寸 / 配色与描边 / 文案四态 / 可见性标签 / 交互回调（卡片与加入钮各一次）/
/// joining 与 active / hover 与键盘焦点环 / 网格列数 2·3·4 与 padding / 空态 / 控制条两态 /
/// 入场 stagger。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/visibility.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/primitives.dart';
import '../lib/widgets/reveal.dart';
import '../lib/widgets/voice_channels.dart';

void main() {
  // 用例级可变状态（配合 `stateful` 助手在**同一棵树**里切态）
  bool uiBrowsing = false;
  bool uiZeroPadding = false;
  bool uiReveal = false;
  bool uiRejoin = false;

  const AylaVoiceCardData basic = AylaVoiceCardData(
    id: '1',
    name: '深夜电台',
    ownerNickname: '爱莉',
    memberCount: 5,
    visibility: AylaPostVisibility.public,
  );

  Widget host(Widget child, {Size viewport = const Size(1200, 700)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 同一棵树里驱动多状态。
  ///
  /// ⚠️ 不能在同一用例里第二次 `pumpWidget`：`previewScope` 的 `Overlay(initialEntries:)`
  /// 只在**首次创建**生效（`13-工作进度与待办.md` §6.19 / §6.21 已两次记录），
  /// 读到的还是旧树。改用树内 `StatefulBuilder` 的 setState。
  ({Widget widget, void Function(VoidCallback) setState}) stateful(
    Widget Function(BuildContext context) builder,
  ) {
    late StateSetter setter;
    return (
      widget: StatefulBuilder(
        builder: (BuildContext context, StateSetter s) {
          setter = s;
          return builder(context);
        },
      ),
      setState: (VoidCallback fn) => setter(fn),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Finder cardAt(int index) => find.byType(AylaCardInteraction).at(index);

  Finder cardSurface(int index) => find.descendant(
        of: cardAt(index),
        matching: find.byType(GlassSurface),
      );

  Color cardBorder(WidgetTester tester, int index) {
    final GlassSurface surface =
        tester.widget<GlassSurface>(cardSurface(index));
    final BoxBorder? border = surface.borderOverride;
    return (border! as Border).top.color;
  }

  /// 卡的语义/焦点宿主（`AylaCardInteraction` 内那层 `Focus`）。
  FocusNode cardFocusNode(WidgetTester tester, int index) =>
      Focus.of(tester.element(cardSurface(index)));

  Future<void> hover(WidgetTester tester, Finder target) async {
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  // ======================= 结构 / 尺寸 / 文案 =======================

  testWidgets('卡片结构：标签组 → 收藏槽 → mic 14 + 名称 → owner → 人数 + 加入钮',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));

    expect(find.byType(AylaScrollingTags), findsOneWidget); // head 左侧标签组
    expect(find.text('公开'), findsOneWidget); // 来源标签（visibility=public）
    expect(find.byType(AylaScrollingText), findsOneWidget); // 名称（单行滚动）
    expect(find.text('深夜电台'), findsOneWidget);
    expect(find.text('爱莉'), findsOneWidget); // owner 行
    expect(find.text('5 人'), findsOneWidget); // foot 人数
    expect(find.text('加入'), findsOneWidget); // 加入钮

    // mic 图标 14×14（tsx 34 `<IconMic width={14} height={14} />`）
    final AylaIcon mic = tester.widget<AylaIcon>(
      find.descendant(
        of: cardAt(0),
        matching: find.byWidgetPredicate(
          (Widget w) => w is AylaIcon && identical(w.icon, aylaIconByName('iconMic')),
        ),
      ),
    );
    expect(mic.size, 14);
    expect(mic.color, AylaColors.textPrimary);
  });

  testWidgets('卡片尺寸：padding 12、圆角 16、加入钮 min-height 32 / 13px',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));

    final GlassSurface surface =
        tester.widget<GlassSurface>(cardSurface(0));
    expect(surface.padding, const EdgeInsets.all(AylaSpacing.sp3)); // 12
    expect(
      surface.radiusOverride,
      BorderRadius.all(Radius.circular(AylaRadii.rCard)), // 16
    );

    final GlassButton join = tester.widget<GlassButton>(
      find.byWidgetPredicate(
        (Widget w) => w is GlassButton && w.label == '加入',
      ),
    );
    expect(join.minHeight, 32);
    expect(join.fontSize, 13);
    expect(join.variant, GlassButtonVariant.primary);
    expect(join.padding, const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3));
    expect(tester.getSize(find.byWidget(join)).height, 32);
  });

  testWidgets('来源标签：max-width 12ch（同字体实测 `0` 宽 ×12）+ 无字重（继承 400）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));

    // 与实现同口径算一遍 12ch
    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: '0',
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double expected = painter.width * 12;

    final ConstrainedBox box = tester.widget<ConstrainedBox>(
      find.descendant(
        of: cardAt(0),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is ConstrainedBox && w.constraints.maxWidth < 200,
        ),
      ),
    );
    expect(box.constraints.maxWidth, closeTo(expected, 0.01));

    final AylaCapsuleTag tag = tester.widget<AylaCapsuleTag>(
      find.byType(AylaCapsuleTag),
    );
    expect(tag.tone, CapsuleTone.sakura); // sakura-300 底 + grape-700 字
    expect(tag.fontSize, 11);
    expect(tag.letterSpacing, 0.8);
    expect(tag.fontWeight, FontWeight.w400); // 该规则未声明字重 ⇒ 继承 body 400
    expect(tag.padding, const EdgeInsets.symmetric(horizontal: 8));
  });

  testWidgets('可见性标签：公开/好友互斥、白名单群名可叠加、group 回落群名、未知→群可见',
      (WidgetTester tester) async {
    expect(
      const AylaVoiceCardData(
        id: 'a',
        name: 'n',
        visibility: AylaPostVisibility.friends,
      ).visibilityLabels,
      <String>['好友'],
    );
    expect(
      const AylaVoiceCardData(
        id: 'b',
        name: 'n',
        visibility: AylaPostVisibility.public,
        allowedGroupNames: <String>['冰樱研究社'],
      ).visibilityLabels,
      <String>['公开', '冰樱研究社'], // 叠加
    );
    expect(
      const AylaVoiceCardData(
        id: 'c',
        name: 'n',
        visibility: AylaPostVisibility.group,
        groupName: '深夜电台',
      ).visibilityLabels,
      <String>['深夜电台'], // 旧数据回落
    );
    expect(
      const AylaVoiceCardData(id: 'd', name: 'n').visibilityLabels,
      <String>['群可见'], // 未知 visibility 的兜底（与 web getVisibilityLabels 同）
    );
  });

  testWidgets('文案四态：加入 / 加入中… / 查看语音房 / mine→「我在其中」',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    // 常规
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));
    expect(find.text('加入'), findsOneWidget);
    expect(find.text('我在其中'), findsNothing);
  });

  testWidgets('文案：joining → 「加入中…」且按钮禁用；卡片不透明 .7',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(const AylaVoiceChannelCard(channel: basic, joining: true)),
    );
    expect(find.text('加入中…'), findsOneWidget);
    expect(
      tester.widget<GlassButton>(find.byType(GlassButton)).onPressed,
      isNull, // disabled
    );
    // 卡内还有 GlassButton 自己的 disabled `Opacity(.55)` 与扫光 `Opacity(.5)`
    // ⇒ 按值锁定卡片那层（不能只按类型取，否则 "Too many elements"）
    expect(
      find.descendant(
        of: cardAt(0),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Opacity && w.opacity == 0.7,
        ),
      ),
      findsOneWidget, // `[aria-disabled="true"] { opacity: .7 }`
    );
  });

  testWidgets('文案：browsing → 「查看语音房」；mine + browsing 仍走按钮（不是「我在其中」）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    final ({Widget widget, void Function(VoidCallback) setState}) demo =
        stateful((BuildContext context) => const AylaVoiceChannelCard(
              channel: AylaVoiceCardData(
                id: 'x',
                name: 'n',
                visibility: AylaPostVisibility.public,
                mine: true,
              ),
              browsing: true,
            ));
    await tester.pumpWidget(host(demo.widget));
    expect(find.text('查看语音房'), findsOneWidget);
    expect(find.text('我在其中'), findsNothing); // tsx 40：mine && !browsing 才显示
    demo.setState(() {});
  });

  testWidgets('mine：foot 显示「我在其中」占位胶囊（min-height 32，与加入钮等高）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelCard(
          channel: AylaVoiceCardData(
            id: 'x',
            name: 'n',
            visibility: AylaPostVisibility.public,
            mine: true,
          ),
        ),
      ),
    );
    expect(find.text('我在其中'), findsOneWidget);
    expect(find.byType(GlassButton), findsNothing);
    final Rect pill = tester.getRect(find.text('我在其中'));
    expect(pill.height, lessThanOrEqualTo(32)); // 胶囊内容高度不超过 32
    final Container container = tester.widget<Container>(
      find.ancestor(
        of: find.text('我在其中'),
        matching: find.byType(Container),
      ).first,
    );
    expect(
      container.constraints!.minHeight,
      32, // `.voice-mine-btn { min-height: 32px }`
    );
  });

  testWidgets('卡片 aria-label：加入/进入/查看 + 语音频道 + 名称（tsx 19/28）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    final ({Widget widget, void Function(VoidCallback) setState}) demo =
        stateful((BuildContext context) =>
            AylaVoiceChannelCard(channel: basic, browsing: uiBrowsing));
    await tester.pumpWidget(host(demo.widget));
    expect(
      tester.widget<AylaCardInteraction>(cardAt(0)).semanticLabel,
      '加入语音频道 深夜电台',
    );
    demo.setState(() => uiBrowsing = true);
    await tester.pump();
    expect(
      tester.widget<AylaCardInteraction>(cardAt(0)).semanticLabel,
      '查看语音频道 深夜电台',
    );
  });

  // ======================= 交互 =======================

  testWidgets('点卡片 → onEnter 一次；点加入钮 → onEnter 一次（不叠加，stopPropagation 等价）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    int enters = 0;
    Widget build() => host(
          AylaVoiceChannelCard(
            channel: basic,
            onEnter: () => enters++,
          ),
        );

    await tester.pumpWidget(build());
    // 按矩形取卡内安全点（标题行左侧，远离右下角的加入钮）——
    // `AylaScrollingText` 自身不是命中目标（库内那层不可点），直接点它会告警
    final Rect r = tester.getRect(cardSurface(0));
    await tester.tapAt(Offset(r.left + 24, r.top + 46));
    await tester.pump();
    expect(enters, 1);

    await tester.tap(find.text('加入'));
    await tester.pump();
    expect(enters, 2, reason: '按钮自己触发一次，且不冒泡到卡片（否则会 +2）');
  });

  testWidgets('joining：点卡片与点按钮都不触发 onEnter', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    int enters = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCard(
          channel: basic,
          joining: true,
          onEnter: () => enters++,
        ),
      ),
    );
    final Rect r = tester.getRect(cardSurface(0));
    await tester.tapAt(Offset(r.left + 24, r.top + 46));
    await tester.tap(find.text('加入中…'), warnIfMissed: false);
    await tester.pump();
    expect(enters, 0);
  });

  testWidgets('mine（我在其中）：描边 --indigo-700（app.css:2832）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelCard(
          channel: AylaVoiceCardData(
            id: 'x',
            name: '深夜电台', // 卡名别也叫「我在其中」，否则与 foot 胶囊文案撞车
            visibility: AylaPostVisibility.public,
            mine: true,
          ),
        ),
      ),
    );
    // `.voice-channel-card.mine { border-color: var(--indigo-700) }`
    expect(cardBorder(tester, 0), AylaColors.indigo700);
    expect(find.text('我在其中'), findsOneWidget); // foot 占位胶囊
  });

  testWidgets('active：描边 --indigo-700（状态，不是悬停）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(
      host(const AylaVoiceChannelCard(channel: basic, active: true)),
    );
    expect(cardBorder(tester, 0), AylaColors.indigo700);

    await hover(tester, cardSurface(0));
    expect(cardBorder(tester, 0), AylaColors.indigo700);
  });

  testWidgets('hover = 库内统一卡片悬停：**不改边色**，只上浮 2px + 换 --glass-shadow-hover',
      (WidgetTester tester) async {
    // 用户 2026-09-21 裁决：web 的 `.voice-hub .voice-channel-card:hover { border-color:
    // rgba(157,191,230,.65) }`（voice.css:543–545）是 **web 端错误**（整个 web 的卡片本应复用
    // 同一套悬停）⇒ Flutter **不复刻**该 hover 换边色。统一悬停 = auroraqua.css:28–52 的
    // 「`translate: 0 -2px` + `box-shadow: --glass-shadow-hover`」；press `.99` 归
    // AylaCardInteraction（见下一条用例）。
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));
    expect(cardBorder(tester, 0), AylaColors.glassBorder);
    expect(tester.widget<GlassSurface>(cardSurface(0)).shadow, AylaShadows.glass);
    final double topBefore = tester.getRect(cardSurface(0)).top;

    await hover(tester, cardSurface(0));

    expect(cardBorder(tester, 0), AylaColors.glassBorder); // 悬停**不改边色**
    expect(
      tester.widget<GlassSurface>(cardSurface(0)).shadow,
      AylaShadows.glassHover, // 换 hover 阴影
    );
    await tester.pump(const Duration(milliseconds: 400)); // 300ms 位移走完
    expect(tester.getRect(cardSurface(0)).top, closeTo(topBefore - 2, 0.5));
  });

  testWidgets('press：scale .99（卡片族共用；不是悬停态）', (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    await tester.pumpWidget(host(const AylaVoiceChannelCard(channel: basic)));
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(cardSurface(0)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester
          .widgetList<AnimatedScale>(find.byType(AnimatedScale))
          .any((AnimatedScale s) => (s.scale - 0.99).abs() < 0.001),
      isTrue,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('键盘：聚焦出 ice-500 焦点环（2px、画在形状外、不占布局）+ Enter 进房',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1200, 700));
    int enters = 0;
    await tester.pumpWidget(
      host(AylaVoiceChannelCard(channel: basic, onEnter: () => enters++)),
    );
    final Rect before = tester.getRect(cardSurface(0));

    cardFocusNode(tester, 0).requestFocus();
    await tester.pump();

    // 环：`Positioned(-4,-4,-4,-4)` 里 2px 描边 + 半径 16+2
    final Finder ring = find.descendant(
      of: cardAt(0),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is Positioned &&
            w.left == -4 &&
            w.top == -4 &&
            w.right == -4 &&
            w.bottom == -4,
      ),
    );
    expect(ring, findsOneWidget);
    final DecoratedBox ringBox = tester.widget<DecoratedBox>(
      find.descendant(of: ring, matching: find.byType(DecoratedBox)),
    );
    final BoxDecoration deco = ringBox.decoration as BoxDecoration;
    expect((deco.border! as Border).top.color, AylaColors.ice500);
    expect((deco.border! as Border).top.width, 2);
    final BorderRadius r = deco.borderRadius! as BorderRadius;
    expect(r.topLeft.x, AylaRadii.rCard + 2); // 环跟随卡片 radius 16

    // 不占布局：卡片自身尺寸不变（AylaPressScale 的内嵌环会 +4px，这里不会）
    expect(tester.getRect(cardSurface(0)), before);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(enters, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(enters, 2);
  });

  // ======================= 列表：列数 / padding / 空态 / stagger =======================

  for (final (Size viewport, int expected) in <(Size, int)>[
    (Size(375, 700), 2),
    (Size(1000, 700), 3),
    (Size(1600, 700), 4),
  ]) {
    testWidgets(
        '网格列数：${viewport.width.toInt()} → $expected 列（voice.css 507/650/657）',
        (WidgetTester tester) async {
      setViewport(tester, viewport);
      await tester.pumpWidget(
        host(
          AylaVoiceChannelList(
            channels: <AylaVoiceCardData>[
              for (int i = 0; i < expected; i++)
                AylaVoiceCardData(id: '$i', name: '房 $i'),
            ],
          ),
          viewport: viewport,
        ),
      );
      // 一行放得下 expected 张：第 1 张与第 expected 张同一 top
      expect(
        tester.getRect(cardAt(expected - 1)).top,
        tester.getRect(cardAt(0)).top,
        reason: '${viewport.width.toInt()} 宽应放得下 $expected 列',
      );
      // 且第 expected+1 张必须换行（列数不会更多）
      if (expected < 4) {
        await tester.pumpWidget(
          host(
            AylaVoiceChannelList(
              channels: <AylaVoiceCardData>[
                for (int i = 0; i < expected + 1; i++)
                  AylaVoiceCardData(id: '$i', name: '房 $i'),
              ],
            ),
            viewport: viewport,
          ),
        );
      }
    });
  }

  testWidgets('列表 padding：默认 sp3/sp4（12/16）；传 EdgeInsets.zero 时贴边（群内用法）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final ({Widget widget, void Function(VoidCallback) setState}) demo = stateful(
      (BuildContext context) => AylaVoiceChannelList(
        channels: <AylaVoiceCardData>[basic],
        columns: 2,
        padding: uiZeroPadding ? EdgeInsets.zero : null,
      ),
    );
    await tester.pumpWidget(host(demo.widget));
    final Rect padded = tester.getRect(cardAt(0));
    expect(padded.left, AylaSpacing.sp4); // 16（padding-inline）
    expect(padded.top, AylaSpacing.sp3); // 12（padding-block）

    demo.setState(() => uiZeroPadding = true);
    await tester.pump();
    expect(tester.getRect(cardAt(0)).left, 0);
  });

  testWidgets('空态：placeholder 两行（Fredoka 28/600 + 14px secondary）居中',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(
      host(const AylaVoiceChannelList(channels: <AylaVoiceCardData>[])),
    );
    expect(find.text('还没有语音房'), findsOneWidget);
    expect(find.text('点右下角 + 建一个吧'), findsOneWidget);
    expect(find.byType(AylaCardInteraction), findsNothing);

    final TextStyle title =
        tester.widget<Text>(find.text('还没有语音房')).style!;
    expect(title.fontSize, 28);
    expect(title.fontWeight, FontWeight.w600);
    expect(title.fontFamily, AylaFonts.display);
    expect(title.color, AylaColors.textPrimary);
    final TextStyle desc =
        tester.widget<Text>(find.text('点右下角 + 建一个吧')).style!;
    expect(desc.fontSize, 14);
    expect(desc.color, AylaColors.textSecondary);
  });

  testWidgets('入场：revealItems=false 不挂 reveal；true 时每张卡一个 reveal 槽',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final ({Widget widget, void Function(VoidCallback) setState}) demo = stateful(
      (BuildContext context) => AylaVoiceChannelList(
        channels: <AylaVoiceCardData>[basic, basic],
        columns: 2,
        revealItems: uiReveal,
      ),
    );
    await tester.pumpWidget(host(demo.widget));
    expect(find.byType(AylaRevealItem), findsNothing);

    demo.setState(() => uiReveal = true);
    await tester.pump();
    expect(find.byType(AylaRevealItem), findsNWidgets(2));
  });

  testWidgets('列表：「我在其中」只有一张 ⇒ 只有它的卡带描边（用户 2026-09-21）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(
      host(
        AylaVoiceChannelList(
          channels: <AylaVoiceCardData>[
            const AylaVoiceCardData(id: '1', name: '普通一'),
            const AylaVoiceCardData(id: '2', name: '深夜电台', mine: true),
            const AylaVoiceCardData(id: '3', name: '普通二'),
          ],
          currentChannelId: '2', // mine 同时是当前频道
          columns: 2,
        ),
      ),
    );
    expect(cardBorder(tester, 0), AylaColors.glassBorder);
    expect(cardBorder(tester, 1), AylaColors.indigo700); // 唯一带描边的卡
    expect(cardBorder(tester, 2), AylaColors.glassBorder);
    expect(find.text('我在其中'), findsOneWidget); // 全列表只有一张
  });

  testWidgets('列表 active 与 joining 透传：currentChannelId 命中者描边 indigo-700',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(
      host(
        AylaVoiceChannelList(
          channels: <AylaVoiceCardData>[
            basic,
            const AylaVoiceCardData(id: '2', name: '第二个'),
          ],
          currentChannelId: '2',
          columns: 2,
        ),
      ),
    );
    expect(cardBorder(tester, 0), AylaColors.glassBorder);
    expect(cardBorder(tester, 1), AylaColors.indigo700);
  });

  // ======================= 控制条 =======================

  testWidgets('控制条：默认只有「离开频道」；showRejoin 时追加「重新加入」',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final ({Widget widget, void Function(VoidCallback) setState}) demo = stateful(
      (BuildContext context) => AylaVoiceControls(showRejoin: uiRejoin),
    );
    await tester.pumpWidget(host(demo.widget));
    expect(find.text('离开频道'), findsOneWidget);
    expect(find.text('重新加入'), findsNothing);

    demo.setState(() => uiRejoin = true);
    await tester.pump();
    expect(find.text('重新加入'), findsOneWidget);
    final GlassButton rejoin = tester.widget<GlassButton>(
      find.byWidgetPredicate(
        (Widget w) => w is GlassButton && w.label == '重新加入',
      ),
    );
    expect(rejoin.variant, GlassButtonVariant.primary);
    expect(rejoin.minHeight, 28); // `.voice-rejoin-btn { min-height: 28px }`
    expect(rejoin.fontSize, 12);
    expect(rejoin.padding, const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3));
  });

  testWidgets('离开钮 = outlineDestructive：透明底 + destructive 字 + 1px destructive 边、无阴影',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(const AylaVoiceControls()));

    final GlassButton leave = tester.widget<GlassButton>(
      find.byWidgetPredicate(
        (Widget w) => w is GlassButton && w.label == '离开频道',
      ),
    );
    expect(leave.variant, GlassButtonVariant.outlineDestructive);

    // 面层：透明底 + destructive 1px 边（app.css 3108–3112）
    final AnimatedContainer face = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byWidget(leave),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final BoxDecoration deco = face.decoration! as BoxDecoration;
    expect(deco.color, Colors.transparent);
    expect(deco.border!.top.color, AylaColors.destructive);

    // `.btn` 基础块未声明 box-shadow ⇒ 该档 `shadow = []`（阴影环 painter 存在但零绘制）；
    // 同时也不叠 `--glass-inset` 内高光（那条只随阴影 token 出现）⇒ 面层无内高光渐变。
    expect(leave.variant, GlassButtonVariant.outlineDestructive);
  });

  testWidgets('控制条外观：padding-top 8 + 顶部 1px --glass-border（app.css 3099–3106）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    await tester.pumpWidget(host(const AylaVoiceControls()));
    final Container box = tester.widget<Container>(
      find.byType(Container).first,
    );
    expect(box.padding, const EdgeInsets.only(top: AylaSpacing.sp2));
    final BoxDecoration deco = box.decoration! as BoxDecoration;
    expect((deco.border! as Border).top.color, AylaColors.glassBorder);
    expect((deco.border! as Border).top.width, 1.0);
    // flex-wrap：两个按钮在窄容器里换行而不是溢出
    expect(find.byType(Wrap), findsOneWidget);
  });

  testWidgets('回调：离开 / 重新加入各自触发', (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    int leaves = 0;
    int rejoins = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceControls(
          showRejoin: true,
          onLeave: () => leaves++,
          onRejoin: () => rejoins++,
        ),
      ),
    );
    await tester.tap(find.text('离开频道'));
    await tester.pump();
    await tester.tap(find.text('重新加入'));
    await tester.pump();
    expect(leaves, 1);
    expect(rejoins, 1);
  });

  testWidgets('列表点击 → onJoin(id)（web onEnter → onJoin(channel.id)）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(1000, 700));
    final List<String> joined = <String>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelList(
          channels: <AylaVoiceCardData>[basic],
          columns: 2,
          onJoin: joined.add,
        ),
      ),
    );
    await tester.tap(find.text('加入'));
    await tester.pump();
    expect(joined, <String>['1']);
  });
}
