/// 主页群卡片「状态轮播」在**切页返回后**是否继续滚动 —— 用户 2026-10 实报回归锁。
///
/// 用户原话：「主页群聊列表的轮播图，刚进入 app 的时候是正常的，但是切换其他页面
/// 再切换回主页群聊就不再滚动了」。
///
/// ## 为什么必须走**真实路由 + 真壳层**
/// 该缺陷只在「离开路由 → 回来」这条路径上出现（首次进入正常）。组件单测自己
/// `pumpWidget` 一个 `AylaGroupCarousel` 永远量不到它 —— 与 skill 里登记过的
/// 「参数注入型组件必须查调用点」「验证必须走真实交互路径」同一类教训。
///
/// ## 判据
/// 轮播当前页 = 指示点里唯一那个 `--glow-500` 的点（`home.css 483–503`）。
/// 首次进入应当每 3s 前进一格；切页返回后**同样**应当继续前进。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart';
import '../lib/core/models/conversation.dart';
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/social_store.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;

AylaDirectoryPage<Object> _emptyPage() => const AylaDirectoryPage<Object>();

AylaConversationSummary _group(String id) => AylaConversationSummary(
      id: id,
      type: AylaConversationType.group,
      title: '群 $id',
      // 轮播第一张（消息+语音合卡）的条件：有未读消息（`groupActivity.ts:300–398`）。
      unreadCount: 3,
    );

AylaDirectoryLiveEntry _live(String id) => AylaDirectoryLiveEntry(
      card: AylaLiveCardData(
        id: id,
        title: '直播 $id',
        status: AylaLiveStatus.live,
        ownerNickname: '小樱',
      ),
      allowedGroupIds: const <String>['g1'],
    );

/// 真实主题 + 真实路由 + 真实壳层的宿主（口径同 `group_home_fixes_test.dart`）。
Future<GoRouter> _pumpApp(WidgetTester tester) async {
  const Size size = Size(420, 900); // 窄屏（≤768）才有群卡片列表形态
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
  final GoRouter router = container.read(appRouterProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ),
    ),
  );
  return router;
}

/// 让页面数据/入场动画走完（**不能用 pumpAndSettle**：轮播的节拍器是无限循环的）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 当前轮播到第几张 = 指示点里颜色为 `--glow-500` 的那个下标。
int _activeDot(WidgetTester tester) {
  final List<Container> dots = tester
      .widgetList<Container>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints == const BoxConstraints.tightFor(width: 4, height: 4) &&
              w.decoration is BoxDecoration,
        ),
      )
      .toList();
  expect(dots.length, 2, reason: '本用例喂了 2 张轮播卡（消息 + 直播）');
  for (int i = 0; i < dots.length; i += 1) {
    final BoxDecoration d = dots[i].decoration! as BoxDecoration;
    if (d.color == AylaColors.glow500) return i;
  }
  return -1;
}

/// 推进 [ms] 毫秒并让 setState 落地（先跳时间、再走一帧重建）。
Future<void> _advance(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  await tester.pump();
}

void main() {
  setUp(() {
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = 'u1';
    // 一个群 + 一条在播直播 ⇒ 该群卡片有 2 张轮播卡（消息 / 直播）。
    aylaSocialStore.requestOverride = (
      AylaSocialKind kind,
      AylaSocialOptions options,
      String? cursor,
    ) async =>
        kind == AylaSocialKind.conversations
            ? AylaDirectoryPage<Object>(results: <Object>[_group('g1')])
            : _emptyPage();
    aylaDirectoryStore.requestOverride = (
      AylaDirectoryKind kind,
      AylaDirectoryOptions options,
      String? cursor,
    ) async =>
        kind == AylaDirectoryKind.live
            ? AylaDirectoryPage<Object>(results: <Object>[_live('l1')])
            : _emptyPage();
  });

  tearDown(() {
    aylaSocialStore.requestOverride = null;
    aylaDirectoryStore.requestOverride = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = null;
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = null;
  });

  testWidgets('进视口即转；切到其它页面再回来**仍然转**', (WidgetTester tester) async {
    final GoRouter router = await _pumpApp(tester);
    await _settle(tester);

    expect(find.byType(Scaffold), findsWidgets);
    expect(_activeDot(tester), 0, reason: '首帧停在第 0 张');

    // ---- 首次进入：正常滚动（用户口中的「刚进入 app 的时候是正常的」）----
    await _advance(tester, 3100);
    expect(_activeDot(tester), 1, reason: '首次进入 3s 后应滑到第 2 张');
    await _advance(tester, 3100);
    expect(_activeDot(tester), 0, reason: '再过 3s 应回到第 1 张');

    // ---- 切到其它一级页，再切回主页（用户实报的路径）----
    router.go('/live');
    await _settle(tester);
    router.go('/group');
    await _settle(tester);

    // 回来时引擎停在哪一张不重要；重要的是**再等 3s 必须动**。
    final int before = _activeDot(tester);
    await _advance(tester, 3100);
    expect(
      _activeDot(tester),
      isNot(before),
      reason: '切页返回后轮播必须继续滚动（用户实报：回来后不再滚动）',
    );
  });
}
