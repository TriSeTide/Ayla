/// presence 域 Provider 汇总 —— 把 web 的 `stores/presence.ts` + `ws/presence.ts`
/// 接进 Riverpod。
///
/// ## 为什么单独一个文件
/// 与 `group_providers.dart` / `chat_providers.dart` / `room_providers.dart` 同一约定：
/// state 文件保持**纯 ChangeNotifier**（不依赖 Riverpod），provider 集中声明；
/// presence 通道客户端要读 presence 状态与 realtime 状态（后者复用
/// `chat_providers.dart` 的 [realtimeProvider] —— **四通道同一份事实表**，不新开一份）。
///
/// ## 生命周期
/// 非 autoDispose 的全局 provider：路由切换不重建，与 web 的模块级单例 store 语义一致；
/// 登出 / 401 由 [aylaStopPresenceWs]（`WidgetRef` 版）与
/// [aylaStopPresenceWsForContainer]（`ProviderContainer` 版）断开并清空。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ws/presence_ws.dart';
import '../core/ws/ws_manager.dart' show WsManager, wsManager;
import 'chat_providers.dart' show realtimeProvider;
import 'presence_state.dart';

/// presence 全局状态（在线集合 + 状态模式映射 + 本通道连接态）。
final ChangeNotifierProvider<AylaPresenceState> presenceStateProvider =
    ChangeNotifierProvider<AylaPresenceState>((Ref ref) => AylaPresenceState());

/// presence 通道客户端（单例）。
final Provider<AylaPresenceWsClient> presenceWsProvider =
    Provider<AylaPresenceWsClient>((Ref ref) {
  final AylaPresenceWsClient client = AylaPresenceWsClient(
    presence: ref.watch(presenceStateProvider),
    realtime: ref.watch(realtimeProvider),
  );
  ref.onDispose(client.disconnect);
  return client;
});

/// 登录后启动 presence 通道（web `useAuth.login` 的 `presenceClient.connect()`）。
///
/// 幂等：`wsManager.connectAll()` 已开 socket 时不重复连接（见 `core/ws/presence_ws.dart` 文件头）。
AylaPresenceWsClient aylaStartPresenceWs(WidgetRef ref) {
  final AylaPresenceWsClient client = ref.read(presenceWsProvider);
  final WsManager? manager = wsManager;
  if (manager != null) client.attach(manager.presence);
  client.connect();
  return client;
}

/// 登出（页面/壳层用 [WidgetRef]）：断开通道 + 清空在线集合（web `presenceClient.disconnect`）。
void aylaStopPresenceWs(WidgetRef ref) {
  ref.read(presenceWsProvider).disconnect();
}

/// 同上（`ProviderContainer` 版，`main.dart` 的 `onSessionExpired` 用）。
void aylaStopPresenceWsForContainer(ProviderContainer container) {
  container.read(presenceWsProvider).disconnect();
}
