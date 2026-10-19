/// 壳层顶部安全区兜底 + 加载转圈循环 的回归锁（2026-10-19 第二批实报）。
///
/// 用户实报：
/// 1. 「还有很多页面顶栏没有退避任务栏」—— 不能逐页补（会漏），必须壳层唯一 owner；
/// 2. 「加载的转圈圈转了一圈就停了」—— TweenAnimationBuilder 只播一次。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/router/shell_config.dart';
import '../lib/widgets/base/loading.dart';

void main() {
  group('① 壳层顶部安全区兜底：判定面覆盖所有「页面自己顶到屏幕最上」的路由', () {
    /// 这些路由**不出壳层顶栏**（`aylaIsNarrowTopBarRoute` 为 false）⇒ 必须由壳层补
    /// 状态栏留白，否则页面自绘的头部会被状态栏压住。
    const List<String> selfDrawnTopRoutes = <String>[
      '/posts/123', //        帖子详情（AylaPostDetailChrome）
      '/chat/c1', //          私聊（AylaPrivateChatPane 自绘头部）
      '/voice/7', //          语音房（AylaVoiceRoomBody 自绘头部）
      '/games/9', //          桌游房（AylaGameRoomPlaceholder 自绘头部）
      '/profile', //          个人主页（AylaProfileCard 自绘头部）
      '/user/u1', //          他人主页
      '/user/u1/posts', //    他人帖子
      '/group/g1', //         群聊（AylaGroupTopTabs 自绘头部）
      '/group/g1/posts', //   群内帖子
      '/group/g1/voice/7', // 群内语音
      '/group/g1/info', //    群信息
      '/live/start/1', //     开播控制台（自绘头部）
    ];

    test('这些路由在窄屏都不出壳层顶栏（⇒ 壳层必须兜底）', () {
      for (final String route in selfDrawnTopRoutes) {
        expect(
          aylaIsNarrowTopBarRoute(route),
          isFalse,
          reason: '$route 不应渲染壳层顶栏（页面自己画）',
        );
      }
    });

    test('出壳层顶栏的一级页：不应再被兜底（否则双倍留白）', () {
      for (final String route in <String>[
        '/group',
        '/voice',
        '/live',
        '/posts',
        '/games',
        '/messages',
        '/search',
        '/favorites',
      ]) {
        expect(
          aylaIsNarrowTopBarRoute(route),
          isTrue,
          reason: '$route 有壳层顶栏 ⇒ 壳层不再补留白',
        );
      }
    });
  });

  group('② 加载转圈必须无限循环（不是只转一圈）', () {
    testWidgets('转圈持续旋转：跨多圈仍有新帧', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: AylaLoadingSpinner())),
      );
      await tester.pump();

      // 判据：**动画是否仍在请求新帧**。
      // · 无限循环（AnimationController.repeat）⇒ 每一帧结束后都继续排下一帧；
      // · 单次动画（TweenAnimationBuilder 播完）⇒ 停止排帧，`hasScheduledFrame` 为 false。
      // 这正是「转一圈就停」与「一直转」的本质差异，且不依赖私有字段。
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.binding.hasScheduledFrame,
          isTrue,
          reason: '第 $i 次 pump 后动画已停止排帧 —— 转圈不是无限循环',
        );
      }
      // 累计 3s > 800ms 的 3 圈，仍在转 ⇒ 确认 repeat 生效。
    });

    testWidgets('reduced-motion 下不旋转（保持静态标识）', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(home: Center(child: AylaLoadingSpinner())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'reduced-motion 档不应有持续动画（base.css 的 reduced-motion 语义）',
      );
    });
  });
}
