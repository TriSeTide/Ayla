/// 窄屏底栏定向测试（web `BottomTabs.tsx` + shell.css 77–162 对照）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/bottom_tabs.dart';
import '../lib/widgets/primitives.dart' show AylaNavHighlight;

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  testWidgets('五个 tab：文案与顺序（主页居中）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaBottomTabs()));
    for (final String label in <String>['语音', '直播', '主页', '帖子', '桌游']) {
      expect(find.text(label), findsOneWidget);
    }
    final double homeX = tester.getCenter(find.text('主页')).dx;
    final double voiceX = tester.getCenter(find.text('语音')).dx;
    final double gamesX = tester.getCenter(find.text('桌游')).dx;
    expect(voiceX < homeX && homeX < gamesX, isTrue);
  });

  testWidgets('选中态：共享胶囊 + 未读徽标（99+ 封顶）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        const AylaBottomTabs(
          module: AylaPrimaryModule.home,
          badges: <AylaPrimaryModule, int>{
            AylaPrimaryModule.posts: 3,
            AylaPrimaryModule.live: 128,
          },
        ),
      ),
    );
    expect(find.byType(AylaNavHighlight), findsOneWidget, reason: '只有一个选中项');
    expect(find.text('3'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('点击回调带模块 key；模块表与 web shellConfig 同源', (WidgetTester tester) async {
    AylaPrimaryModule? picked;
    await tester.pumpWidget(
      host(AylaBottomTabs(onSelect: (AylaPrimaryModule m) => picked = m)),
    );
    await tester.tap(find.text('帖子'));
    expect(picked, AylaPrimaryModule.posts);
    expect(AylaPrimaryModule.posts.path, '/posts');
    expect(AylaPrimaryModule.games.label, '桌游');
    expect(AylaPrimaryModule.home.path, '/group');
  });

  testWidgets('主页凸起圆盘 48px', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaBottomTabs()));
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
}
