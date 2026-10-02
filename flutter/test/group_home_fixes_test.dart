/// 群页 / 主页域三问题回归锁（2026-10-02）。
///
/// | 本组 | web 事实源 |
/// |---|---|
/// | 【问题 14】宽屏群页「建群」→ 填群名 → 提交 ⇒ 建群 API 被调用且参数正确 | `GroupCreateDialog.tsx:46–64`（`createGroupConversation({title, member_ids})` → `upsertConversation` → `onClose` → `navigate('/group/:id')`）；挂载点 `GroupPage.tsx:433` |
/// | 【问题 5】宽屏侧栏切群 ⇒ `recentGroupId` 被写入 | `GroupPage.tsx:229–245`，第 **233** 行 `useHomeStore.getState().setRecentGroup(id)`（依赖 `[id, effectiveScene]`） |
/// | 【问题 7】窄屏切场景 ⇒ 旧场景**不重建**、300ms 内淡出后卸载；新场景无淡入 | `GroupPage.tsx:499–539`：variants `enter/center = {x:0, opacity:1}`、`exit = {x:0, opacity:0}` + `AnimatePresence mode="sync"` |
///
/// ⚠️ 口径：宽屏几何/命中一律先钉表面尺寸（flutter_test 默认 800×600 是窄屏档）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/models/conversation.dart';
import '../lib/core/models/subgroup.dart' show AylaSubgroupPage;
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/layout/create_sheet_forms.dart' show AylaCreateGroupForm;
import '../lib/pages/group_page.dart'
    show
        AylaSceneFade,
        aylaGroupPageCreateGroupBuilder,
        aylaGroupPageSubgroupsLoader;
import '../lib/pages/home_support.dart' show kAylaHomePrefs;
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/directory_store.dart' show aylaDirectoryStore;
import '../lib/state/social_store.dart' show aylaSocialStore;
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/widgets/shell/channel_sidebar.dart' show AylaGroupScene;
import '../lib/widgets/shell/server_rail.dart' show AylaServerRail;

/// 可观测场景组件：把 `initState` / `dispose` 记进 [log]（问题 7 的判据源）。
class _SceneProbe extends StatefulWidget {
  const _SceneProbe(this.label, this.log);

  final String label;
  final List<String> log;

  @override
  State<_SceneProbe> createState() => _SceneProbeState();
}

class _SceneProbeState extends State<_SceneProbe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('init:${widget.label}');
  }

  @override
  void dispose() {
    widget.log.add('dispose:${widget.label}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

/// 真实主题 + 真实路由的 App 宿主（口径同 `group_page_shell_test.dart`）。
Future<({ProviderContainer container, GoRouter router})> _pumpApp(
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
        theme: buildAylaTheme(),
        // 必须真实主题 + Scaffold：默认主题的平台转场会与库内转场叠加（同 router_test 口径）。
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

AylaConversationSummary _group(String id) => AylaConversationSummary(
      id: id,
      type: AylaConversationType.group,
      title: '群 $id',
    );

void main() {
  setUp(() {
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = 'u1';
    // 共享单例（应用级）在用例间残留 ⇒ 每条用例从干净起点开始。
    kAylaHomePrefs.setRecentGroup(null);
  });
  tearDown(() {
    aylaSocialStore.requestOverride = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = null;
    aylaDirectoryStore.requestOverride = null;
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = null;
    aylaGroupPageSubgroupsLoader = null;
    aylaGroupPageCreateGroupBuilder = null;
    kAylaHomePrefs.setRecentGroup(null);
  });

  // ==================================================================
  // 【问题 7】窄屏切场景：旧场景 Element/State 原地复用（不重播入场）
  // ==================================================================
  group('【问题 7】窄屏场景切换（GroupPage.tsx:499–539）', () {
    /// 量某个场景文本所在槽位的 `FadeTransition` 不透明度。
    double slotOpacity(WidgetTester tester, String label) {
      final FadeTransition fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      return fade.opacity.value;
    }

    Widget host(AylaGroupScene scene, List<String> log) => MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: AylaSceneFade(
              scene: scene,
              builder: (AylaGroupScene s) => _SceneProbe(s.name, log),
            ),
          ),
        );

    testWidgets('切到场景 B：旧场景 A 的 initState 不再被调用（未重建）', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(host(AylaGroupScene.chat, log));
      expect(log, <String>['init:chat']);

      // 切到 live（web：`AnimatePresence mode="sync"`，新旧同帧重叠、旧件 300ms 淡出）
      await tester.pumpWidget(host(AylaGroupScene.live, log));

      expect(
        log.where((String e) => e == 'init:chat').length,
        1,
        reason: '旧场景被重建 ⇒ 它的 initState 重跑 ⇒ 「离开的页面重播入场动画」（问题 7 根因）',
      );
      expect(log.contains('dispose:chat'), isFalse, reason: '退场期间旧场景子树必须还活着');
      expect(log, contains('init:live'), reason: '新场景应挂载');
    });

    testWidgets('旧场景 300ms 淡出后才卸载；新场景无淡入（opacity 直接为 1）', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(host(AylaGroupScene.chat, log));
      await tester.pumpWidget(host(AylaGroupScene.live, log));

      // 新场景的 variants 是 `center = {x:0, opacity:1}`（tsx 508–509）⇒ 无淡入。
      expect(slotOpacity(tester, 'live'), 1.0,
          reason: '新场景不得淡入（web enter/center 都是 opacity:1）');

      // 旧场景起点仍为 1（reverse 刚起步），推进 150ms 应到中间态。
      expect(slotOpacity(tester, 'chat'), 1.0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final double mid = slotOpacity(tester, 'chat');
      expect(mid, lessThan(0.9), reason: '旧场景应在淡出中（web exit opacity 1→0，300ms）');
      expect(mid, greaterThan(0.05), reason: '150ms 内不应淡完');
      expect(log.contains('dispose:chat'), isFalse, reason: '淡出未结束，旧场景不能提前卸载');

      // 走完剩余时长（+余量）⇒ 卸载。
      await tester.pump(const Duration(milliseconds: 200));
      expect(log, contains('dispose:chat'), reason: '淡出结束（300ms）后旧场景应卸载');
      expect(
        log.where((String e) => e == 'init:chat').length,
        1,
        reason: '整条淡出链上旧场景不得重建',
      );
    });

    testWidgets('快速连切（chat→live→chat）不丢失退场、旧场景仍不重建', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(host(AylaGroupScene.chat, log));
      await tester.pumpWidget(host(AylaGroupScene.live, log));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100)); // 淡出未完成

      await tester.pumpWidget(host(AylaGroupScene.chat, log));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));

      expect(
        log.where((String e) => e == 'init:chat').length,
        1,
        reason: '连切过程中 chat 场景被重建了（固定槽位 / 恒定包装链失效）',
      );
      expect(log, contains('dispose:live'));
    });
  });

  // ==================================================================
  // 【问题 5】宽屏侧栏切群 ⇒ 写 recentGroupId（GroupPage.tsx:233）
  // ==================================================================
  group('【问题 5】进群写 recentGroupId（GroupPage.tsx:233）', () {
    testWidgets('宽屏侧栏切群：recent 跟随当前群更新', (WidgetTester tester) async {
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
              results: <Object>[_group('g1'), _group('g2')], total: 2);
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();
      aylaGroupPageSubgroupsLoader = (String gid, String? cursor) async =>
          const AylaSubgroupPage();

      final ({ProviderContainer container, GoRouter router}) app =
          await _pumpApp(tester, const Size(1440, 900));

      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      expect(kAylaHomePrefs.recentGroupId, 'g1', reason: '进群应写 recent（web tsx 233）');

      // 侧栏切群：与 home_page 不同的一条写路径（原来只 context.go、不写 recent）。
      app.router.go('/group/g2');
      await tester.pumpAndSettle();
      expect(
        kAylaHomePrefs.recentGroupId,
        'g2',
        reason: '宽屏侧栏切群必须更新 recentGroupId（GroupPage.tsx:233）—— 否则「回主页」跳到旧群',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ==================================================================
  // 【问题 14】宽屏群页建群接线
  // ==================================================================
  group('【问题 14】宽屏群页建群（GroupCreateDialog.tsx:46–64 / GroupPage.tsx:433）', () {
    Finder createButton() => find.byWidgetPredicate(
          (Widget w) => w is AylaIconButton && w.semanticLabel == '创建群聊',
        );

    Future<void> pumpWideGroup(WidgetTester tester) async {
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[_group('g1')], total: 1);
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();
      aylaGroupPageSubgroupsLoader = (String gid, String? cursor) async =>
          const AylaSubgroupPage();
      final ({ProviderContainer container, GoRouter router}) app =
          await _pumpApp(tester, const Size(1600, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
    }

    testWidgets('点侧栏加号挂载的是**完整接线**的建群表单（不是只带 onClose 的空壳）',
        (WidgetTester tester) async {
      await pumpWideGroup(tester);
      expect(find.byType(AylaServerRail), findsOneWidget);

      await tester.tap(createButton(), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(
        find.byType(AylaCreateGroupForm),
        findsOneWidget,
        reason: '群页建群弹层必须是接好 onSubmit/onOpenPrivate/搜索的完整表单；'
            '只传 onClose 时 `group_create_dialog.dart:184–185` 会静默返回 ⇒ 点「建群」毫无反应',
      );
      expect(find.text('创建群聊'), findsOneWidget, reason: '弹窗未打开');
      expect(tester.takeException(), isNull);
    });

    testWidgets('填群名 → 点「建群」⇒ createGroupConversation 被调用且参数正确',
        (WidgetTester tester) async {
      String? gotTitle;
      List<String>? gotMembers;
      await pumpWideGroup(tester);

      // 注入**真实** AylaCreateGroupForm，只替换三个 API 出口（替身注入的既有口径）。
      aylaGroupPageCreateGroupBuilder = (VoidCallback onClose) => AylaCreateGroupForm(
            onClose: onClose,
            searchUsers: (String q, {int limit = 30, String? cursor}) async =>
                AylaDirectoryPage<AylaUserPublic>(
              results: <AylaUserPublic>[
                const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
              ],
              total: 1,
            ),
            createGroup: ({required String title, required List<String> memberIds}) async {
              gotTitle = title;
              gotMembers = memberIds;
              return 'group-new';
            },
            openPrivate: (String userId) async => 'chat-new',
          );

      await tester.tap(createButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AylaCreateGroupForm), findsOneWidget);

      // tsx 98–105：群名必填输入框（**限定在弹层子树内** —— 群页聊天场景下
      // 页面本身还有消息输入框，`find.byType(TextField).first` 会打错目标）。
      final Finder titleField = find
          .descendant(
            of: find.byType(AylaCreateGroupForm),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(titleField, '  深夜电台  ');
      await tester.pump();

      // tsx 172–180：建群键（busy/空名时禁用）。
      // ⚠️ 用回调直调而不是 tap：弹层在 GroupPage 的 Stack 内，宿主矩形与固定舞台不一致时
      //    按钮会落到命中区外（同 `group_create_dialog_test.dart:106–110` 的既有口径）。
      //    本用例验的是**接线**（submit 是否被接上、参数是否原样透传），不是按钮自身的命中。
      final AylaGlassButton submit = tester.widget<AylaGlassButton>(
        find
            .ancestor(
              of: find.text('建群'),
              matching: find.byType(AylaGlassButton),
            )
            .first,
      );
      expect(submit.onPressed, isNotNull, reason: '群名已填 ⇒ 建群键必须可用（问题 14 的空壳接线不可用）');
      submit.onPressed!.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(gotTitle, '深夜电台', reason: 'tsx 47/52：title.trim() 后提交');
      expect(gotMembers, isEmpty, reason: 'tsx 53：未勾选成员 ⇒ member_ids 为空数组');
      // tsx 57：成功后 onClose ⇒ 弹窗关闭。
      expect(
        find.byType(AylaCreateGroupForm),
        findsNothing,
        reason: 'tsx 57：成功后 onClose ⇒ 弹窗关闭',
      );
      expect(tester.takeException(), isNull);
    });
  });
}