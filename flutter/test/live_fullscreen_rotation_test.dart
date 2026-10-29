/// 手机端直播全屏的回归锁（2026-10 用户实报「点全屏后横屏显示直播间页面，随后回竖屏」）。
///
/// ## 两个根因（本文件分别锁死）
/// ① `live_room_page.dart` 旧写法 `narrow ? AylaFullScreenSwipeBack(...) : body` ——
///    点全屏会锁横屏 ⇒ 宽 > 768 ⇒ `narrow` 翻转 ⇒ 三元返回**类型不同的 Widget**
///    ⇒ 整棵 subtree 销毁重建；
/// ② `gestures.dart` 的 `AylaFullScreenSwipeBack.build` 旧写法
///    `if (!on) return content; return GestureDetector(...)` —— 即使页面改成「恒包一层」，
///    组件自身在 `enabled` 翻转时**返回类型也变了** ⇒ 子树照样被销毁。
///
/// 销毁的后果：`_AylaLivePlayerState.dispose` 跑 `_fsEntry.remove()` +
/// `_unlockOrientation()` ⇒ 全屏层消失 + 屏幕解锁回竖屏 = 用户看到的现象。
///
/// ## 宿主形状沿用 `live_player_test.dart` 的既有写法
/// `previewScope` + `MediaQuery.copyWith(size:)` + `SizedBox.fromSize` —— 该宿主已被
/// 12 个既有播放器用例验证可用（它同时提供 Overlay / Material / 主题域）。
/// 不用 `MaterialApp`：`AylaLivePlayer` 的全屏层插进**最近 Overlay**，
/// 而 MaterialApp 会让 Overlay 归属 Navigator，跨出本测试要控制的那层作用域。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_player.dart' show AylaLivePlayer, AylaLiveSrsStatus;
import '../lib/widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;

/// 生产形状（与修好后的 `live_room_page.dart` 同构）：**恒包一层 + `enabled` 开关**。
class _PageShape extends StatelessWidget {
  const _PageShape();

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    return AylaFullScreenSwipeBack(
      enabled: narrow,
      onBack: () {},
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            flat: narrow,
            videoView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      ),
    );
  }
}

Widget _host(Widget child, Size viewport) {
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

void main() {
  Finder byLabel(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openFullscreen(WidgetTester tester) async {
    await tester.tap(find.byType(AylaLivePlayer), warnIfMissed: false);
    await tester.pump();
    await tester.tap(byLabel('全屏'));
    await settle(tester);
  }

  testWidgets('点全屏后旋转（窄→宽）：State 复用 + 全屏层存活（根因 ①+②）', (
    WidgetTester tester,
  ) async {
    const Size portrait = Size(390, 844);
    const Size landscape = Size(844, 390);
    tester.view.physicalSize = portrait;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const _PageShape(), portrait));
    await settle(tester);

    final State<AylaLivePlayer> playerBefore =
        tester.state(find.byType(AylaLivePlayer));

    await openFullscreen(tester);
    expect(byLabel('退出全屏'), findsOneWidget, reason: '点全屏后必须出现全屏宿主');

    // ---- 模拟系统旋转（MediaQuery 尺寸变化，Element 树保持）----
    tester.view.physicalSize = landscape;
    await tester.pumpWidget(_host(const _PageShape(), landscape));
    await settle(tester);

    expect(
      identical(tester.state(find.byType(AylaLivePlayer)), playerBefore),
      isTrue,
      reason: '旋转不得重建 AylaLivePlayer —— 其 dispose 会摘掉全屏层并解锁竖屏',
    );
    expect(
      byLabel('退出全屏'),
      findsOneWidget,
      reason: '旋转后全屏层必须仍在（否则用户看到「横屏显示直播间页面」）',
    );
  });

  testWidgets('全屏中按 ESC 退出（DismissIntent）', (WidgetTester tester) async {
    const Size portrait = Size(390, 844);
    tester.view.physicalSize = portrait;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const _PageShape(), portrait));
    await settle(tester);
    await openFullscreen(tester);
    expect(byLabel('退出全屏'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(byLabel('退出全屏'), findsNothing, reason: 'ESC 必须退出全屏');
  });

  testWidgets('AylaFullScreenSwipeBack 在 enabled 两档返回同一 widget 类型（根因 ②）', (
    WidgetTester tester,
  ) async {
    int disposed = 0;
    Widget page(bool narrow) =>
        AylaFullScreenSwipeBack(
          enabled: narrow,
          onBack: () {},
          child: _DisposeProbe(onDispose: () => disposed += 1),
        );

    await tester.pumpWidget(MaterialApp(home: page(true)));
    await tester.pump();
    final State<_DisposeProbe> s1 = tester.state(find.byType(_DisposeProbe));
    expect(disposed, 0);

    await tester.pumpWidget(MaterialApp(home: page(false)));
    await tester.pump();
    final State<_DisposeProbe> s2 = tester.state(find.byType(_DisposeProbe));

    expect(disposed, 0, reason: 'enabled 翻转不得销毁子树的 State');
    expect(
      identical(s1, s2),
      isTrue,
      reason: '组件在 enabled 两档必须返回同一种 widget 类型',
    );
  });
}

class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(child: Text('probe'));
}
