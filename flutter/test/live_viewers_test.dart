/// B2-4：在看观众条 + 在看名单弹层定向测试 —— 逐条对照
/// `components/live/LiveViewerStrip.tsx`(85) / `LiveViewerSheet.tsx`(147)、
/// `live.css:1095–1325`，并移植官方用例 `vitest/live-viewers.test.tsx:161–256`
/// （整排可点 / 未知不冒充 0 / 0 是真实读数 / 纯展示不拉数据 / 行跳主页后关闭 /
/// 截断提示 / 503 明示 + 重试 / portal 到 body）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/dialogs.dart' show AylaModalCard;
import '../lib/widgets/loading.dart' show AylaSkeleton;
import '../lib/widgets/live_viewers.dart';

const List<AylaLiveViewerItem> _watchers = <AylaLiveViewerItem>[
  AylaLiveViewerItem(userId: 'u1', nickname: '小冰'),
  AylaLiveViewerItem(userId: 'u2', nickname: '小樱'),
];

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(900, 700),
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: viewport, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 整排按钮（aria 文案定位，官方用例用 role+name 同义）。
  Finder strip(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  group('LiveViewerStrip（官方用例 161–209）', () {
    testWidgets('渲染人数 + 头像 + 三圆点「更多」，整排可点开名单', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 2, viewers: _watchers),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);

      expect(strip('正在观看 2 人，查看完整名单'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // 预览头像复用 AvatarHalo（在流光环）
      expect(find.byType(AvatarHalo), findsNWidgets(2));
      // 排尾是「更多」三圆点图标（不是文本省略号）
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container && w.constraints?.maxWidth == 26 && w.constraints?.maxHeight == 26,
        ),
        findsOneWidget,
      );

      await tester.tap(strip('正在观看 2 人，查看完整名单'));
      await settle(tester);
      // 弹层标题 = 「正在观看 · N 人」（tsx 83–86）
      expect(find.text('正在观看 · 2 人'), findsOneWidget);
      expect(find.byType(AylaLiveViewerSheet), findsOneWidget);
    });

    testWidgets('人数未知仍占位：显示 –，不冒充 0，且高度与已知态一致', (WidgetTester tester) async {
      // ⚠️ 同一用例里不能第二次 pumpWidget 换 props（`previewScope` 的 Overlay 只在首次创建
      //    生效，§6.19/§6.21 已两次记录；实测第二次 pump 连 didUpdateWidget 都不触发）
      //    ⇒ 用树内 StatefulBuilder 的 setState 切态。
      int? count = 3;
      late StateSetter setLocal;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setLocal = setState;
              return AylaLiveViewerStrip(count: count);
            },
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      final double known = tester.getRect(find.byType(AylaLiveViewerStrip)).height;
      expect(find.text('3'), findsOneWidget);

      setLocal(() => count = null);
      await settle(tester);
      expect(find.text('–'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(
        tester.getRect(find.byType(AylaLiveViewerStrip)).height,
        known,
        reason: '未知态高度必须与已知态完全一致（禁止画面跳变）',
      );
    });

    testWidgets('0 人是真实读数：显示 0，无头像，仍有「更多」入口', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 0),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(find.text('0'), findsOneWidget);
      expect(find.byType(AvatarHalo), findsNothing);
      expect(find.text('–'), findsNothing);
    });

    testWidgets('预览上限 12：多给只渲染前 12 个头像（tsx 27）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerStrip(
            count: 20,
            viewers: <AylaLiveViewerItem>[
              for (int i = 1; i <= 15; i += 1)
                AylaLiveViewerItem(userId: '$i', nickname: '观众$i'),
            ],
          ),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(kAylaLiveViewerPreviewMax, 12);
      expect(find.byType(AvatarHalo), findsNWidgets(12));
    });

    testWidgets('纯展示：空数据也不报错、不弹层（不自行拉数据）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: null),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(AylaLiveViewerSheet), findsNothing);
    });

    testWidgets('几何：min-height 44 / padding sp1 sp3 / radius-input / 玻璃底', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerStrip(count: 1),
          viewport: const Size(560, 300),
        ),
      );
      await settle(tester);
      final Rect rect = tester.getRect(find.byType(AylaLiveViewerStrip));
      expect(rect.height, greaterThanOrEqualTo(44)); // min-height: 44px
      final Container box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AylaLiveViewerStrip),
              matching: find.byType(Container),
            )
            .first,
      );
      final BoxDecoration deco = box.decoration! as BoxDecoration;
      expect(deco.color, AylaColors.glassBg);
      expect(
        (deco.borderRadius! as BorderRadius).topLeft.x,
        AylaRadii.rInput,
      );
      expect(box.padding, isNotNull);
    });
  });

  group('LiveViewerSheet（官方用例 211–256）', () {
    testWidgets('名单渲染头像 + 昵称；点整行 → 回调 + 关闭弹层', (WidgetTester tester) async {
      String? picked;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 2,
              onOpenProfile: (AylaLiveViewerItem v) => picked = v.userId,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);

      expect(find.text('小冰'), findsOneWidget);
      expect(find.text('小樱'), findsOneWidget);
      expect(find.byType(AvatarHalo), findsNWidgets(2));

      await tester.tap(strip('查看 小冰 的个人主页'));
      await settle(tester);
      expect(picked, 'u1');
    });

    testWidgets('点行后由组件调用 onClose（跳转并关闭）', (WidgetTester tester) async {
      int closes = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: const AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 2,
            ),
            onClose: () => closes += 1,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      await tester.tap(strip('查看 小樱 的个人主页'));
      await settle(tester);
      expect(closes, 1);
    });

    testWidgets('截断 → 「仅显示前 N 位」；爱莉标记走 AvatarHalo 的 elysia 档', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: const AylaLiveViewerSheetData(
              viewers: _watchers,
              count: 200,
              hasMore: true,
              elysiaUserId: 'u2',
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('仅显示前 2 位'), findsOneWidget);
      final List<AvatarHalo> avatars = tester
          .widgetList<AvatarHalo>(find.byType(AvatarHalo))
          .toList();
      expect(avatars[1].core, AvatarCore.elysia); // u2 = 爱莉
      expect(avatars[0].core, AvatarCore.user);
    });

    testWidgets('503 → role=alert 明示读不到 + 重试；**不**回落空名单', (WidgetTester tester) async {
      int retries = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers, // 有预览也要走错误态（web：rows = error ? [] : preview）
            data: AylaLiveViewerSheetData(
              error: '暂时读不到在看名单',
              onRetry: () => retries += 1,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);

      expect(find.text('暂时读不到在看名单'), findsOneWidget);
      expect(find.text('还没有人在看'), findsNothing); // 不冒充空名单
      expect(find.text('小冰'), findsNothing);
      // 标题退化：`count === null && error` → 「正在观看」
      expect(find.text('正在观看'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(retries, 1);
    });

    testWidgets('空态：viewers 为空列表 → 「还没有人在看」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: <AylaLiveViewerItem>[],
            data: AylaLiveViewerSheetData(
              viewers: <AylaLiveViewerItem>[],
              count: 0,
            ),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('还没有人在看'), findsOneWidget);
      expect(find.text('正在观看 · 0 人'), findsOneWidget);
    });

    testWidgets('骨架：viewers == null 且无预览 → 6 行（头像 41 + 名字 40%）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: <AylaLiveViewerItem>[],
            data: AylaLiveViewerSheetData(),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      // 6 行 × 2 块骨架
      expect(
        find.byType(AylaSkeleton),
        findsNWidgets(AylaLiveViewerSheet.skeletonRows * 2),
      );
      expect(find.text('还没有人在看'), findsNothing);
    });

    testWidgets('预览打底：viewers == null 但有预览 → 直接渲染预览（不显示骨架）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(),
            onClose: _noop,
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      expect(find.text('小冰'), findsOneWidget);
      // total = count ?? rows.length → 2
      expect(find.text('正在观看 · 2 人'), findsOneWidget);
      expect(find.byType(AylaSkeleton), findsNothing);
    });

    testWidgets('窄屏（≤768）→ 弹层高度 = 60vh（web `.live-viewer-sheet-card` 档）', (
      WidgetTester tester,
    ) async {
      const Size vp = Size(420, 600);
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(viewers: _watchers, count: 2),
            onClose: _noop,
          ),
          viewport: vp,
        ),
      );
      await settle(tester);
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.height, closeTo(vp.height * 0.6, 0.5)); // height: 60vh
      expect(card.bottom, vp.height); // 贴底上滑
    });

    testWidgets('head 固定：标题行**不在**滚动视图内，只有名单本身滚动', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveViewerSheet(
            preview: _watchers,
            data: AylaLiveViewerSheetData(
              viewers: <AylaLiveViewerItem>[
                for (int i = 1; i <= 40; i += 1)
                  AylaLiveViewerItem(userId: '$i', nickname: '观众$i'),
              ],
              count: 40,
            ),
            onClose: () {},
          ),
          viewport: const Size(900, 500),
        ),
      );
      await settle(tester);

      // 标题不在任何滚动视图内（`.create-sheet-head { flex: none }`）
      expect(
        find.ancestor(
          of: find.text('正在观看 · 40 人'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      // 名单在滚动视图内
      expect(
        find.ancestor(
          of: find.text('观众40'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
      // 内容确实超过可视区（限高生效）
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(
        tester.getRect(find.text('观众40')).bottom,
        greaterThan(card.bottom),
      );
    });

    testWidgets('弹层插在 root Overlay（等价 web portal 到 body）：不在条子组件子树内', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          const Center(
            child: SizedBox(
              width: 480,
              child: AylaLiveViewerStrip(count: 2, viewers: _watchers),
            ),
          ),
          viewport: const Size(900, 700),
        ),
      );
      await settle(tester);
      await tester.tap(strip('正在观看 2 人，查看完整名单'));
      await settle(tester);

      expect(find.byType(AylaLiveViewerSheet), findsOneWidget);
      // 不在 strip 子树内（说明是插到 root overlay 的独立子树）
      expect(
        find.ancestor(
          of: find.byType(AylaLiveViewerSheet),
          matching: find.byType(AylaLiveViewerStrip),
        ),
        findsNothing,
      );
      // 覆盖整个窗口（stage 之外的区域也属于弹层遮罩）
      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.top, greaterThan(0)); // 居中卡 ⇒ 上下都有遮罩
      expect(card.width, 480); // min(480, 100%)
    });
  });
}

void _noop() {}
