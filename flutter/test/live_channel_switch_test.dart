/// 侧栏切台回归锁 —— 用户实报「Flutter 直播界面侧栏切换直播间跳变」（2026-11-02）。
///
/// ## 缺陷（修前必红）
/// 侧栏切台走 `context.replace('/live/:id')`（= web `navigate(replace)`），而 Flutter 侧
/// 路由的 Page key 取自**路径**（`app_router.dart` 的 `aylaRoutePage`）⇒ `/live/1 → /live/2`
/// 换了 `ValueKey` ⇒ Navigator 的 `Page.canUpdate` 判假 ⇒ **整条 route 被替换**：
///
/// | 被重建的东西 | 用户看到的 |
/// |---|---|
/// | `LiveRoomPage` / `LiveStudioPage` 的 State | 会话、侧栏分页、名单弹层缓存全部归零 |
/// | `AylaLiveChannelRail` 的 State | 选中高亮 `_highlightRect` 丢失 ⇒ 先消失一帧再瞬现 |
/// | `AylaLivePlayer`（平台视图） | 销毁重建 ⇒ 黑屏 / 重新起播 |
/// | `_LiveRoomHeaderSwap` + `AylaRevealScope(replayKey:)` | 切台动效退化成整页重建 |
///
/// ## web 事实源
/// `components/motion/PageTransition.tsx:37–67` 的 `resolvePageKey`：
/// `/live/:id → "/live/room"`（tsx 63）、`/live/start/:channelId → "/live/start"`（tsx 65）
/// ⇒ React 按组件类型复用同一个页面实例，**只更新 `useParams().channelId`**；
/// tsx 43–51 的注释写明理由（「避免直播间切换触发整页重挂载（底栏滑出动画复位）」，
/// 以及开播台不归一会被旧页 cleanup 清掉新页会话的 2026-09-06 事故）。
///
/// ## 本文件锁什么
/// 1. **路由层**：页面路径判定 + Page key 归一（纯函数级 + 真实 GoRouter 级）；
/// 2. **页面层**：切台后页面 State **identity 不变**（同一个实例被复用）——
///    这是「不跳变」的定义式断言，修前 `identical == false`；
/// 3. **侧栏层**：切台后 `AylaLiveChannelRail` 的 State identity 也不变（高亮迁移不断链）；
/// 4. **反向**：进 / 出直播间仍必须换实例（归一不得把 `/live` 一并吃掉）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/pages/live_room_page.dart';
import '../lib/pages/live_studio_page.dart';
import '../lib/router/app_router.dart';
import '../lib/router/shell_config.dart';
import '../lib/core/api/live_api.dart' show AylaLiveDanmaku;
import '../lib/state/auth_state.dart';
import '../lib/state/live_state.dart' show AylaLiveState;
import '../lib/state/room_providers.dart' show liveStateProvider;
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;
import '../lib/widgets/live/live_room_body.dart' show AylaLiveRoomBody;
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/live/live_rail.dart' show AylaLiveChannelRail;

/// 启动**真实路由表**（登录态注入 = `router_test` / `group_page_shell_test` 同款）。
///
/// ⚠️ 必须钉真实表面尺寸：断点读 `MediaQuery`、布局宽来自测试表面，两件事都要钉。
/// 最近一次 [_pumpApp] 用的 ProviderContainer（供用例直接改 store 造真实态）。
ProviderContainer? _lastContainer;

/// 取当前用例的容器（= [AylaLiveState] 的唯一 owner）。
AylaLiveState containerOf(WidgetTester tester) {
  final ProviderContainer container = _lastContainer!;
  return container.read(liveStateProvider);
}

Future<GoRouter> _pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final ProviderContainer container = ProviderContainer();
  _lastContainer = container;
  addTearDown(() {
    _lastContainer = null;
    container.dispose();
  });
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
  final GoRouter router = container.read(appRouterProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        // 必须真实主题：默认主题的平台转场会与库内转场叠加（见 `router_test` 头注）。
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// 从页面 Element 出发做一次 `replace`（= 侧栏 `_goTo` 的真实调用面）。
void _goReplace(Element anchor, String location) {
  GoRouter.of(anchor).replace(location);
}

void main() {
  group('路由层：页面身份归一（web resolvePageKey tsx:37–67）', () {
    test('直播间 / 开播台的路径判定互不干扰', () {
      // 观看页：只认 /live/:channelId
      expect(aylaIsLiveRoomPagePath('/live/1'), isTrue);
      expect(aylaIsLiveRoomPagePath('/live/2'), isTrue);
      expect(aylaIsLiveRoomPagePath('/live/start/1'), isFalse,
          reason: '/live/start/:id 是 3 段，不得被当成观看页');
      expect(aylaIsLiveRoomPagePath('/live'), isFalse);
      // 开播台：只认 /live/start/:channelId
      expect(aylaIsLiveStudioPagePath('/live/start/1'), isTrue);
      expect(aylaIsLiveStudioPagePath('/live/1'), isFalse);
      // 合成的旧语义（壳层沉浸路由）两者都认
      expect(aylaIsLiveRoomRoute('/live/1'), isTrue);
      expect(aylaIsLiveRoomRoute('/live/start/1'), isTrue);
    });

    testWidgets('/live/:id 之间 = 同一个 Page（Navigator 的 pages 末项 key 不变）',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();

      List<Page<Object?>> pages() =>
          tester.widget<Navigator>(find.byType(Navigator).first).pages;

      final List<Element> before = find.byType(LiveRoomPage).evaluate().toList();
      expect(before, hasLength(1));
      final Key? keyBefore = pages().last.key;
      expect(keyBefore, isNotNull);

      _goReplace(before.first, '/live/2');
      await tester.pump();

      expect(find.byType(LiveRoomPage), findsOneWidget);
      // 归一的判据就在 Page 上：末项 key 相同 ⇒ `Page.canUpdate` 为真 ⇒ 复用 route。
      expect(
        pages().last.key,
        keyBefore,
        reason: 'Page key 必须归一（否则 /live/1 → /live/2 会整条 route 被替换）',
      );
      await tester.pumpAndSettle();
    });
  });

  group('页面层：切台不得重建页面（实报「跳变」的定义式断言）', () {
    testWidgets('LiveRoomPage：/live/1 → /live/2 State identity 不变',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();

      final Finder pageFinder = find.byType(LiveRoomPage);
      expect(pageFinder, findsOneWidget);
      final State<LiveRoomPage> stateBefore =
          tester.state<State<LiveRoomPage>>(pageFinder);
      final Element elementBefore = pageFinder.evaluate().single;

      _goReplace(elementBefore, '/live/2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final State<LiveRoomPage> stateAfter =
          tester.state<State<LiveRoomPage>>(pageFinder);
      expect(
        identical(stateBefore, stateAfter),
        isTrue,
        reason: '切台必须复用同一个 State（整页重建 = 用户看到的「跳变」）',
      );
      expect(
        identical(elementBefore, pageFinder.evaluate().single),
        isTrue,
        reason: 'Element 也不得重建（否则整棵子树重挂、播放器销毁重建）',
      );
      // 新 channelId 真的传进来了（复用 ≠ 不更新）
      expect((stateAfter.widget as LiveRoomPage).channelId, '2');
      await tester.pumpAndSettle();
    });

    testWidgets('LiveRoomPage：切台后侧栏 AylaLiveChannelRail State identity 不变（高亮迁移不断链）',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();

      final Finder railFinder = find.byType(AylaLiveChannelRail);
      expect(railFinder, findsOneWidget,
          reason: '宽屏观看态必须有侧栏（本用例的前提）');
      final State<AylaLiveChannelRail> railBefore =
          tester.state<State<AylaLiveChannelRail>>(railFinder);

      _goReplace(find.byType(LiveRoomPage).evaluate().single, '/live/2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final State<AylaLiveChannelRail> railAfter =
          tester.state<State<AylaLiveChannelRail>>(railFinder);
      expect(
        identical(railBefore, railAfter),
        isTrue,
        reason: '侧栏 State 归零 ⇒ _highlightRect 丢失 ⇒ 高亮先消失一帧再瞬现（跳变）',
      );
      expect(
        (railAfter.widget as AylaLiveChannelRail).currentId,
        '2',
        reason: '复用同一个侧栏实例时，currentId 必须按新频道更新',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('LiveRoomPage：切台后侧栏高亮**仍在**（不会消失一帧再瞬现）',
        (WidgetTester tester) async {
      // 这条是「跳变」的**用户可见**那一半：组件级迁移由 `live_rail_test` 的
      // 「切换选中 → 高亮在 300ms 内迁移到新项位置」锁住；这里锁的是**路由驱动**的
      // 那条路径 —— 侧栏实例不被重建时，高亮在切台首帧就必须仍然存在。
      // 修前页面整页重建 ⇒ 侧栏 State 归零 ⇒ `_highlightRect == null` ⇒ 首帧没有高亮。
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();
      expect(find.byType(AylaNavHighlight), findsOneWidget);

      _goReplace(find.byType(LiveRoomPage).evaluate().single, '/live/2');
      // ⚠️ 只 pump 一帧：迁移动画的第一帧也必须**已经**有高亮（不是 null 档）。
      await tester.pump();
      expect(
        find.byType(AylaNavHighlight),
        findsOneWidget,
        reason: '切台首帧高亮消失 = 用户报的「跳变」（State 丢失后要等测量完才瞬现）',
      );
      await tester.pumpAndSettle();
      expect(find.byType(AylaNavHighlight), findsOneWidget);
    });

    testWidgets('LiveStudioPage：/live/start/1 → /live/start/2 State identity 不变',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/start/1');
      await tester.pumpAndSettle();

      final Finder pageFinder = find.byType(LiveStudioPage);
      expect(pageFinder, findsOneWidget);
      final State<LiveStudioPage> stateBefore =
          tester.state<State<LiveStudioPage>>(pageFinder);

      _goReplace(pageFinder.evaluate().single, '/live/start/2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final State<LiveStudioPage> stateAfter =
          tester.state<State<LiveStudioPage>>(pageFinder);
      expect(
        identical(stateBefore, stateAfter),
        isTrue,
        reason: '开播台切频道同样不得整页重建（web resolvePageKey → /live/start）',
      );
      expect((stateAfter.widget as LiveStudioPage).channelId, '2');
      await tester.pumpAndSettle();
    });

    testWidgets('切台首帧：不得把**上一个频道**的数据挂到新频道上',
        (WidgetTester tester) async {
      // 探针实证的缺陷（2026-11-02）：切台首帧里新会话的 `_history` 还没建好、
      // 旧会话的 `stop()` 还排在 microtask ⇒ 若直接回落 `live.danmaku`，
      // 会把旧频道的弹幕挂到新频道的列表与飘弹幕层上（web 侧不留这个窗口：
      // `liveSessionRuntime.enter()` 切频道分支**同步**先 `leave()` 清空）。
      // 同理头部不得显示旧频道的标题（`_channelOf` 只认同 id）。
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();

      // 造出「1 号频道正在直播、有 3 条弹幕」的真实观看态
      final AylaLiveState live = containerOf(tester);
      live.upsertChannel(const AylaLiveChannelSnapshot(
        id: '1',
        title: 'CH-ONE',
        status: AylaLiveStatus.live,
      ));
      live.setCurrentChannel(const AylaLiveChannelSnapshot(
        id: '1',
        title: 'CH-ONE',
        status: AylaLiveStatus.live,
      ));
      live.setSrsStatus(AylaLiveSrsStatus.live);
      live.setCurrentLoading(false);
      live.setDanmaku(<AylaLiveDanmaku>[
        for (int i = 1; i <= 3; i++)
          AylaLiveDanmaku(
            id: 'd$i',
            content: 'old-$i',
            createdAt: '2026-01-01T00:00:0${i}Z',
          ),
      ]);
      await tester.pump();
      final AylaLiveRoomBody before =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      expect(before.data.danmaku, hasLength(3), reason: '前提：1 号频道有 3 条弹幕');

      _goReplace(find.byType(LiveRoomPage).evaluate().single, '/live/2');
      await tester.pump(); // 只 pump 一帧 = 切台首帧

      final AylaLiveRoomBody after =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      expect(after.channelId, '2');
      expect(
        after.data.danmaku,
        isEmpty,
        reason: '切台首帧不得显示上一个频道的弹幕（探针修前为 3 条）',
      );
      expect(
        after.data.channel?.id,
        isNot('1'),
        reason: '头部不得拿到上一个频道的快照（_channelOf 只认同 id）',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('进 / 出直播间仍保留页面生命周期变化（归一不得跨页收拢）',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpApp(tester, const Size(1440, 900));
      router.go('/live/1');
      await tester.pumpAndSettle();
      final State<LiveRoomPage> roomState =
          tester.state<State<LiveRoomPage>>(find.byType(LiveRoomPage));

      // 回大厅：页面类型变化 ⇒ 必然换实例（这条反过来锁住「归一没有把 /live 也吃掉」）
      router.go('/live');
      await tester.pumpAndSettle();
      expect(find.byType(LiveRoomPage), findsNothing);

      router.go('/live/1');
      await tester.pumpAndSettle();
      expect(
        identical(
          roomState,
          tester.state<State<LiveRoomPage>>(find.byType(LiveRoomPage)),
        ),
        isFalse,
        reason: '退出再进入是真实的页面生命周期变化，不该复用旧 State',
      );
      await tester.pumpAndSettle();
    });
  });
}
