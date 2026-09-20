/// 响应式顶栏定向测试（`TopNav.tsx` 1–343 + `NarrowTopBar.tsx` 1–199 + 样式链对照）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/bottom_tabs.dart' show AylaPrimaryModule;
import '../lib/widgets/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/top_nav.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  Future<void> setWidth(WidgetTester tester, double w) async {
    tester.view.physicalSize = Size(w, 220);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('宽屏（1600）：圆角浮动卡 + 五个模块 + logo', (WidgetTester tester) async {
    await setWidth(tester, 1600);
    await tester.pumpWidget(host(const AylaTopNav(userName: '爱莉')));
    await tester.pumpAndSettle();
    // 条 = 复用 GlassCard（auroraqua:262–270 的浮动圆角卡）
    expect(find.byType(GlassCard), findsWidgets);
    for (final String label in <String>['主页', '语音', '直播', '帖子', '桌游']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Ayla'), findsOneWidget, reason: '1600 > 1240 → logo 显示');
    expect(find.text('搜索'), findsOneWidget, reason: '宽屏搜索框 placeholder');
    // 宽屏条高 64（shell.css:168）
    expect(tester.getSize(find.byType(GlassCard).first).height, greaterThanOrEqualTo(64));
  });

  testWidgets('≤1240 隐藏 logo（shell.css:268–272）', (WidgetTester tester) async {
    await setWidth(tester, 1200);
    await tester.pumpWidget(host(const AylaTopNav(userName: '爱莉')));
    await tester.pumpAndSettle();
    expect(find.text('Ayla'), findsNothing);
    expect(find.text('主页'), findsOneWidget, reason: '模块链仍在');
  });

  testWidgets('窄屏（375）：方角条 + 头像 36 + 搜索胶囊，无模块链', (WidgetTester tester) async {
    await setWidth(tester, 375);
    await tester.pumpWidget(host(const AylaTopNav(userName: '爱莉')));
    await tester.pumpAndSettle();
    expect(find.text('主页'), findsNothing, reason: '窄屏不出模块链');
    expect(find.text('搜索'), findsOneWidget, reason: 'default 变体的搜索胶囊文案');
    expect(find.byType(AvatarHalo), findsOneWidget);
    // 头像 36（NarrowTopBar.tsx:182）。⚠️ 量 **widget 属性**而非渲染尺寸：
    // AvatarHalo 在线时有呼吸动画（AnimationController _breathe），渲染尺寸会抖动。
    final AvatarHalo halo = tester.widget<AvatarHalo>(find.byType(AvatarHalo));
    expect(halo.size, 36);
    // 窄屏条：方角（radiusOverride: BorderRadius.zero → ClipRRect 半径 0）
    final Finder clips = find.descendant(
      of: find.byType(AylaTopNav),
      matching: find.byType(ClipRRect),
    );
    final bool square = clips
        .evaluate()
        .any((Element e) => (e.widget as ClipRRect).borderRadius == BorderRadius.zero);
    expect(square, isTrue, reason: '窄屏条无圆角（home.css:34–48 未声明 radius）');
  });

  testWidgets('窄屏 search 变体：返回钮 + 输入框 placeholder + 更多', (WidgetTester tester) async {
    await setWidth(tester, 375);
    await tester.pumpWidget(
      host(
        AylaTopNav(
          userName: '爱莉',
          variant: AylaTopNavVariant.search,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('搜索用户、群、帖子…'), findsOneWidget, reason: 'NarrowTopBar.tsx:153');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('窄屏 favorites 变体：标题 + 返回钮', (WidgetTester tester) async {
    await setWidth(tester, 375);
    await tester.pumpWidget(
      host(
        AylaTopNav(
          userName: '爱莉',
          variant: AylaTopNavVariant.favorites,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的收藏'), findsOneWidget);
  });

  testWidgets('模块点击回调带模块 key', (WidgetTester tester) async {
    await setWidth(tester, 1600);
    AylaPrimaryModule? picked;
    await tester.pumpWidget(
      host(
        AylaTopNav(
          userName: '爱莉',
          onModuleTap: (AylaPrimaryModule m) => picked = m,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('直播'));
    expect(picked, AylaPrimaryModule.live);
  });

  testWidgets('选中模块渲染共享胶囊（有 `has-auroraqua-highlight` ⇒ 不画底条）',
      (WidgetTester tester) async {
    await setWidth(tester, 1600);
    await tester.pumpWidget(
      host(
        const AylaTopNav(
          userName: '爱莉',
          module: AylaPrimaryModule.posts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('nope')), findsNothing);
    // 胶囊在库内为 AylaNavHighlight，选中项恰好一个；且**必须带白边**
    final AylaNavHighlight hl = tester.widget<AylaNavHighlight>(
      find.byType(AylaNavHighlight),
    );
    expect(
      hl.showBorder,
      isTrue,
      reason: '白边 = auroraqua.css:186 的 `border: 1px solid --glass-border`',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('模块胶囊几何实测（web：min-height 44 + padding 0 sp3 ⇒ 高 44）',
      (WidgetTester tester) async {
    await setWidth(tester, 1600);
    await tester.pumpWidget(
      host(
        const AylaTopNav(userName: '爱莉', module: AylaPrimaryModule.home),
      ),
    );
    await tester.pumpAndSettle();
    final Rect cap = tester.getRect(find.byType(AylaNavHighlight));
    // ignore: avoid_print
    print('MEASURED capsule=${cap.size}');
    expect(cap.height, 44, reason: 'web：min-height 44 + 内容高 ⇒ 按钮高 44（auroraqua:258）');
    expect(cap.width, greaterThan(60), reason: '宽 = 图标16 + 6 + 文字 + 2×sp3');
  });

  testWidgets('更多菜单：三项文案齐全 + 挂在锚点下方（不错位）',
      (WidgetTester tester) async {
    await setWidth(tester, 1600);
    await tester.pumpWidget(host(const AylaTopNav(userName: '爱莉')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('更多').last);
    await tester.pumpAndSettle();
    expect(find.text('个人主页'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    final Rect item = tester.getRect(find.text('个人主页'));
    final Rect more = tester.getRect(find.bySemanticsLabel('更多').last);
    // ignore: avoid_print
    print('MENU item=${item} moreBtn=${more}');
    // 菜单应在按钮下方（top ≈ 按钮底 + 8），且右对齐（right ≈ 按钮右）
    expect(item.top, greaterThan(more.bottom), reason: 'top: calc(100% + 8px)');
    expect(item.left, greaterThan(1000), reason: '挂在右侧锚点附近');
  });

  testWidgets('宽屏内容垂直居中（web `.top-nav { align-items: center }`）',
      (WidgetTester tester) async {
    await setWidth(tester, 1600);
    await tester.pumpWidget(host(const AylaTopNav(userName: '爱莉')));
    await tester.pumpAndSettle();
    final Rect bar = tester.getRect(find.byType(GlassCard).first);
    final Rect avatar = tester.getRect(find.byType(AvatarHalo));
    final Rect logo = tester.getRect(find.text('Ayla'));
    final Rect search = tester.getRect(find.byType(TextField));
    // ignore: avoid_print
    print('VCENTER bar=${bar.center.dy} avatar=${avatar.center.dy} '
        'logo=${logo.center.dy} search=${search.center.dy}');
    expect(avatar.center.dy, closeTo(bar.center.dy, 1.0), reason: '头像居中');
    expect(logo.center.dy, closeTo(bar.center.dy, 1.0), reason: 'logo 居中');
    expect(search.center.dy, closeTo(bar.center.dy, 1.0), reason: '搜索框居中');
  });
}
