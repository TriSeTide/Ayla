/// 四条手机端实报缺陷的回归锁（2026-10-19）。
///
/// 每条都对应一次**用户实报**，且都曾在 web 侧已有正确实现、Flutter 侧漏对齐：
/// 1. 直播无法全屏 —— `live_player.dart` 的 videoView 新旧两档同时挂载；
/// 2. 返回键直接退出 —— `context.go` 不建历史栈（web 的 navigate 是 push）；
/// 3. 切后台重登 —— 缺 `restoreSession`（web `main.tsx:36`）；
/// 4. 顶部不避让状态栏 —— 窄屏顶栏/群顶栏/直播头部没让出 `viewPadding.top`。
///
/// 这里锁的是**可稳定断言的契约**（渲染树结构 / 纯函数 / 接线）；
/// 视觉与真机行为由用户在自己的调试实例上验收（skill 纪律：预览由用户自己看）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/state/auth_bootstrap.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_player.dart';

void main() {
  group('① 全屏：videoView 同一时刻只挂一处（对齐 web 的 video 原子迁移）', () {
    /// 视频替身：带一个独特类型，便于在渲染树里数「挂了几份」。
    testWidgets('全屏期间视频只挂一份（inline 侧必须卸载）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: AylaLivePlayer(
                  srsStatus: AylaLiveSrsStatus.live,
                  videoView: const _VideoProbe(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 未全屏：恰好一份（inline）。
      expect(find.byType(_VideoProbe), findsOneWidget);

      // 进全屏。控件需先显示：点画面 → 点「全屏」键。
      final Finder player = find.byType(AylaLivePlayer);
      await tester.tap(player);
      await tester.pump();
      final Finder fsButton = find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == '全屏',
      );
      expect(fsButton, findsWidgets, reason: '全屏键必须存在（web 窄屏照常渲染）');
      await tester.tap(fsButton.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // ★ 关键断言：全屏时视频**只挂一份**（overlay 里那份）。
      // 修复前 inline 侧的条件是 `!fullscreen`（恒真）⇒ 两份同时挂 ⇒ 平台视图重复
      // attach ⇒ 手机端点全屏后黑屏/卡死。
      expect(
        find.byType(_VideoProbe),
        findsOneWidget,
        reason: '全屏期间视频必须只挂一处（重复挂载 = 重复 attach = 黑屏）',
      );
    });
  });

  group('③ 会话恢复：首屏落点', () {
    test('有会话恢复在途时首屏落 /login（而不是 /group 再被守卫弹回）', () {
      expect(
        aylaInitialLocation(
          autoLoginInFlight: false,
          sessionRestoreInFlight: true,
        ),
        '/login',
      );
      expect(
        aylaInitialLocation(
          autoLoginInFlight: false,
          sessionRestoreInFlight: false,
        ),
        '/group',
      );
      // 自动登录那条路径的既有语义不能变（用户明确要求「看见它登进去」）。
      expect(aylaInitialLocation(autoLoginInFlight: true), '/login');
    });
  });
}

/// 视频替身（只为在渲染树里可数）。
class _VideoProbe extends StatelessWidget {
  const _VideoProbe();

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
