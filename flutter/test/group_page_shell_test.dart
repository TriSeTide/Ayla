/// GroupPage 壳层回归锁 —— 宽屏三列 + 窄屏顶栏（web `pages/GroupPage.tsx` 405–496）。
///
/// 本轮（2026-09-29 用户验收实报）修的四条，每条都在这里留一条锁：
/// ① 宽屏切群**不得整棵重建**：路由不给页面加 `key: ValueKey(id)` ⇒ State 跨群复用
///    （web 只有一个 GroupPage 实例、只换 route param；`ServerRail` 常驻，
///    `ChannelSidebar` 走 `AnimatePresence mode="wait"` 换面板）；
/// ② 宽屏第二列（`ChannelSidebar`）必须可点：`playing` 不传 false（= web 面板在场态）；
/// ③ 宽屏输入容器 = `margin: var(--sidebar-gutter)` + `margin-left: 0`
///    （`auroraqua.css:346–359 / 361–368`）+ `panelVariants(bottom)` 上滑入场
///    （`GroupChat.tsx:326–332`）；**消息区**同理补 `panelVariants(right)` 右入
///    （`GroupChat.tsx:288–294`，进场 x +20 → 0 + 淡入，切场景回聊天会重播）；
/// ④ 窄屏 `/group/:id/{posts,voice,games}` 不得再触发
///    `Incorrect use of ParentDataWidget`（`AylaScrollTopFab` 的 narrow 档自带 `Positioned`）。
///
/// 口径：与 `router_test` 同源 —— **真实主题 + 真实表面尺寸**
/// （断点读 `MediaQuery`、布局宽来自测试表面，两件事都要钉）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart';
import '../lib/pages/group_chat_page.dart';
import '../lib/pages/group_page.dart';
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/group_providers.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/chat/message_list.dart' show AylaMessageList;
import '../lib/widgets/shell/channel_sidebar.dart';
import '../lib/widgets/shell/group_top_tabs.dart';
import '../lib/widgets/shell/server_rail.dart';
import '../lib/widgets/shell/top_nav.dart';

/// 启动真实路由（登录态注入 = `router_test` 同款；无网络 ⇒ 请求失败静默）。
Future<({ProviderContainer container, GoRouter router})> pumpApp(
  WidgetTester tester,
  Size size,
) async {
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
  return (container: container, router: router);
}

/// 目标子树所属 `AylaRevealItem` **自己那一层**的 `Opacity` 取值。
///
/// `AylaRevealItem` 的结构是 `AnimatedBuilder > Opacity > Transform.translate`
/// ⇒ reveal 内**第一个** `Opacity` 就是它自己的（内层 `AylaPanelSwap` 等在其之后）。
double revealLayerOpacity(WidgetTester tester, Finder target) {
  final Finder item = find
      .ancestor(of: target, matching: find.byType(AylaRevealItem))
      .first;
  return tester
      .widget<Opacity>(
        find.descendant(of: item, matching: find.byType(Opacity)).first,
      )
      .opacity;
}

/// 群内容区（`GroupChatPage`）**祖辈**的最小不透明度。
///
/// `1.0` = 内容整体可见；`0` = 内容不在场或被整层淡出。只取祖辈 ⇒ 子件自己的入场动画
/// （`AylaRevealItem` 在 GroupChatPage **内部**）不会干扰判据。
double contentAreaOpacity(WidgetTester tester) {
  final Iterable<Element> found = find.byType(GroupChatPage).evaluate();
  if (found.isEmpty) return 0;
  double min = 1;
  found.first.visitAncestorElements((Element a) {
    final Widget w = a.widget;
    if (w is FadeTransition) min = math.min(min, w.opacity.value);
    if (w is Opacity) min = math.min(min, w.opacity);
    if (w is AnimatedOpacity) min = math.min(min, w.opacity);
    return true;
  });
  return min;
}

// ⚠️ 这里原有一个 `messageAreaOpacity()`（取 `AylaMessageList` 祖辈最小不透明度）。
// 2026-09-29 的 Impeller 修复后，消息区（玻璃子树）的 `AylaRevealItem` 走**玻璃档**、
// 整层 opacity 恒 1.0（见 `lib/widgets/base/reveal.dart` 文件头）⇒ 该探针恒读 1.0、
// 失去判据价值，已删除；消息区入场改由**位移**锁住（原 `Opacity > Transform.translate`
// 里的 `Transform` 仍在，位移判据不受影响）。

void main() {
  // ⚠️ 服务器列（左侧群头像列）入场是**每个 app 会话只播一次**（kAylaServerRailEntered）——
  // web 宽屏给 .server-rail 写了 animation: none（auroraqua.css:293 + 310–313），
  // 由 motion 按 owner 编排。用例间必须重置，否则「第二列入场」类断言会串味。
  setUp(() => kAylaServerRailEntered = false);
  group('宽屏：切群保留壳与侧栏（实报 ①）', () {
    testWidgets('整条外壳链（AppShell→TopNav→GroupPage→两列侧栏）的 State 跨群不重建', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      // 群头像侧栏 = **选项卡**语义（web `GroupPage.tsx:409–414` 的 `<ServerRail>` **没有 key**
      // ⇒ 切群不重挂；而 `ChannelSidebar.tsx:71–76` 有 `key={groupId}` + `mode="wait"`，
      // 那是 web 自己的换面板编排）。这里把**整条链**一起钉住：任何一层被重建，
      // 用户看到的就是「整个界面重新加载」。
      final State<StatefulWidget> shell = tester.state(find.byType(AppShell));
      final State<StatefulWidget> nav = tester.state(find.byType(AylaTopNav));
      final State<StatefulWidget> page = tester.state(find.byType(GroupPage));
      final State<StatefulWidget> rail = tester.state(find.byType(AylaServerRail));
      final State<StatefulWidget> sidebar =
          tester.state(find.byType(AylaChannelSidebar));
      // 群头像列表的滚动位置：只有「State + ScrollController 都活着」才会保留。
      final Finder railList = find.descendant(
        of: find.byType(AylaServerRail),
        matching: find.byType(Scrollable),
      );
      final ScrollableState railScroll = tester.state<ScrollableState>(railList.first);

      app.router.go('/group/g2');
      await tester.pumpAndSettle();

      expect(
        identical(shell, tester.state(find.byType(AppShell))),
        isTrue,
        reason: 'AppShell 被重建 ⇒ 顶栏 / 浮层 / 底栏整壳重载',
      );
      expect(
        identical(nav, tester.state(find.byType(AylaTopNav))),
        isTrue,
        reason: 'AylaTopNav 被重建 ⇒ 顶栏重新入场',
      );
      expect(
        identical(railScroll, tester.state<ScrollableState>(railList.first)),
        isTrue,
        reason: '群头像列的 ScrollPosition 被换掉 ⇒ 列表重新加载（滚动位置归零）',
      );

      expect(
        identical(page, tester.state(find.byType(GroupPage))),
        isTrue,
        reason: '切群重建了 GroupPage ⇒ 整个界面（含两列侧栏）重新加载',
      );
      expect(
        identical(rail, tester.state(find.byType(AylaServerRail))),
        isTrue,
        reason: 'ServerRail 跨群必须常驻（web 同一实例、只换 props）',
      );
      expect(
        identical(sidebar, tester.state(find.byType(AylaChannelSidebar))),
        isTrue,
        reason: 'ChannelSidebar 跨群必须复用实例（web 走 AnimatePresence mode="wait" 换面板）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('切群再切回：群级目录桶复用、**不重拉**（web `records[key]` 语义）', (
      WidgetTester tester,
    ) async {
      // web：`useDirectoryPage` / `useSocialPage` 从全局 store 的 `records[key]` 读，
      // key 含 groupId；`stores/directory.ts:274` / `stores/social.ts:150` 的
      // `mode === "initial" && fetchedAt < 60s ⇒ return` 让**切回旧群不再发首屏请求**，
      // 面板一挂上就是满内容（无 loading 闪烁）。
      // 反例（本轮修掉的实报）：每次切群 dispose + 重建 + 立即 load() ⇒ 空一下 = 「选项卡被刷掉」。
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      // 正对照：**首次**进群必须发起首屏请求（缓存未命中）⇒ 证明这条判据是活的。
      app.router.go('/group/g1');
      await tester.pump();
      expect(
        tester
            .widget<AylaChannelSidebar>(find.byType(AylaChannelSidebar))
            .subgroupDirectory
            .loading,
        isTrue,
        reason: '首次进群没有发起首屏请求 —— 缓存语义改坏了',
      );
      await tester.pumpAndSettle();
      app.router.go('/group/g2');
      await tester.pumpAndSettle();

      app.router.go('/group/g1'); // 切回已进过的群
      await tester.pump(); // 只看第 1 帧：旧实现这一刻正在跑新建桶的首屏请求
      final AylaChannelSidebar sidebar =
          tester.widget<AylaChannelSidebar>(find.byType(AylaChannelSidebar));
      expect(
        sidebar.subgroupDirectory.loading,
        isFalse,
        reason: '切回已进过的群又发起了一次首屏请求 —— web 的 records[key] 命中缓存时不重拉',
      );
      expect(
        sidebar.voiceDirectory.loading,
        isFalse,
        reason: '语音房目录同样按群分桶缓存，切回不得重拉',
      );
      expect(
        sidebar.liveDirectory.loading,
        isFalse,
        reason: '直播间目录同样按群分桶缓存，切回不得重拉',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('切群：第二列**新面板必须播入场**（web 面板带 key=groupId ⇒ 新组件 initial="enter"）', (
      WidgetTester tester,
    ) async {
      // web `ChannelSidebar.tsx:75–77` 的面板是 `AnimatePresence` 的**直接子元素**且带
      // `key={groupId}` ⇒ 换群 = 新组件挂载 ⇒ `initial="enter"`（同文件 93 行）配合
      // `panelVariants(reduced, "left")`（`auroraquaMotion.ts:37–51`：x −20 / opacity 0 → center）
      // **每次换群都重播入场**。不给 `AylaRevealItem` 带 key 时它的 State 被复用、
      // `_started` 已 true ⇒ 只剩旧面板退场、新面板直接闪现。
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();

      final Finder row = find.descendant(
        of: find.byType(AylaChannelSidebar),
        matching: find.text('聊天'),
      );
      expect(row, findsOneWidget);
      // ⚠️ 判据用**位移**、不用 `Opacity`：新面板 `_ChannelSidebarPanel` 自身是玻璃件
      // （`channel_sidebar.dart:1140` 的 `AylaGlassSurface`）⇒ `AylaRevealItem` 对含
      // `BackdropFilter` 的子树**不再做整层淡入**（Impeller 会拒绝「`Opacity` 祖先 +
      // `BackdropFilter`」并刷屏；依据与处置见 `lib/widgets/base/reveal.dart` 文件头）
      // —— 该子树里的 `Opacity` 恒为 1.0，只有位移还随入场推进。
      //
      // 位移与入场进度同源：`offset.dx * (1 − t)`，左入起点 −20 / 终点 0
      // ⇒ 与原判据等价（`opacity < 0.9` ⇔ `t < 0.9` ⇔ 位移 < −2）。
      double revealTranslateX() => tester
          .widget<Transform>(
            find
                .descendant(
                  of: find
                      .ancestor(of: row, matching: find.byType(AylaRevealItem))
                      .last,
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .storage[12]; // Matrix4 的平移 x（列主序）

      app.router.go('/group/g2');
      // 退场 300ms（旧面板 x −20 + 淡出）走完后再采样：此刻新面板应处于**入场起点**。
      for (int i = 0; i < 22; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        revealTranslateX(),
        lessThan(-2.0),
        reason: '新群侧栏直接到位（没有入场）—— 用户实报「没有后一个群的侧栏淡入」',
      );
      await tester.pumpAndSettle();
      expect(
        revealTranslateX(),
        moreOrLessEquals(0.0, epsilon: 0.001),
        reason: '入场应能正常走到终点',
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('切群：群内容区**不得整体淡出**（web 宿主变体全空 = 当帧切换）', (
      WidgetTester tester,
    ) async {
      // web `components/motion/ConversationTransition.tsx:12–24` + `auroraquaMotion.ts:29`：
      // `ConversationOwner` 的变体是 `auroraquaPanelOrchestration`（enter/center/exit **全为空对象**）
      // ⇒ `AnimatePresence mode="wait"` 当帧满足 ⇒ **宿主不淡出**；而
      // `AylaConversationTransition` 的 `panels:true && !childOwnsPanels` 档会给旧件挂
      // 300ms `FadeTransition` 兜底（旧件淡到 0 期间**不挂新件**）= 用户实报的「切群闪屏」。
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      expect(contentAreaOpacity(tester), 1.0, reason: '静态时内容区应完全不透明');

      app.router.go('/group/g2');
      for (int i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          contentAreaOpacity(tester),
          greaterThan(0.9),
          reason: '切群第 ${i + 1} 帧群内容区被整体淡出/清空 —— 即「跳转闪屏」',
        );
      }
    });
  });

  group('宽屏：第二列命中（实报 ②）', () {
    testWidgets('点 ChannelSidebar 的「语音 / 帖子」行进对应场景', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();

      Future<void> tapRow(String label, String expectPath, String expectScene) async {
        final Finder row = find.descendant(
          of: find.byType(AylaChannelSidebar),
          matching: find.text(label),
        );
        expect(row, findsOneWidget, reason: '侧栏「$label」行未渲染');
        await tester.tap(row, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(
          app.router.routerDelegate.currentConfiguration.uri.toString(),
          expectPath,
          reason: '「$label」行的命中被忽略（IgnorePointer / 遮挡）',
        );
        expect(app.container.read(groupStateProvider).activeScene.name, expectScene);
      }

      await tapRow('语音', '/group/g1/voice', 'voice');
      await tapRow('帖子', '/group/g1/posts', 'posts');
      expect(tester.takeException(), isNull);
    });
  });

  group('宽屏：输入容器外边距与上滑入场（实报 ③）', () {
    testWidgets('≥769：上/右/下各 12、左 0（与左列侧栏卡片底沿齐平）', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();

      final Rect input = tester.getRect(find.byType(AylaMessageInput));
      final Rect sidebar = tester.getRect(find.byType(AylaChannelSidebar));
      // auroraqua.css:347–358（margin: 12）+ 362–366（margin-left: 0）
      expect(input.right, 1440 - 12, reason: '右沿应离视口 12（原本贴右）');
      expect(input.bottom, 900 - 12, reason: '底沿应离视口 12（原本贴底）');
      expect(
        input.bottom,
        sidebar.bottom - 12,
        reason: '输入框底沿必须与左列侧栏卡片的底沿齐平（两者各带同一 12 的 gutter）',
      );
      expect(
        input.left,
        sidebar.right,
        reason: '左沿 = 内容列左沿（左列侧栏 slot 的右缘），margin-left: 0',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('进场从下方 20px 上滑（玻璃档只位移不淡入；GroupChat.tsx:326–333）', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pump(); // 首帧（入场起点）
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(AylaMessageInput), findsOneWidget);
      final Rect early = tester.getRect(find.byType(AylaMessageInput));
      await tester.pumpAndSettle();
      final Rect settled = tester.getRect(find.byType(AylaMessageInput));

      expect(
        early.top - settled.top,
        greaterThan(5),
        reason: '入场首帧应带正下方位移（+20 → 0），实测 ${early.top - settled.top}',
      );
      // ⚠️ 入场断言由「`opacity` 中间态」改为**位移 + 玻璃档 opacity 恒 1.0**：
      // 输入区是玻璃（`.composer` → `AylaGlassSurface`）⇒ 调用点传了
      // `fadeGlass: false`（`group_chat_page.dart` 的输入区 reveal）⇒ 整层 opacity
      // 恒 1.0、**不推 opacity**（Impeller 拒绝「`Opacity` 祖先 + `BackdropFilter`」并刷屏，
      // 处置与依据见 `lib/widgets/base/reveal.dart` 文件头）。位移判据（上一行）
      // 仍然锁住「入场发生了」，本行锁住「玻璃档没在推 opacity」。
      // 若将来改成「玻璃件自己接收父级 alpha」（13 号 §6.2 末条，需用户裁决），
      // 这条断言可按当时口径恢复为「中间态 < 0.9」。
      expect(
        revealLayerOpacity(tester, find.byType(AylaMessageInput)),
        1.0,
        reason: '玻璃子树不得走整层淡入（Impeller 会拒绝并刷屏）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('消息区入场：x +20 → 0（玻璃档只位移），切场景回聊天会重播（GroupChat.tsx:288–294）', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));

      Future<double> sampleDx() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(AylaMessageList), findsOneWidget);
        final Rect early = tester.getRect(find.byType(AylaMessageList));
        await tester.pumpAndSettle();
        final Rect settled = tester.getRect(find.byType(AylaMessageList));
        return early.left - settled.left;
      }

      app.router.go('/group/g1'); // 进群（聊天场景）
      final double first = await sampleDx();
      expect(first, greaterThan(5), reason: '消息区进场应带 +20 右向位移，实测 $first');
      // 消息区同样是玻璃子树（气泡 `.bubble-other` blur12）⇒ `group_chat_page.dart`
      // 的 reveal 传了 `fadeGlass: false`：整层 opacity 恒 1.0、不推 opacity
      // （原因见 `lib/widgets/base/reveal.dart` 文件头）。
      expect(
        revealLayerOpacity(tester, find.byType(AylaMessageList)),
        1.0,
        reason: '玻璃子树不得走整层淡入（Impeller 会拒绝并刷屏）',
      );

      app.router.go('/group/g1/voice'); // 切到语音场景
      await tester.pumpAndSettle();
      app.router.go('/group/g1'); // 切回聊天 ⇒ 应重播
      final double again = await sampleDx();
      expect(again, greaterThan(5), reason: '切回聊天未重播消息区入场，实测 $again');
      expect(tester.takeException(), isNull);
    });

    testWidgets('≤768：无外边距（app.css:3206 只改内距）', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      final Rect input = tester.getRect(find.byType(AylaMessageInput));
      expect(input.left, 0);
      expect(input.right, 400);
      expect(input.bottom, 800);
      expect(tester.takeException(), isNull);
    });
  });

  group('窄屏：场景路由不触发 ParentDataWidget 冲突（实报 ④/⑤）', () {
    for (final String path in <String>[
      '/group/g1',
      '/group/g1/posts',
      '/group/g1/voice',
      '/group/g1/games',
      '/group/g1/info',
    ]) {
      testWidgets('$path 正常渲染顶栏与内容', (WidgetTester tester) async {
        final ({ProviderContainer container, GoRouter router}) app =
            await pumpApp(tester, const Size(400, 800));
        app.router.go(path);
        await tester.pumpAndSettle();
        expect(
          find.byType(AylaGroupTopTabs),
          findsOneWidget,
          reason: '窄屏群页必须渲染顶栏（GroupTopTabs）',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$path 触发了框架断言（AylaScrollTopFab 的 narrow 档自带 Positioned）',
        );
      });
    }

    testWidgets('顶栏四个 tab 均可点（含右上角「桌游」）', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();

      Future<void> tapTab(String label, String expectPath) async {
        final Finder tab = find.descendant(
          of: find.byType(AylaGroupTopTabs),
          matching: find.text(label),
        );
        expect(tab, findsOneWidget);
        await tester.tap(tab.first, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(
          app.router.routerDelegate.currentConfiguration.uri.toString(),
          expectPath,
          reason: '顶栏「$label」tab 点击无效',
        );
      }

      await tapTab('直播', '/group/g1/live');
      await tapTab('帖子', '/group/g1/posts');
      await tapTab('桌游', '/group/g1/games'); // 右上角
      await tapTab('语音', '/group/g1/voice');
      expect(tester.takeException(), isNull);
    });
  });
}
