/// 根因 B 的复现锁：「GroupPage 已挂载 → 进入 VoiceHubPage」不得在 build 期通知。
///
/// ## 用户现场（2026-10-02，\`flutter run\` 首条异常）
/// \`\`\`
/// setState() or markNeedsBuild() called during build.
/// The widget on which setState() was called was: GroupPage
/// #3  _GroupPageState._onChanged (pages/group_page.dart:383)
/// #4  ChangeNotifier.notifyListeners
/// #5  AylaGroupDirectory._forward (pages/group_support.dart:431)
/// #6  ChangeNotifier.notifyListeners
/// #7  AylaSocialController._onStoreChanged (state/social_store.dart:796)
/// #9  AylaSocialStore._patch (state/social_store.dart:683)
/// #10 AylaSocialStore.load (state/social_store.dart:391)
/// #11 aylaHubFriendIds (pages/hub_support.dart:430)
/// #12 _VoiceHubPageState._loadFriends (pages/voice_hub_page.dart:241)
/// #13 _VoiceHubPageState.initState (pages/voice_hub_page.dart:109)
/// \`\`\`
///
/// ## 机制（为什么必然触发）
/// - 四个大厅页都在 \`initState\` 里 \`_loadFriends()\`（voice/live/games/posts 同款）；
/// - \`_loadFriends\` 是 \`async\` 但**首个 \`await\` 之前是同步段**：
///   \`aylaHubFriendIds()\` → \`aylaSocialStore.load()\` 在 **首个 await 前**
///   同步走完 60s 短路判定 → \`_patch()\`（同步 \`notifyListeners\`）
///   （\`social_store.dart:391\`；命中缓存时这条提前返回，正是「打开组件库/
///   首次进入才炸、之后不再炸」的原因）；
/// - 订阅链：store → \`AylaSocialController._onStoreChanged\`（:796）→
///   \`AylaGroupDirectory._forward\`（group_support.dart:431）→
///   \`GroupPage._onChanged\`（group_page.dart:383 的裸 \`setState\`）；
/// - 而 \`initState\` 发生在**本帧的 build 阶段**（父级 build 里挂载新页面）
///   ⇒ \`setState\` 落在 build 期间 ⇒ 断言。
/// 只有 GroupPage 挂着时才炸（大厅页自己只读 items，不 setState）。
///
/// ## 修复
/// 四个大厅页的 \`_loadFriends\` 统一挪到**帧后**
/// （\`addPostFrameCallback\`，与同文件 \`_registerDirectoryEvents\` /
/// \`_registerRefresh\` 的既有范式一致）：帧后 store 的同步通知不再落在 build 期。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/pages/group_page.dart';
import '../lib/pages/live_hub_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/social_store.dart';

/// 统计某段构建里 FlutterError 的首行种类（用于「修复前后条数」量化）。
class _ErrorCounter {
  final List<String> messages = <String>[];
  FlutterExceptionHandler? _prev;
  bool _active = false;

  void start() {
    _prev = FlutterError.onError;
    _active = true;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (_active) messages.add(details.exceptionAsString());
    };
  }

  void stop() {
    _active = false;
    FlutterError.onError = _prev;
  }

  int countOf(String needle) =>
      messages.where((String m) => m.contains(needle)).length;
}

/// 复刻真实位形：GroupPage 常驻（壳层切场景时不 dispose），大厅页是**后挂**的。
Widget _host(ProviderContainer container, Widget? overlayPage) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                const GroupPage(groupId: 'g1'),
                if (overlayPage != null) Positioned.fill(child: overlayPage),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  /// friends 请求挂起（不完成）——只要 \`store.load()\` 被调用，
  /// 它在**首个 await 之前**就同步 \`_patch\` 了一帧 loading 状态。
  Completer<AylaDirectoryPage<Object>> gate = Completer<AylaDirectoryPage<Object>>();

  setUp(() {
    gate = Completer<AylaDirectoryPage<Object>>();
    aylaGroupPageSubgroupsLoader = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    aylaSocialStore.requestOverride =
        (AylaSocialKind kind, AylaSocialOptions options, String? cursor) {
      if (kind == AylaSocialKind.friends) return gate.future;
      return Future<AylaDirectoryPage<Object>>.value(
        const AylaDirectoryPage<Object>(),
      );
    };
  });

  tearDown(() {
    aylaGroupPageSubgroupsLoader = null;
    aylaSocialStore.requestOverride = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = null;
  });

  testWidgets('GroupPage 已挂载 → 进入 VoiceHubPage：无 setState during build', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    // ① GroupPage 常驻并完成首帧
    await tester.pumpWidget(_host(container, null));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'GroupPage 首帧本身必须干净');

    // ② 同一帧内挂上 VoiceHubPage（= 壳层切场景 / 路由换页的真实位形）
    await tester.pumpWidget(_host(container, const VoiceHubPage()));
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: '大厂页 initState 同步触发 store 写入 ⇒ GroupPage._onChanged 在 build 期 setState',
    );

    await tester.pumpAndSettle();
  });

  testWidgets('量化：进入 VoiceHubPage 时 setState-during-build 条数必须为 0', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_host(container, null));
    await tester.pump();
    tester.takeException();

    final _ErrorCounter counter = _ErrorCounter();
    counter.start();
    await tester.pumpWidget(_host(container, const VoiceHubPage()));
    await tester.pump();
    counter.stop();
    tester.takeException();

    expect(
      counter.countOf('setState() or markNeedsBuild() called during build'),
      0,
      reason: '修复前为 1（_VoiceHubPageState.initState → _loadFriends 的同步通知）',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('LiveHubPage 同路径：无 setState during build', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_host(container, null));
    await tester.pump();
    tester.takeException();

    await tester.pumpWidget(_host(container, const LiveHubPage()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });
}
