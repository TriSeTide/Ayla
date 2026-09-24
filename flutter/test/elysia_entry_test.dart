/// B3 chat 域第一批：爱莉入口卡定向测试 —— 逐条对照
/// `components/chat/ElysiaEntry.tsx`(31) 与 `app.css:435–478`（`.elysia-entry` 全族）、
/// `app.css:3195–3200`（窄屏辉光降 30%）。
///
/// 覆盖：结构（40 头像 + 名 + 副标题 + 箭头）/ 文案两态（启用 / 停用）/ 材质
/// （135deg sakura 渐变 + 1px rgba(247,150,255,.5) + radius 16 + padding 12）/
/// 交互（点击进入）/ 窄屏 hover 辉光降 30%。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/elysia_profile.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/elysia_entry.dart';

const AylaElysiaProfile _profile = AylaElysiaProfile(
  id: 1,
  displayName: '爱莉',
  enabled: true,
  userId: 'elysia',
);

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(420, 200),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 374, child: child),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('结构：40 爱莉头像 + 名字 + 副标题 + 箭头', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, AylaElysiaEntry(profile: _profile, onEnter: () {})));
    await tester.pump(const Duration(milliseconds: 50));

    final AvatarHalo halo = tester.widget<AvatarHalo>(find.byType(AvatarHalo));
    expect(halo.size, 40, reason: '`<Avatar size={40}>`（tsx 21）');
    expect(halo.core, AvatarCore.elysia, reason: '爱莉专属光环（辉光归属爱莉身份）');
    expect(halo.online, isTrue, reason: '`online={profile.enabled}`');

    expect(find.text('爱莉'), findsOneWidget);
    expect(find.text('在线 · 与她聊天'), findsOneWidget);
    expect(find.text('›'), findsOneWidget, reason: '箭头字符 › 18px');

    // `padding: var(--sp-3)` + `border-radius: var(--radius-card)`
    final Iterable<AnimatedContainer> boxes =
        tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
    final BoxDecoration deco =
        boxes.first.decoration! as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(AylaRadii.rCard));
    expect(deco.border, Border.all(color: AylaColors.elysiaBubbleBorder));
    final LinearGradient gradient = deco.gradient! as LinearGradient;
    expect(gradient.colors, <Color>[AylaColors.sakura100, AylaColors.sakura300]);
  });

  testWidgets('停用态：副标题「已停用」+ 离线光环', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        const AylaElysiaEntry(
          profile: AylaElysiaProfile(id: 1, displayName: '爱莉', enabled: false),
          onEnter: null,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已停用'), findsOneWidget);
    expect(tester.widget<AvatarHalo>(find.byType(AvatarHalo)).online, isFalse);
  });

  testWidgets('display_name 为空 → 回退「爱莉」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        const AylaElysiaEntry(
          profile: AylaElysiaProfile(id: 1, displayName: '  ', enabled: true),
          onEnter: null,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('爱莉'), findsOneWidget);
  });

  testWidgets('点击 → onEnter', (WidgetTester tester) async {
    int entered = 0;
    await tester.pumpWidget(
      host(tester, AylaElysiaEntry(profile: _profile, onEnter: () => entered++)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('爱莉'));
    await tester.pump();
    expect(entered, 1);
  });

  testWidgets('hover 辉光：宽屏 --glow-shadow；窄屏降 30%（app.css 3195–3200）', (
    WidgetTester tester,
  ) async {
    // 宽屏（>768）
    await tester.pumpWidget(
      host(
        tester,
        AylaElysiaEntry(profile: _profile, onEnter: () {}),
        viewport: const Size(900, 200),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('爱莉')));
    await tester.pump(const Duration(milliseconds: 300));
    BoxDecoration decoOf(WidgetTester t) => t
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .first
        .decoration! as BoxDecoration;
    expect(decoOf(tester).boxShadow, AylaShadows.glow, reason: '宽屏 hover → --glow-shadow');
  });

  testWidgets('hover 辉光：窄屏（≤768）降 30% → 11px .32', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaElysiaEntry(profile: _profile, onEnter: () {}),
        viewport: const Size(600, 200),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('爱莉')));
    await tester.pump(const Duration(milliseconds: 300));
    final BoxDecoration deco = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .first
        .decoration! as BoxDecoration;
    expect(deco.boxShadow, AylaShadows.glowNarrow);
  });
}
