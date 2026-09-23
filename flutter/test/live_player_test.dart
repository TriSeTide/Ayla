/// B2-6：播放器（`LivePlayer.tsx` 420）+ 浮动小窗（`LiveMiniPlayer.tsx` 228）定向测试。
///
/// 覆盖：三态占位文案与颜色 / 播放失败的重试 / 悬浮控件的显隐与 3s 自动隐藏 / 刷新旋转 /
/// 全屏（root overlay + 回调）/ 小窗默认位置与尺寸 / 关闭键在小窗外的位置 / 拖动阈值与点击抑制 /
/// 键盘可达。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart' show GlassButton, GlassButtonVariant;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live_mini_player.dart';
import '../lib/widgets/live_player.dart';
import '../lib/widgets/overlays.dart';

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(640, 480),
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

  Finder byLabel(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('AylaLivePlayer 三态（tsx 331–363 + app.css 3535–3553）', () {
    testWidgets('srsStatus == null → 「正在查询直播状态…」（secondary）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const SizedBox(width: 320, child: AylaLivePlayer()),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      expect(find.text('正在查询直播状态…'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('正在查询直播状态…')).style?.color,
        AylaColors.textSecondary,
      );
    });

    testWidgets('degraded → 「直播服务状态未知，请稍后再试」且色为 --warning', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const SizedBox(
            width: 320,
            child: AylaLivePlayer(srsStatus: AylaLiveSrsStatus.degraded),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      expect(find.text('直播服务状态未知，请稍后再试'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('直播服务状态未知，请稍后再试')).style?.color,
        AylaColors.warning,
      );
    });

    testWidgets('idle → 「主播未开播」；乐观已开播 → 「等待推流信号…」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const SizedBox(
            width: 320,
            child: AylaLivePlayer(srsStatus: AylaLiveSrsStatus.idle),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      expect(find.text('主播未开播'), findsOneWidget);
    });

    testWidgets('idle + optimistic live → 「等待推流信号…」（tsx 344）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const SizedBox(
            width: 320,
            child: AylaLivePlayer(
              srsStatus: AylaLiveSrsStatus.idle,
              optimisticStatus: AylaLiveStatus.live,
            ),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      expect(find.text('等待推流信号…'), findsOneWidget);
    });

    testWidgets('live + playerError → 「播放失败」(destructive) + `.btn-glow`「重试」', (
      WidgetTester tester,
    ) async {
      int retries = 0;
      await tester.pumpWidget(
        host(
          tester,
          SizedBox(
            width: 320,
            child: AylaLivePlayer(
              srsStatus: AylaLiveSrsStatus.live,
              playerError: 'boom',
              onRetry: () => retries += 1,
            ),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      expect(find.text('播放失败'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('播放失败')).style?.color,
        AylaColors.destructive,
      );
      final GlassButton retry = tester.widget<GlassButton>(
        find.byWidgetPredicate((Widget w) => w is GlassButton && w.label == '重试'),
      );
      expect(retry.variant, GlassButtonVariant.glow);
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(retries, 1);
    });
  });

  group('AylaLivePlayer 悬浮控件（tsx 186/365–418 + app.css 3557–3615）', () {
    testWidgets('live：初始控件不可见 → 点画面显示 → 3s 无操作自动隐藏', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const SizedBox(
            width: 320,
            child: AylaLivePlayer(srsStatus: AylaLiveSrsStatus.live),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);

      AnimatedOpacity layer() => tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first,
      );
      expect(layer().opacity, 0); // 非常态显示

      await tester.tap(find.byType(AylaLivePlayer));
      await tester.pump();
      expect(layer().opacity, 1);

      // AUTO_HIDE_MS = 3000（tsx 24）
      await tester.pump(kLivePlayerAutoHide);
      await tester.pump();
      expect(layer().opacity, 0);
      expect(kLivePlayerAutoHide, const Duration(milliseconds: 3000));
    });

    testWidgets('刷新键 → onRefresh 被调用并进入旋转态（0.65s 后复位）', (WidgetTester tester) async {
      int refreshes = 0;
      await tester.pumpWidget(
        host(
          tester,
          SizedBox(
            width: 320,
            child: AylaLivePlayer(
              srsStatus: AylaLiveSrsStatus.live,
              onRefresh: () => refreshes += 1,
            ),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer)); // 显示控件
      await tester.pump();

      await tester.tap(byLabel('跳到最新画面'));
      await tester.pump();
      expect(refreshes, 1);
      // 旋转中：存在旋转包装（TweenAnimationBuilder → Transform.rotate）
      expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
      await tester.pump(kLivePlayerSpinReset);
      await tester.pump();
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    });

    testWidgets('全屏：插 root overlay + onFullscreenChanged(true/false)，退出后移除', (
      WidgetTester tester,
    ) async {
      final List<bool> events = <bool>[];
      OverlayEntry? captured;
      await tester.pumpWidget(
        host(
          tester,
          SizedBox(
            width: 320,
            child: AylaLivePlayer(
              srsStatus: AylaLiveSrsStatus.live,
              onFullscreenChanged: events.add,
              overlayHostBuilder: (Widget child) =>
                  captured = aylaOverlayEntry(builder: (BuildContext ctx) => child),
            ),
          ),
          viewport: const Size(400, 300),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer));
      await tester.pump();

      await tester.tap(byLabel('全屏'));
      await settle(tester);
      expect(events, <bool>[true]);
      expect(captured, isNotNull);

      await tester.tap(byLabel('退出全屏'));
      await settle(tester);
      expect(events, <bool>[true, false]);
    });
  });

  group('AylaLiveMiniPlayer（tsx 228 + live.css 1021–1095）', () {
    testWidgets('默认位置右下 16、尺寸 168×94（16:9）；关闭键在小窗右上角**外侧**', (
      WidgetTester tester,
    ) async {
      const Size vp = Size(420, 700);
      await tester.pumpWidget(
        host(
          tester,
          const Stack(
            children: <Widget>[
              AylaLiveMiniPlayer(channelTitle: '深夜电台', videoView: const SizedBox()),
            ],
          ),
          viewport: vp,
        ),
      );
      await settle(tester);

      final Rect mini = tester.getRect(find.byType(AylaLiveMiniPlayer));
      expect(mini.width, kLiveMiniWidth);
      expect(mini.height, kLiveMiniHeight);
      expect(mini.right, vp.width - 16); // right: 16px
      expect(mini.bottom, vp.height - 16); // bottom: 16px
      // 关闭键 top/right = -10 ⇒ 其右缘超出生小窗右缘 10px
      final Rect close = tester.getRect(byLabel('关闭小窗'));
      expect(close.right, greaterThan(mini.right), reason: 'mini=$mini close=$close');
      expect(close.top, lessThan(mini.top), reason: 'mini=$mini close=$close');
      expect(close.width, 24);
    });

    testWidgets('小位移（< 阈值 5）仍是点击 → onOpenRoom；点关闭键 → onClose 且不触发回房', (
      WidgetTester tester,
    ) async {
      int opens = 0;
      int closes = 0;
      await tester.pumpWidget(
        host(
          tester,
          Stack(
            children: <Widget>[
              AylaLiveMiniPlayer(
                videoView: const SizedBox(),
                onOpenRoom: () => opens += 1,
                onClose: () => closes += 1,
              ),
            ],
          ),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(AylaLiveMiniPlayer));
      await settle(tester);
      expect(opens, 1);

      await tester.tap(byLabel('关闭小窗'));
      await settle(tester);
      expect(closes, 1);
      expect(opens, 1, reason: '关闭键是独立点击目标（tsx 219–222 stopPropagation）');
    });

    testWidgets('拖动超阈值 → 位置改变且随后的点击被抑制；再点一次才回房', (WidgetTester tester) async {
      int opens = 0;
      await tester.pumpWidget(
        host(
          tester,
          Stack(
            children: <Widget>[
              AylaLiveMiniPlayer(videoView: const SizedBox(), onOpenRoom: () => opens += 1),
            ],
          ),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);
      final Rect before = tester.getRect(find.byType(AylaLiveMiniPlayer));

      // 拖动 100×-100（超阈值 5）
      final TestGesture gesture = await tester.startGesture(before.center);
      await tester.pump();
      for (int i = 0; i < 10; i += 1) {
        await gesture.moveBy(const Offset(-10, -10));
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      final Rect after = tester.getRect(find.byType(AylaLiveMiniPlayer));
      expect(after.left, lessThan(before.left));
      expect(after.top, lessThan(before.top));
      expect(opens, 0, reason: '拖动结束的合成 click 只消费抑制标记（tsx 182–186）');

      await tester.tap(find.byType(AylaLiveMiniPlayer));
      await settle(tester);
      expect(opens, 1);
    });

    testWidgets('拖动被 clamp 在视口内（边缘最小间距 8）', (WidgetTester tester) async {
      const Size vp = Size(420, 700);
      await tester.pumpWidget(
        host(
          tester,
          const Stack(children: <Widget>[AylaLiveMiniPlayer(videoView: SizedBox())]),
          viewport: vp,
        ),
      );
      await settle(tester);
      final Rect before = tester.getRect(find.byType(AylaLiveMiniPlayer));

      final TestGesture gesture = await tester.startGesture(before.center);
      await tester.pump();
      for (int i = 0; i < 20; i += 1) {
        await gesture.moveBy(const Offset(-100, -100));
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      final Rect after = tester.getRect(find.byType(AylaLiveMiniPlayer));
      expect(after.left, kLiveMiniDragMargin);
      expect(after.top, kLiveMiniDragMargin);
    });
  });
}
