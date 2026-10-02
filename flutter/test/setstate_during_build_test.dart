/// 「setState() during build」跨页缺陷链的复现锁（2026-10-02 真机日志实锤）。
///
/// ## 被锁的缺陷链（逐环，全部可在源码指到行号）
/// ```text
/// _VoiceHubPageState.initState          (pages/voice_hub_page.dart:109)
///   └─ _loadFriends()                   (:241)
///        └─ aylaHubFriendIds()          (pages/hub_support.dart:430)
///             └─ AylaSocialStore.load() (state/social_store.dart:391)  ← 同步段就 _patch
///                  └─ _patch()          (:683)  → notifyListeners()
///                       └─ AylaSocialController._onStoreChanged (state/social_store.dart:796)
///                            └─ notifyListeners()   ← 不按 key 过滤：任意 kind 的 patch
///                                                     都会叫醒全部 controller
///                                 └─ AylaGroupDirectory._forward (pages/group_support.dart:431)
///                                      └─ notifyListeners()
///                                           └─ _GroupPageState._onChanged (pages/group_page.dart:383)
///                                                └─ setState()  ← 💥 builder 正在构建时调用
/// ```
///
/// ## 为什么异常文本是「GroupPage / Builder」
/// `_ModalScopeState.didChangeDependencies` 把路由页包在
/// `RepaintBoundary > Builder(builder: (ctx) => route.buildPage(...))` 里 —— 于是
/// 「当前正在构建的 widget」恒为 `Builder`，而被 setState 的 `GroupPage` 在**另一条
/// route** 的 `_ModalScope` 下 ⇒ `Element._debugIsDescendantOf(currentBuildTarget)` 为
/// false ⇒ `markNeedsBuild` 的断言抛出。两行文本与真机日志逐字一致。
///
/// ## 三组锁的分工
/// - **A / B**：端到端复现（真实路由）—— 覆盖页面的 store 写入时机；
/// - **C**：状态层兜底（`AylaSocialController._onStoreChanged` 的 build 期让路）的
///   **独立**证据 —— 直接在 build 期写 store，验证任何遗漏的调用方也不会把通知打回
///   build 期，且通知仍会最终送达。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/models/subgroup.dart' show AylaSubgroupPage;
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/pages/group_page.dart' show aylaGroupPageSubgroupsLoader;
import '../lib/router/app_router.dart' show appRouterProvider;
import '../lib/state/auth_state.dart' show authNotifierProvider;
import '../lib/state/directory_store.dart' show aylaDirectoryStore;
import '../lib/state/social_store.dart'
    show
        AylaSocialController,
        AylaSocialKind,
        AylaSocialOptions,
        aylaSocialStore;
import '../lib/theme/app_theme.dart' show buildAylaTheme;

const AylaSocialOptions kFriends = AylaSocialOptions();
const AylaSocialOptions kGroupConversations = AylaSocialOptions(type: 'group');

Future<AylaDirectoryPage<Object>> _emptyDirectory(
  Object kind,
  Object options,
  String? cursor,
) async =>
    const AylaDirectoryPage<Object>();

/// 页面级「裸 setState」受害者的最小等价物 —— 与 `_GroupPageState._onChanged`
/// （`group_page.dart:382–384`）**逐字同形**：`if (mounted) setState(() {})`。
class _BareSetStateVictim extends StatefulWidget {
  const _BareSetStateVictim({super.key, required this.controller, required this.log});

  final AylaSocialController<String> controller;
  final List<String> log;

  @override
  State<_BareSetStateVictim> createState() => _BareSetStateVictimState();
}

class _BareSetStateVictimState extends State<_BareSetStateVictim> {
  /// 触发件在写 store 前后置位：用于区分「通知落在 build 期」与「落在帧后」。
  bool writing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    widget.log.add(writing ? 'during-build' : 'after-build');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => const Text('victim');
}

/// 在**自己 initState（= 帧的 build 阶段）**里写 social store 的触发件。
///
/// 与 `_VoiceHubPageState.initState` 的 store 写入**同相位**：两者都发生在
/// `SchedulerBinding.schedulerPhase == persistentCallbacks` 期间。
class _InitStateStoreWriter extends StatefulWidget {
  const _InitStateStoreWriter({required this.onWrite});

  final VoidCallback onWrite;

  @override
  State<_InitStateStoreWriter> createState() => _InitStateStoreWriterState();
}

class _InitStateStoreWriterState extends State<_InitStateStoreWriter> {
  @override
  void initState() {
    super.initState();
    widget.onWrite();
  }

  @override
  Widget build(BuildContext context) => const Text('writer');
}

void main() {
  late int friendLoads;
  late int clockMs;

  setUp(() {
    friendLoads = 0;
    clockMs = 1700000000000;
    aylaGroupPageSubgroupsLoader = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    // ⚠️ 时钟可注入（social_store.dart:679）⇒ 60 秒新鲜窗口可控，
    // 这样「第二次进入」才会真的重新 _patch（= 触发通知链的那一步）。
    aylaSocialStore.nowMillis = () => clockMs;
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = 'u1';
    aylaDirectoryStore.requestOverride = _emptyDirectory;
    aylaSocialStore.requestOverride =
        (AylaSocialKind kind, AylaSocialOptions options, String? cursor) async {
      if (kind == AylaSocialKind.friends) {
        friendLoads += 1;
        return const AylaDirectoryPage<Object>(
          results: <Object>[AylaUserPublic(id: 'u2', nickname: '好友')],
          total: 1,
        );
      }
      return const AylaDirectoryPage<Object>();
    };
    aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
        const AylaSubgroupPage(total: 0);
  });

  tearDown(() {
    aylaGroupPageSubgroupsLoader = null;
    aylaSocialStore.requestOverride = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = null;
    aylaDirectoryStore.requestOverride = null;
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = null;
  });

  Future<({ProviderContainer container, GoRouter router})> pumpApp(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
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
    await tester.pumpAndSettle();
    return (container: container, router: router);
  }

  group('★ 复现锁 A：GroupPage 已挂载 → 进入 VoiceHubPage 不得抛异常', () {
    testWidgets('真机路径：/group/g1（已挂载）→ push /voice ⇒ takeException == null',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester);

      // ① 先进群页：GroupPage 挂载 ⇒ AylaGroupDirectory + _onChanged 已订阅。
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '/group/g1 自身应当干净');

      // ② 再进语音大厅：VoiceHubPage.initState 的 store 写入。
      app.router.push('/voice');
      await tester.pump(); // ← 关键帧：VoiceHubPage 在 Builder 里挂载
      expect(
        tester.takeException(),
        isNull,
        reason: '★ 这就是真机日志的那条断言：VoiceHubPage 的同步 store 写入经'
            'AylaSocialController → AylaGroupDirectory → GroupPage.setState 级联到'
            '已挂载但不在构建子树里的 GroupPage',
      );
      expect(friendLoads, greaterThan(0), reason: '好友档确实被取过（否则不算走到链上）');

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('★ 复现锁 B：同一会话内连续跨页（语音 hub → 群页 → 再回）无异常', () {
    testWidgets('/group/g1 → /voice → pop → /voice（新鲜窗口过期后重取）',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester);

      // ① 群页（受害者常驻栈底）
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // ② 第一站 /voice
      app.router.push('/voice');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '第一站 /voice 干净');
      expect(friendLoads, 1, reason: '首次进入取一次好友');

      // ③ 退回群页（VoiceHubPage 卸载，GroupPage 仍在栈上活跃）
      app.router.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '退回 /group/g1 干净');

      // ④ 让 60 秒新鲜窗口过期 ⇒ 再进 /voice 会真的重新 _patch（真正触发通知链）
      clockMs += 61 * 1000;
      app.router.push('/voice');
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '★ 再回 /voice：GroupPage 仍在栈上活跃，'
            'store 写入的级联不得再打醒它',
      );
      expect(friendLoads, 2, reason: '新鲜窗口过期 ⇒ 确实重新取了一次');

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // ==========================================================================
  // 状态层兜底（AylaSocialController._onStoreChanged）的**确定性锁**。
  //
  // 与 A/B 的区别：A/B 走「页面自己把写入延到帧后」，本组**直接**在 build 阶段写
  // store，验证「任何**遗漏的**调用方（含未来新增页面）也不会把通知打回 build 期」。
  // 因此本组**不依赖任何页面的修复**，是状态层修复的独立证据。
  //
  // 观察面三层：
  //   ① 订阅者通知**不得**落在 build 期（during-build 不得出现）；
  //   ② 通知必须**最终送达**（after-build 出现，不是把通知吞掉）；
  //   ③ 裸 setState 的受害者不抛异常（真机崩溃的可观测面）。
  group('★ 复现锁 C：build 期 store 写入 ⇒ 通知延到帧后（状态层兜底）', () {
    testWidgets('兄弟件 initState 写 store：裸 setState 订阅者不炸、且最终收到通知',
        (WidgetTester tester) async {
      final AylaSocialController<String> victim =
          AylaSocialController<String>(
        store: aylaSocialStore,
        kind: AylaSocialKind.friends,
        options: kFriends,
      );
      addTearDown(victim.dispose);
      final List<String> log = <String>[];
      final GlobalKey<_BareSetStateVictimState> victimKey =
          GlobalKey<_BareSetStateVictimState>();

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: <Widget>[
                  _BareSetStateVictim(
                    key: victimKey,
                    controller: victim,
                    log: log,
                  ),
                  // 触发件：在自己 initState（帧的 build 阶段）里写 store ——
                  // 与 VoiceHubPage.initState 的 store 写入同相位。
                  _InitStateStoreWriter(
                    onWrite: () {
                      victimKey.currentState!.writing = true;
                      // ⚠️ 不 await：load 的**同步段**就在这里（social_store.dart:391）。
                      aylaSocialStore.load(
                        AylaSocialKind.conversations,
                        kGroupConversations,
                      );
                      victimKey.currentState!.writing = false;
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // ① build 期不得通知订阅者（否则受害者的 setState 会抛断言）。
      expect(
        log.where((String s) => s == 'during-build'),
        isEmpty,
        reason: '★ 通知不得落在 build 期 —— 这正是真机 1051 条异常的判据',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '裸 setState 的受害者必须活着（真机崩溃面）',
      );

      // ② 通知必须最终送达（不是被吞掉）。
      await tester.pump();
      expect(
        log.where((String s) => s == 'after-build'),
        isNotEmpty,
        reason: '帧后必须补发通知 —— 页面仍然要刷新（不是静默丢弃）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('非 build 期（帧间）的 store 写入仍然**同步**通知（不改既有语义）',
        (WidgetTester tester) async {
      final AylaSocialController<String> controller =
          AylaSocialController<String>(
        store: aylaSocialStore,
        kind: AylaSocialKind.friends,
        options: kFriends,
      );
      addTearDown(controller.dispose);
      int notified = 0;
      controller.addListener(() => notified += 1);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Directionality(
              textDirection: TextDirection.ltr,
              child: Text('idle'),
            ),
          ),
        ),
      );
      // 帧间（idle）写入 ⇒ 同步通知，不排队。
      await aylaSocialStore.load(AylaSocialKind.friends, kFriends);
      expect(
        notified,
        greaterThan(0),
        reason: '帧间写入必须立即通知（与 web zustand 订阅在 commit 后同步回调同语义）',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
