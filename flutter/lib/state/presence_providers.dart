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
///
/// ### 关闭顺序（2026-10-02 修复）
/// 这里有两个**不同**的关闭入口，不能混用：
/// - **显式登出** ⇒ `client.disconnect()`：容器活着，必须清空 presence 与 realtime 两处状态；
/// - **容器销毁** ⇒ `client.dispose()`（`ref.onDispose` 上挂的就是它）：provider 图回收期间，
///   `presenceStateProvider` / `realtimeProvider` **可能已经先被 dispose**
///   （三个 provider 之间用 `read`、没有依赖边 ⇒ Riverpod 不保证顺序）⇒
///   再回写就是 "used after being disposed"（实测：`test/auth_remember_test.dart` 5 条用例）。
///   故 `dispose()` 先移交状态所有权、再断连接；两者都幂等且可重入。
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
  // ⚠️ **用 `read` 而不是 `watch`**（2026-10-02，与 `chatWsProvider` 同一根因家族）：
  // 两个被依赖的 store 都是高频 notify 的 ⇒ `watch` 会让本 provider 被反复重建，
  // 每次重建都 `ref.onDispose(client.disconnect)` **把 presence 通道断掉**。
  // 二者都是长生命周期单例（引用永不变化），连接对象的生命周期必须长于其通知频率。
  final AylaPresenceWsClient client = AylaPresenceWsClient(
    presence: ref.read(presenceStateProvider),
    realtime: ref.read(realtimeProvider),
  );
  // 容器销毁 ⇒ [AylaPresenceWsClient.dispose]（**不是** disconnect）：先移交共享状态
  // 所有权、再断连接。原因见本文件头的「关闭顺序」与 client 的 dispose 文档 ——
  // 容器销毁期间 presenceState/realtime 两个 store 可能已被回收，回写会抛
  // "used after being disposed"（2026-10-02 真机验收）。
  ref.onDispose(client.dispose);
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
