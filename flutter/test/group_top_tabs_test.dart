/// 群内顶栏定向测试（`GroupTopTabs.tsx` 1–125 + group.css 21–91 + auroraqua 253/255/448 对照）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart' show AylaPressScale;
import '../lib/theme/tokens.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/bottom_tabs.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/group_top_tabs.dart';
import '../lib/widgets/primitives.dart' show AylaNavHighlight;

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  testWidgets('四 tab 文案（无「主页」）+ 中央群头像 48', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 375,
          child: AylaGroupTopTabs(
            groupName: '深夜电台',
            activeScene: AylaGroupScene.voice,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final String label in <String>['语音', '直播', '帖子', '桌游']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('主页'), findsNothing, reason: '群顶栏中央是头像槽，不是主页 tab');
    expect(find.byType(AvatarHalo), findsOneWidget);
    expect(tester.getSize(find.byType(AvatarHalo)).width, 48);
  });

  testWidgets('选中胶囊画在按钮内且随场景跨槽迁移', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AylaGroupScene scene = AylaGroupScene.voice; // 槽 0
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return SizedBox(
              width: 375,
              child: AylaGroupTopTabs(
                groupName: '深夜电台',
                activeScene: scene,
                onSelectScene: (AylaGroupScene next) => setState(() => scene = next),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder buttons = find.byType(AylaPressScale);
    expect(buttons, findsNWidgets(4), reason: '只有四个 tab 按钮（头像槽不是 AylaPressScale）');
    Rect capsule = tester.getRect(find.byType(AylaNavHighlight));
    Rect slot0 = tester.getRect(buttons.at(0));
    expect(capsule.left, closeTo(slot0.left, 0.5), reason: '高亮 inset:0 → 与按钮重合');
    expect(capsule.width, closeTo(slot0.width, 0.5), reason: '按钮宽 = 内容宽（inline-flex）');
    // 点「直播」（槽 1）→ 胶囊迁移
    await tester.tap(find.text('直播'));
    await tester.pumpAndSettle();
    final Rect slot1 = tester.getRect(buttons.at(1));
    capsule = tester.getRect(find.byType(AylaNavHighlight));
    expect(capsule.left, closeTo(slot1.left, 0.5));
    expect(capsule.width, closeTo(slot1.width, 0.5));
    expect(slot1.left, greaterThan(slot0.left), reason: '槽序：语音 → 直播');
    // 直接改父级状态也生效（受控）
    rebuild(() => scene = AylaGroupScene.games);
    await tester.pumpAndSettle();
    final Rect slot3 = tester.getRect(buttons.at(3));
    capsule = tester.getRect(find.byType(AylaNavHighlight));
    expect(capsule.left, closeTo(slot3.left, 0.5));
  });

  testWidgets("帖子 tab 未读红点：>0 显示 8px 粉点，=0 不显示", (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // ⚠️ 必须用 StatefulBuilder 宿主只改参数：换 `MaterialApp.home` 不会重建子树
    // （skill 教训：同类型 MaterialApp 的 home 替换后子树 build 不跑）。
    int unread = 3;
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return SizedBox(
              width: 375,
              child: AylaGroupTopTabs(
                groupName: "深夜电台",
                activeScene: AylaGroupScene.voice,
                postUnread: unread,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder dot = find.byWidgetPredicate((Widget w) {
      if (w is! Container) return false;
      final BoxDecoration? d = w.decoration as BoxDecoration?;
      return d != null &&
          d.shape == BoxShape.circle &&
          d.color == AylaColors.pink500;
    });
    expect(dot, findsOneWidget);
    expect(tester.getSize(dot).width, 8);
    rebuild(() => unread = 0);
    await tester.pumpAndSettle();
    expect(dot, findsNothing, reason: "阅读后红点消失（postUnread=0）");
  });
  testWidgets("群顶栏条高 = 64（group.css:36）", (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 375,
          child: AylaGroupTopTabs(
            groupName: "深夜电台",
            activeScene: AylaGroupScene.chat,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AylaGroupTopTabs)).height, 64);
  });

  testWidgets("底栏条高 = 64（shell.css:96）——与群顶栏同高", (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 375,
          child: AylaBottomTabs(module: AylaPrimaryModule.home),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AylaBottomTabs)).height, 64);
  });

  testWidgets("场景为聊天（头像槽）时清空胶囊——其它 tab 高亮必须去掉",
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AylaGroupScene scene = AylaGroupScene.voice;
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return SizedBox(
              width: 375,
              child: AylaGroupTopTabs(
                groupName: "深夜电台",
                activeScene: scene,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AylaNavHighlight), findsOneWidget, reason: "选中语音 → 有胶囊");
    rebuild(() => scene = AylaGroupScene.chat);
    await tester.pumpAndSettle();
    expect(
      find.byType(AylaNavHighlight),
      findsNothing,
      reason: "聊天是头像槽场景，四个 tab 都不得高亮（2026-09-20 用户实测残留）",
    );
    rebuild(() => scene = AylaGroupScene.posts);
    await tester.pumpAndSettle();
    expect(find.byType(AylaNavHighlight), findsOneWidget, reason: "切到帖子 → 胶囊回来");
  });

  testWidgets('方角容器（auroraqua 448 覆写 253）+ 父级 offset 生效', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 375,
          child: AylaGroupTopTabs(
            groupName: '深夜电台',
            activeScene: AylaGroupScene.voice,
            offset: Offset(0, 40), // 父级驱动（入场中间帧）
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder clips = find.descendant(
      of: find.byType(AylaGroupTopTabs),
      matching: find.byType(ClipRRect),
    );
    final bool square = clips
        .evaluate()
        .any((Element e) => (e.widget as ClipRRect).borderRadius == BorderRadius.zero);
    expect(square, isTrue, reason: '窄屏媒体查询把圆角清零 → 方角');
    // offset 生效：组件矩形应下移 40（相对未位移时的位置）
    final Rect moved = tester.getRect(find.byType(AylaGroupTopTabs));
    expect(moved.top, greaterThan(0));
  });
}
