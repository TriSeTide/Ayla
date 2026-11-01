/// 直播全屏「等比铺满 + 多余留黑」的回归锁（2026-11-01 用户实报两轮）。
///
/// ## 需求原文
/// 第一轮：「不要拉伸屏幕，要正常长宽比，多余的留黑」
/// 第二轮：「**还是有概率拉伸，你应该找到拉伸的代码级根因。直接把全屏播放器的
///          长宽比限死不就行了**」
///
/// ## 第一轮实现为什么会「有概率」拉伸（本轮修掉的两个代码级根因）
/// ① **比例来源不可靠**：旧实现「平台上报比例、报不出来就原样铺满」，而比例可能
///    晚于「进全屏」那一刻才上报（刚进房 / 播放器刚自愈重建）⇒ 那一次必然拉伸。
/// ② **overlay 子树是快照**（更致命的确定性缺陷）：`_toggleFullscreen` 把
///    `_buildFullscreen()` 的**结果** captured 进 `OverlayEntry.builder` 的闭包
///    ⇒ 全屏层永远渲染那份快照，State 再 setState 也不重建它 ⇒ 进全屏时比例若是 null，
///    **永远**停在拉伸态（换台 / 重连都不会自愈）。同一缺陷也让
///    `_controlsVisible` / `_spinning` 在全屏里冻结。
///
/// ## 修复后的契约（本文件锁这几条）
/// ① 比例**限死**：注入 null ⇒ 用 `kAylaLiveVideoAspectRatio`（16:9），不是「铺满」；
/// ② 注入真实比例 ⇒ 用它；非有限 / ≤0 ⇒ 退回 16:9（绝不产出 NaN 尺寸的盒子）；
/// ③ 全屏容器铺满整屏，画面在容器内保持 16:9 且**居中**（对称留黑）——
///    断言必须量**实际渲染框**，不能只断言 widget 存在；
/// ④ **比例的迟到不算事故**：先进全屏（比例 null）、后把比例喂进来 ⇒ 渲染框必须跟着变
///    （锁住「overlay 快照」那条根因）；
/// ⑤ 全屏里控件的 3s 自动隐藏也必须在进全屏**之后**仍然生效（同一根因的旁证）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart' show AylaSpacing;
import '../lib/widgets/live/live_player.dart';
import '../lib/widgets/live/video_contain.dart';

/// 视频替身：带独特类型，便于在渲染树里定位并量它的**实际渲染框**。
class _VideoProbe extends StatelessWidget {
  const _VideoProbe();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF224466));
}

void main() {
  Finder byLabel(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 把测试窗口调到指定尺寸（否则根约束恒为 flutter_test 默认的 800×600，
  /// 量出来的渲染框会被那个「虚拟屏幕」夹住，断言就变成假的）。
  void useViewport(WidgetTester tester, Size viewport) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 宿主：真实 `previewScope`（提供 Overlay / Material / 主题域）。
  Widget host(Widget child, Size viewport) {
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

  Future<void> enterFullscreen(WidgetTester tester) async {
    await tester.tap(find.byType(AylaLivePlayer), warnIfMissed: false);
    await tester.pump();
    await tester.tap(byLabel('全屏').first);
    await settle(tester);
  }

  group('AylaVideoContain（= object-fit: contain，比例限死）', () {
    testWidgets('16:9 兜底比例在 2.16:1 的屏上：高度顶满、宽度按比例、左右留黑', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);
      await tester.pumpWidget(
        host(
          const AylaVideoContain(
            aspectRatio: kAylaLiveVideoAspectRatio,
            child: _VideoProbe(),
          ),
          screen,
        ),
      );
      await settle(tester);

      final Rect box = tester.getRect(find.byType(_VideoProbe));
      expect(box.height, closeTo(screen.height, 0.01));
      expect(box.width, closeTo(screen.height * 16 / 9, 0.01));
      expect(box.width / box.height, closeTo(16 / 9, 1e-6));
      expect(box.left, closeTo((screen.width - box.width) / 2, 0.01));
    });

    testWidgets('4:3 画面在 2.16:1 的屏上：宽度顶满、上下留黑', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);
      await tester.pumpWidget(
        host(
          const AylaVideoContain(aspectRatio: 4 / 3, child: _VideoProbe()),
          screen,
        ),
      );
      await settle(tester);

      // 屏 2.16:1 比画面 1.33:1 **更宽** ⇒ contain 由**高度**顶满、两侧留黑
      // （写成「宽度顶满」等于没验证 contain，等于把拉伸当正确）
      final Rect box = tester.getRect(find.byType(_VideoProbe));
      expect(box.height, closeTo(screen.height, 0.01));
      expect(box.width, closeTo(screen.height * 4 / 3, 0.01));
      expect(box.width / box.height, closeTo(4 / 3, 1e-6));
      expect(box.left, closeTo((screen.width - box.width) / 2, 0.01));
    });

    testWidgets('非法比例（0 / 负数 / NaN / 无穷）⇒ 退回 16:9，绝不产出 NaN 盒子', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);
      for (final double bad in <double>[0, -1.5, double.nan, double.infinity]) {
        await tester.pumpWidget(
          host(
            AylaVideoContain(aspectRatio: bad, child: const _VideoProbe()),
            screen,
          ),
        );
        await settle(tester);
        final Rect box = tester.getRect(find.byType(_VideoProbe));
        expect(
          box.width / box.height,
          closeTo(16 / 9, 1e-6),
          reason: '非法比例必须退回 16:9，而不是铺满或 NaN',
        );
      }
    });
  });

  group('全屏里的播放器（真实 AylaLivePlayer + Overlay 宿主）', () {
    testWidgets('比例未知也能锁死：全屏画面 16:9 且居中（①③）', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);
      await tester.pumpWidget(
        host(
          const AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: _VideoProbe(),
            // 故意不注入比例：这正是「刚进房还没上报」的真实状态
          ),
          screen,
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(byLabel('退出全屏'), findsOneWidget);

      final Rect box = tester.getRect(find.byType(_VideoProbe));
      expect(
        box.width,
        closeTo(screen.height * 16 / 9, 0.01),
        reason: '比例未知时必须按 16:9 限死，而不是被拉伸到屏宽',
      );
      expect(box.width / box.height, closeTo(16 / 9, 1e-6));
      expect(box.center.dx, closeTo(screen.width / 2, 0.01));
      expect(box.center.dy, closeTo(screen.height / 2, 0.01));
    });

    testWidgets('比例的**迟到**要能生效（② 根因：overlay 子树曾是快照）', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);

      // ⚠️ 宿主必须与**生产同构**：比例是父级（`AylaLiveRoomBody` 拿到 session
      // 通知后）重新 build `AylaLivePlayer` 传进来的 ⇒ 用 StatefulWidget 改字段，
      // 不能用 `pumpWidget` 整体换一棵树（`previewScope` 的 `Overlay(initialEntries:)`
      // 在重建时会忽略新 entries，量出来的永远是旧条目 ⇒ 假失败）。
      final GlobalKey<_RatioHostState> hostKey = GlobalKey<_RatioHostState>();
      await tester.pumpWidget(
        host(
          _RatioHost(key: hostKey, initial: null, viewport: screen),
          screen,
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(
        tester.getRect(find.byType(_VideoProbe)).width,
        closeTo(screen.height * 16 / 9, 0.01),
      );

      // 播放器上报了真实比例（4:3）⇒ overlay 里那棵子树必须跟着重建
      hostKey.currentState!.setRatio(4 / 3);
      await settle(tester);
      await tester.pump();

      final Rect updated = tester.getRect(find.byType(_VideoProbe));
      expect(
        updated.width / updated.height,
        closeTo(4 / 3, 1e-6),
        reason: '进全屏之后才上报的比例也必须生效 —— 快照式 overlay 会让它永远停在 16:9',
      );
      expect(
        tester
            .widgetList<AylaVideoContain>(find.byType(AylaVideoContain))
            .map((AylaVideoContain w) => w.aspectRatio),
        contains(closeTo(4 / 3, 1e-6)),
        reason: '重建后的等比件必须拿到新比例，而不是进全屏那一刻的快照',
      );
    });

    testWidgets('全屏容器铺满整屏，且不再套 16:9 AspectRatio（web aspect-ratio: auto）', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(844, 390);
      useViewport(tester, screen);
      await tester.pumpWidget(
        host(
          const AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: _VideoProbe(),
          ),
          screen,
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);

      expect(
        find.ancestor(
          of: find.byType(_VideoProbe),
          matching: find.byType(AspectRatio),
        ),
        findsNothing,
        reason: '全屏档不得再套 16:9 AspectRatio（画面比例由 AylaVideoContain 负责）',
      );
      // 退出键贴的是**整屏**右上角（说明容器真的铺满，而不是被 16:9 收窄)  
      final Rect exitBtn = tester.getRect(byLabel('退出全屏'));
      expect(exitBtn.right, closeTo(screen.width - AylaSpacing.sp2, 0.5));
    });
  });

  group('⑤ 同一根因的旁证：全屏里的控件显隐也要跟着 State 变', () {
    testWidgets('进全屏后 3s 无操作 ⇒ 控件自动隐藏（快照式 overlay 会让它永不隐藏）', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(400, 800);
      useViewport(tester, screen);
      await tester.pumpWidget(
        host(
          const AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: _VideoProbe(),
          ),
          screen,
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);

      await tester.pump(kLivePlayerAutoHide + const Duration(milliseconds: 50));
      await tester.pump();

      final Iterable<AnimatedOpacity> fades =
          tester.widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(
        fades.any((AnimatedOpacity w) => w.opacity == 0),
        isTrue,
        reason: '3s 无操作后控件层必须 opacity:0（快照式 overlay 会永远停在 opacity:1）',
      );
    });
  });
}

/// 与生产同构的宿主：比例变化来自**父级 rebuild**（不是换整棵树）。
class _RatioHost extends StatefulWidget {
  const _RatioHost({
    super.key,
    required this.initial,
    required this.viewport,
  });

  final double? initial;
  final Size viewport;

  @override
  State<_RatioHost> createState() => _RatioHostState();
}

class _RatioHostState extends State<_RatioHost> {
  late double? _ratio = widget.initial;

  /// 模拟「播放器上报了真实比例」。
  void setRatio(double? ratio) => setState(() => _ratio = ratio);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: widget.viewport,
        child: AylaLivePlayer(
          srsStatus: AylaLiveSrsStatus.live,
          videoView: const _VideoProbe(),
          videoAspectRatio: _ratio,
        ),
      ),
    );
  }
}
