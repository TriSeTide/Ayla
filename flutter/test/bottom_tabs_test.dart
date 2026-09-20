/// 窄屏底栏定向测试（`BottomTabs.tsx` + shell.css 77–162 + auroraqua 244–255/412–448 对照）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart' show AylaPressScale;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/bottom_tabs.dart';
import '../lib/widgets/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/tab_badge.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  testWidgets('五个 tab 文案与视觉顺序（主页居中）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaBottomTabs()));
    for (final String label in <String>['语音', '直播', '主页', '帖子', '桌游']) {
      expect(find.text(label), findsOneWidget);
    }
    final double voice = tester.getCenter(find.text('语音')).dx;
    final double home = tester.getCenter(find.text('主页')).dx;
    final double games = tester.getCenter(find.text('桌游')).dx;
    expect(voice < home && home < games, isTrue);
  });

  testWidgets('F1 阶段不渲染红点（badges 恒空）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaBottomTabs(module: AylaPrimaryModule.home)),
    );
    expect(find.byType(TabBadge), findsNothing);
  });

  testWidgets('方角容器（auroraqua 447–448 覆写）+ 主页圆盘 48 且上浮 8',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(const AylaBottomTabs(module: AylaPrimaryModule.home)),
    );
    await tester.pumpAndSettle();
    // 容器方角：GlassSurface 的 ClipRRect 半径应为 0
    final Finder clips = find.descendant(
      of: find.byType(AylaBottomTabs),
      matching: find.byType(ClipRRect),
    );
    expect(clips, findsWidgets);
    // 容器方角：主裁剪半径为 0（auroraqua 447–448 覆写 radius-panel 20）
    final bool hasZeroClip = clips
        .evaluate()
        .any((Element e) => (e.widget as ClipRRect).borderRadius == BorderRadius.zero);
    expect(hasZeroClip, isTrue, reason: '窄屏媒体查询把底栏圆角清零 → 方角');
    // 主页圆盘：48 且其顶边在容器顶之上 8（= 向上溢出）
    final Finder disc = find.byWidgetPredicate((Widget w) {
      if (w is! Container) return false;
      final BoxDecoration? d = w.decoration as BoxDecoration?;
      return d != null && d.shape == BoxShape.circle;
    });
    expect(disc, findsOneWidget);
    final Size size = tester.getSize(disc);
    expect(size.width, 48);
    expect(size.height, 48);
  });

  testWidgets('选中胶囊画在按钮内（margin 4/2）且随选中跨槽迁移',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    int index = 2; // 初始「主页」
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return AylaBottomTabs(module: aylaBottomTabOrder[index]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder buttons = find.byType(AylaPressScale);
    Rect capsule = tester.getRect(find.byType(AylaNavHighlight));
    final Rect slot2 = tester.getRect(buttons.at(2));
    expect(capsule.left, closeTo(slot2.left, 0.5), reason: '高亮 inset:0 → 与按钮重合');
    expect(capsule.top, closeTo(slot2.top, 0.5));
    expect(capsule.width, closeTo(slot2.width, 0.5));
    expect(capsule.height, closeTo(slot2.height, 0.5));
    // 按钮内缩 4/2（用第 0 槽量偏移；第 2 槽 left 天然含两个槽宽）
    final Rect bar = tester.getRect(find.byType(AylaBottomTabs));
    final Rect slot0 = tester.getRect(buttons.at(0));
    expect(slot0.left - bar.left, closeTo(2, 0.5), reason: '水平内缩 2');
    expect(slot0.top - bar.top, closeTo(4, 0.5), reason: '垂直内缩 4');
    // 迁移：切到槽位 3
    rebuild(() => index = 3);
    await tester.pumpAndSettle();
    final Rect slot3 = tester.getRect(buttons.at(3));
    capsule = tester.getRect(find.byType(AylaNavHighlight));
    expect(capsule.left, closeTo(slot3.left, 0.5), reason: '胶囊跟随选中槽');
    expect(
      capsule.left - slot2.left,
      closeTo(slot3.left - slot2.left, 0.5),
      reason: '位移 = 一个槽宽',
    );
  });

  testWidgets('点击回调带模块 key；模块表与 web shellConfig 同源',
      (WidgetTester tester) async {
    AylaPrimaryModule? picked;
    await tester.pumpWidget(
      host(AylaBottomTabs(onSelect: (AylaPrimaryModule m) => picked = m)),
    );
    await tester.tap(find.text('帖子'));
    expect(picked, AylaPrimaryModule.posts);
    expect(AylaPrimaryModule.home.path, '/group');
    expect(AylaPrimaryModule.games.label, '桌游');
  });
}
