/// 窄屏 `/messages` 顶部选项卡**高亮迁移连续性**回归 —— 用户 2026-10-09 实报
/// 「私信卡切换到别的卡、别的卡切换到私信卡时高亮跳变」。
///
/// ## web 事实源（逐条）
/// - `MessagesPage.tsx:210–242`：三个 `.messages-tab` **各自**条件渲染
///   `{tab === "chat" && <AuroraquaNavHighlight id={selectionId} />}`，
///   三处共用**同一个** `useId()`（tsx:40）⇒ Framer 的 `layoutId` 共享布局动画
///   （`AuroraquaNavHighlight.tsx:17`）——同一个胶囊实体在两项之间**迁移**，
///   而不是各自重新出现。
/// - `auroraquaMotion.ts:26–29`：`auroraquaIndicatorTransition` =
///   `{ duration: 0.3, ease: [0, 0, 0.58, 1] }`（300ms / ease-out）。
/// - `auroraqua.css:175–185`：`.auroraqua-nav-highlight { position: absolute; inset: 0;
///   border-radius: inherit; background: var(--nav-active-bg); box-shadow: var(--glass-shadow-nav) }`
///   —— 几何全由宿主项决定，胶囊自身无尺寸。
/// - 三档 tab 的 DOM 结构完全相同（`MessagesPage.tsx:206–247`：`.messages-page` 的
///   第一子项恒为 tabs 包装行、第二子项恒为面板）⇒ **切 tab 不会重建 tabs 行**。
///
/// ## 口径（本测试锁什么）
/// Flutter 侧 tabs 行在窄屏的两个分支里处于**不同的树位置**（私信档 = `Column` 直接子项，
/// 好友/认证档 = `SingleChildScrollView > Column` 的子项）。若切换时 Element 被重建，
/// `AylaNavHighlightList` 的 State 归零 ⇒ `_capsuleRect == null` ⇒ **首帧胶囊直接消失**、
/// postFrame 后瞬现于新位置 = 跳变。
/// ⇒ 断言分三段：① 首帧胶囊**仍存在且仍在旧位置**（迁移起点）；② 中途落在两点之间
/// （真的在动，不是瞬移）；③ 300ms 后到达终点。三段合起来才锁得住「不是跳变」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/messages_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/primitives.dart' show AylaNavHighlight;

Widget _host(Widget child, Size viewport) => ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: previewScope(
              SizedBox(
                width: viewport.width,
                height: viewport.height,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _pump(
  WidgetTester tester, {
  Size viewport = const Size(420, 760),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(const MessagesPage(), viewport));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 走完一次完整的迁移（⚠️ 必须「先 `pump()` 起 tick、再 `pump(时长)`」——
/// 单发 `pump(350ms)` 里 controller 的 startTime 记在本帧，elapsed 恒为 0 ⇒
/// 动画停在起点，`before` 会量到**上一次**的位置。skill 已固化该坑）。
Future<void> _settleMigration(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('私信 → 好友：首帧胶囊仍在旧位（Element 不重建，迁移不中断）', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    final Finder capsule = find.byType(AylaNavHighlight);
    expect(capsule, findsOneWidget, reason: '私信档：容器级单实例胶囊');
    final Rect before = tester.getRect(capsule);

    await tester.tap(find.text('好友列表'));
    await tester.pump(); // 重建帧 = 300ms 迁移的起点

    // ★ 核心断言：State 若被重建，这一帧胶囊根本不画（`_capsuleRect == null`）。
    expect(
      capsule,
      findsOneWidget,
      reason: '★ 切 tab 后首帧胶囊必须已存在 —— 消失即 State 重建（跳变根因）',
    );
    expect(
      tester.getRect(capsule).left,
      moreOrLessEquals(before.left, epsilon: 0.5),
      reason: '★ 首帧必须停在旧位置（= 迁移起点）；直接出现在新位置就是用户实报的「跳变」',
    );

    // 中途：真的在迁移（`AnimatedPositioned` 300ms easeOut）
    await tester.pump(const Duration(milliseconds: 150));
    final double mid = tester.getRect(capsule).left;
    expect(mid, greaterThan(before.left), reason: '第三项在右侧 ⇒ left 单调增');

    // 终点
    await tester.pump(const Duration(milliseconds: 300));
    final double after = tester.getRect(capsule).left;
    expect(after, greaterThan(mid), reason: '300ms 后到达终点');
    expect(
      after,
      moreOrLessEquals(
        tester.getRect(find.text('好友列表')).center.dx -
            tester.getRect(capsule).width / 2,
        epsilon: 1.0,
      ),
      reason: '终点 = 「好友列表」项的矩形（胶囊 inset:0 于该项）',
    );
  });

  testWidgets('好友 → 私信：同一方向锁一遍（用户报的是双向跳变）', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('好友列表'));
    await _settleMigration(tester); // 让第一次迁移走完

    final Finder capsule = find.byType(AylaNavHighlight);
    final Rect before = tester.getRect(capsule);

    await tester.tap(find.text('私信'));
    await tester.pump();

    expect(capsule, findsOneWidget, reason: '★ 反向同样不得重建');
    expect(
      tester.getRect(capsule).left,
      moreOrLessEquals(before.left, epsilon: 0.5),
      reason: '★ 反向首帧仍停在旧位置',
    );

    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getRect(capsule).left,
      lessThan(before.left),
      reason: '私信在左侧 ⇒ left 单调减（真在迁移）',
    );
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('好友 ↔ 认证：同分支内切换照旧平滑（对照档，修复前也应为绿）', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('好友列表'));
    await _settleMigration(tester);

    final Finder capsule = find.byType(AylaNavHighlight);
    final Rect before = tester.getRect(capsule);

    await tester.tap(find.text('认证消息'));
    await tester.pump();

    expect(capsule, findsOneWidget);
    expect(
      tester.getRect(capsule).left,
      moreOrLessEquals(before.left, epsilon: 0.5),
      reason: '同分支内切换本来就不重建（对照：证明本测试量的确实是重建与否）',
    );
    await tester.pump(const Duration(milliseconds: 400));
  });
}
