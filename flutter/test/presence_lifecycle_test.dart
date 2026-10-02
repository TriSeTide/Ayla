/// presence 域「容器销毁 / 关闭顺序」回归锁 —— 锁住 2026-10-02 真机验收暴露的缺陷：
///
/// ```
/// A AylaPresenceState was used after being disposed.
///   ChangeNotifier.notifyListeners
///   lib/state/presence_state.dart  AylaPresenceState.reset        (:86)
///   lib/core/ws/presence_ws.dart   AylaPresenceWsClient.disconnect (:72)
///   riverpod ... ProviderElementBase.runOnDispose
///   riverpod ... ProviderContainer.dispose
/// ```
///
/// ## 触发条件（不是"偶发"）
/// `presenceWsProvider` 注册了 `ref.onDispose(client.disconnect)`
/// （`state/presence_providers.dart:38`），而 `disconnect()` 会写
/// `presenceStateProvider`（`reset()`）与 `realtimeProvider`（`setStatus`）。
/// 容器销毁时**状态被回收与 owner 被关闭之间没有先后契约**（Riverpod 的
/// `ProviderContainer.dispose` 逆序遍历 provider 图，而这三个 provider 之间
/// 因 `read` 不建依赖边）⇒ `AylaPresenceState` 可能先一步被回收，
/// 此时 `disconnect()` 仍会 `notifyListeners()` ⇒ 抛 "used after being disposed"。
///
/// 该异常直接毁掉 `test/auth_remember_test.dart` 的 5 条用例
/// （「冷启动自动登录」2 条 ·「冷启动首屏落点」1 条 ·「登出链」2 条）：
/// 它们都会真的走一遍登录副作用链，把 presence 通道 owner 建出来。
///
/// ## 本组锁什么
/// 1. `AylaPresenceState` 回收后：`reset()` 与其余写入**不抛、不广播**，但值仍被清空
///    （AGENTS.md §7「关闭必须幂等」+「不回滚事实」）；
/// 2. 两条真实容器路径 —— **presence 已断开** / **presence 曾在线上** ——
///    `container.dispose()` 都不留异常（`takeException() == null`）；
/// 3. 幂等：连续 `disconnect()` 两次不抛，且语义与断开一次相同。
///
/// ⚠️ 为什么用 `testWidgets` 而不是纯 `test`：只有 `TestWidgetsFlutterBinding` 会把
/// 未捕获 zone 错误收进 `takeException()`（Riverpod 的 `runOnDispose` 内部走
/// `runGuarded` → `Zone.current.handleUncaughtError`，**不会**把异常抛回
/// `container.dispose()` 的调用点）。纯 `test` 里同一个 bug 会**静默通过**。
/// 本组不发任何 HTTP 请求，因此不踩 `auth_remember_test.dart` 记录的
/// "binding 把 `HttpOverrides.global` 换成 mock" 那个坑。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart' show AuthTokenStore;
import '../lib/core/ws/presence_ws.dart';
import '../lib/core/ws/ws_manager.dart'
    show WsChannel, WsChannelKind, WsChannelStatus;
import '../lib/state/chat_providers.dart' show realtimeProvider;
import '../lib/state/presence_providers.dart';
import '../lib/state/presence_state.dart';
import '../lib/state/realtime_state.dart';

/// 无令牌的 token store（`WsChannel.connect()` 随即 no-op，不会开真 socket）。
class _NoTokenStore implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

void main() {
  group('AylaPresenceState 生命周期（状态层守卫）', () {
    test('回收后 reset 不抛、不广播，但值仍被清空', () {
      final AylaPresenceState state = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUserStatus('u1', 'dnd')
        ..setConnection(AylaPresenceConnection.online);
      int notified = 0;
      state.addListener(() => notified++);

      state.dispose();
      expect(state.isDisposed, isTrue);

      expect(state.reset, returnsNormally);
      expect(state.users, isEmpty);
      expect(state.statuses, isEmpty);
      expect(state.connection, AylaPresenceConnection.offline);
      expect(notified, 0, reason: '已回收 ⇒ 只改值，不再通知（不得再碰 notifyListeners）');
    });

    test('回收后逐条写入都不抛（通道在途帧 / 迟到的对账结果）', () {
      final AylaPresenceState state = AylaPresenceState();
      state.dispose();

      expect(() => state.setUser('u1', 'online'), returnsNormally);
      expect(() => state.setUserStatus('u1', 'away'), returnsNormally);
      expect(() => state.removeUser('u1'), returnsNormally);
      expect(() => state.replaceAll(<String, String>{'u2': 'online'}),
          returnsNormally);
      expect(() => state.setConnection(AylaPresenceConnection.online),
          returnsNormally);

      // 字段语义不因回收而改变（与 web store 同值），只是不再广播。
      expect(state.users, <String, String>{'u2': 'online'});
      expect(state.statuses, <String, String>{'u1': 'away'});
      expect(state.connection, AylaPresenceConnection.online);
    });

    test('未回收时通知照旧（守卫不得吞掉正常广播）', () {
      final AylaPresenceState state = AylaPresenceState();
      int notified = 0;
      state.addListener(() => notified++);
      state.setConnection(AylaPresenceConnection.connecting);
      state.setUser('u1', 'online');
      state.reset();
      expect(notified, 3);
      expect(state.isDisposed, isFalse);
    });
  });

  group('容器销毁：presence 已断开路径', () {
    testWidgets('disconnect() 之后 container.dispose() 不留异常', (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      final AylaPresenceWsClient client = container.read(presenceWsProvider);
      final AylaPresenceState presence = container.read(presenceStateProvider);
      presence
        ..setUser('u1', 'online')
        ..setConnection(AylaPresenceConnection.online);

      client.disconnect();
      expect(presence.users, isEmpty, reason: '显式断开的语义不变（清空在线集合）');

      container.dispose(); // ← 内部会再跑一次 ref.onDispose(client.disconnect)
      expect(tester.takeException(), isNull);
      expect(presence.isDisposed, isTrue);
    });
  });

  group('容器销毁：presence 曾在线上路径（第二层缺陷的回归锁）', () {
    testWidgets('容器销毁后 client 不再回写已移交的 store（不抛、不覆盖）',
        (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      final AylaPresenceWsClient client = container.read(presenceWsProvider);
      final AylaPresenceState presence = container.read(presenceStateProvider);
      final AylaRealtimeState realtime = container.read(realtimeProvider);

      // 生产形态：连接态已经写过 presence + realtime 两处（见 presence_ws 的 _setConnection）。
      client.debugHandleStatus(WsChannelStatus.connecting);
      client.debugHandleStatus(WsChannelStatus.online);
      presence.setUser('u1', 'online');
      expect(realtime.statusOf(AylaRealtimeChannel.presence).connection,
          AylaRealtimeConnection.online);

      // 显式登出（容器活着）：清空语义必须完好。
      client.disconnect();
      expect(presence.users, isEmpty);
      expect(realtime.statusOf(AylaRealtimeChannel.presence).connection,
          AylaRealtimeConnection.offline);

      // 再次「上线」，随后销毁容器。
      client.debugHandleStatus(WsChannelStatus.online);
      presence.setUser('u1', 'online');

      container.dispose();
      expect(tester.takeException(), isNull);
      expect(client.debugStatesReleased, isTrue,
          reason: '容器销毁 ⇒ 状态所有权已交还容器');
      // 关闭期间**不得**回写：live_state.dart:283–296 记录的正是这条
      // （容器先回收、动作后补 → "used after being disposed"）。
      expect(realtime.statusOf(AylaRealtimeChannel.presence).connection,
          AylaRealtimeConnection.online,
          reason: '容器销毁路径不回写 realtime（回写会命中已被回收的 ChangeNotifier）');
      expect(presence.users, <String, String>{'u1': 'online'},
          reason: '容器销毁路径不回写 presence');
    });

    testWidgets('attach 真实 WsChannel 后容器销毁：断开回调不得回写已回收的 store',
        (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      final AylaPresenceWsClient client = container.read(presenceWsProvider);
      final AylaPresenceState presence = container.read(presenceStateProvider);
      final AylaRealtimeState realtime = container.read(realtimeProvider);

      // 生产形态的通道对象（令牌缺失 ⇒ 不会真的开 socket，但 disconnect 会同步回调 onStatus）。
      final WsChannel channel = WsChannel(
        kind: WsChannelKind.presence,
        path: '/ws/presence/',
        heartbeatInterval: const Duration(seconds: 25),
        tokens: _NoTokenStore(),
        refreshTokens: () async => false,
        connectFactory: (Uri _) => throw StateError('本用例不应开真 socket'),
      );
      client.attach(channel);
      client.connect();
      presence.setUser('u1', 'online');

      container.dispose(); // 内部走 client.dispose() → channel.disconnect() → onStatus(offline)
      expect(tester.takeException(), isNull);
      expect(client.debugStatesReleased, isTrue);
      expect(presence.users, <String, String>{'u1': 'online'},
          reason: '通道关闭回调不得回写已移交的 presence state');
      expect(realtime.statusOf(AylaRealtimeChannel.presence).connection,
          AylaRealtimeConnection.offline,
          reason: 'realtime 档保持初始值，不因关闭回调而被写');
    });

    testWidgets('销毁后到达的在途帧被丢弃（不写已移交的 store）',
        (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      final AylaPresenceWsClient client = container.read(presenceWsProvider);
      final AylaPresenceState presence = container.read(presenceStateProvider);
      presence.setUser('u1', 'online');

      client.dispose(); // = ref.onDispose 挂的那个
      client.debugHandleFrame(<String, dynamic>{
        'type': 'presence.update',
        'data': <String, dynamic>{'user_id': 'u2', 'status': 'online'},
      });
      client.debugHandleStatus(WsChannelStatus.connecting);

      container.dispose();
      expect(tester.takeException(), isNull);
      expect(presence.users, <String, String>{'u1': 'online'},
          reason: '已移交的 store 不再接受本类的写入');
    });
  });

  group('幂等', () {
    test('连续 disconnect() 两次不抛，语义与一次相同', () {
      final AylaPresenceState presence = AylaPresenceState()
        ..setUser('u1', 'online')
        ..setUserStatus('u1', 'dnd')
        ..setConnection(AylaPresenceConnection.online);
      final AylaRealtimeState realtime = AylaRealtimeState();
      final AylaPresenceWsClient client =
          AylaPresenceWsClient(presence: presence, realtime: realtime);

      expect(client.disconnect, returnsNormally);
      expect(client.disconnect, returnsNormally);
      expect(presence.users, isEmpty);
      expect(presence.statuses, isEmpty);
      expect(presence.connection, AylaPresenceConnection.offline);
      expect(realtime.statusOf(AylaRealtimeChannel.presence).connection,
          AylaRealtimeConnection.offline);
    });

    testWidgets('disconnect() 之后容器再销毁（重入同一条关闭链）', (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      final AylaPresenceWsClient client = container.read(presenceWsProvider);
      client.disconnect();
      client.disconnect();
      container.dispose();
      expect(tester.takeException(), isNull);
    });
  });
}
