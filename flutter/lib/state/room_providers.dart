/// 房内域（voice / live）Provider 汇总 —— 把 web 的 `stores/voice.ts` /
/// `stores/live.ts` / `ws/voice.ts` / `ws/live.ts` 接进 Riverpod。
///
/// ## 为什么集中在一个文件
/// 与 `chat_providers.dart` 同因：voice WS 客户端要读 voice 状态与 realtime 状态，
/// 散在各文件会形成环形 import ⇒ 集中声明，state 文件保持**纯 ChangeNotifier**
/// （不依赖 Riverpod）。realtime 状态复用 `chat_providers.dart` 的
/// [realtimeProvider]（**四通道同一份事实表**，不新开一份）。
///
/// ## 生命周期
/// 非 autoDispose 的全局 provider：路由切换（`/voice` ↔ `/voice/:id`、
/// `/live` ↔ `/live/:id` ↔ `/live/start/:id`）不重建，
/// 与 web 的模块级单例 store 语义一致；登出时由 [aylaStopRooms] 统一断开与清空。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/net/dio_client.dart' show DioClient;
import '../core/ws/live_ws.dart';
import '../core/ws/room_frames.dart' show AylaRoomDirectoryBridge;
import '../core/ws/voice_ws.dart';
import '../core/ws/ws_manager.dart' show WsManager, wsManager;
import '../pages/live_support.dart' show aylaCloseLiveMiniPlayer;
import 'auth_state.dart';
import 'chat_providers.dart' show chatWsProvider, realtimeProvider;
import 'directory_events.dart';
import 'live_state.dart';
import 'voice_state.dart';

/// voice 全局状态（成员表 / 当前频道 / 媒体与应用层连接态）。
final ChangeNotifierProvider<AylaVoiceState> voiceStateProvider =
    ChangeNotifierProvider<AylaVoiceState>((Ref ref) => AylaVoiceState());

/// live 全局状态（当前直播间 / SRS 判定 / 弹幕队列 / 在看人数）。
final ChangeNotifierProvider<AylaLiveState> liveStateProvider =
    ChangeNotifierProvider<AylaLiveState>((Ref ref) => AylaLiveState());

/// 目录热更新事件总线（频道帧 → 目录页）。
final ChangeNotifierProvider<AylaDirectoryEvents> directoryEventsProvider =
    ChangeNotifierProvider<AylaDirectoryEvents>(
  (Ref ref) => AylaDirectoryEvents(),
);

/// voice 应用层 WS 客户端（单例）。
final Provider<AylaVoiceWsClient> voiceWsProvider = Provider<AylaVoiceWsClient>(
  (Ref ref) {
    final AylaVoiceWsClient client = AylaVoiceWsClient(
      voiceState: ref.watch(voiceStateProvider),
      realtime: ref.watch(realtimeProvider),
    );
    ref.onDispose(client.disconnect);
    return client;
  },
);

/// 直播弹幕 WS 客户端（单例；每频道一条连接，切频道由会话层负责断开旧连接）。
///
/// 令牌取自 `DioClient`（未 init ⇒ null ⇒ 连接 no-op，**不伪造已连接**）。
final Provider<AylaLiveWsClient> liveWsProvider = Provider<AylaLiveWsClient>(
  (Ref ref) {
    final AylaLiveWsClient client = AylaLiveWsClient(
      accessToken: () => DioClient.instance.accessToken,
      refreshTokens: () => DioClient.instance.refreshAccessToken(),
    );
    ref.onDispose(client.disconnect);
    return client;
  },
);

/// 房内域目录帧桥（chat WS 的 `voice.channel.*` / `live.*` / `boardgame.room.*` 分支）。
///
/// ⚠️ **必须挂上才会生效**：帧从 chat 通道来，桥靠 `chat.onFrame` 接 —— 由
/// [aylaStartRoomFrames] 在 app 启动时挂一次（web 侧是 `chat.ts` 的模块级单例 +
/// `ensureDirectoryTracking()`，同样是启动期挂载）。
final Provider<AylaRoomDirectoryBridge> roomDirectoryBridgeProvider =
    Provider<AylaRoomDirectoryBridge>((Ref ref) {
  final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
    voiceState: ref.watch(voiceStateProvider),
    liveState: ref.watch(liveStateProvider),
    directory: ref.watch(directoryEventsProvider),
    currentUserId: () => ref.read(authNotifierProvider).user?.id,
  );
  ref.onDispose(bridge.detach);
  return bridge;
});

/// 启动期挂载目录帧桥（`main.dart` 在 `initWsManager` 之后调用一次；幂等）。
///
/// 与 chat 通道的连接时机**解耦**：桥只登记 `onFrame` 回调，chat 未连时不消费任何帧。
void aylaStartRoomFrames(ProviderContainer container) {
  final AylaRoomDirectoryBridge bridge =
      container.read(roomDirectoryBridgeProvider);
  bridge.attach(container.read(chatWsProvider));
}

/// 同上（`WidgetRef` 版；登录后的收尾/重连路径可再挂一次，幂等）。
void aylaStartRoomFramesForRef(WidgetRef ref) {
  ref.read(roomDirectoryBridgeProvider).attach(ref.read(chatWsProvider));
}

/// 登录后启动 voice 通道（web `VoiceHubPage.tsx:144–146` 的 `voiceWS.connect()`）。
///
/// 幂等：重复调用只重连（`WsChannel` 自身按 token 重建连接）。
AylaVoiceWsClient aylaStartVoiceWs(WidgetRef ref) {
  final AylaVoiceWsClient client = ref.read(voiceWsProvider);
  final WsManager? manager = wsManager;
  if (manager != null) client.attach(manager.voice);
  client.connect();
  return client;
}

/// 登出 / 401 过期：断开两条房内通道 + 解绑目录帧桥 + 清空房内状态。
void aylaStopRooms(WidgetRef ref) {
  aylaStopLiveMiniPlayer();
  ref.read(roomDirectoryBridgeProvider).detach();
  ref.read(voiceWsProvider).disconnect();
  ref.read(liveWsProvider).disconnect();
  ref.read(voiceStateProvider).reset();
  ref.read(liveStateProvider).reset();
  ref.read(directoryEventsProvider).reset();
}

/// 同上（`ProviderContainer` 版，`main.dart` 的 `onSessionExpired` 用）。
void aylaStopRoomsForContainer(ProviderContainer container) {
  aylaStopLiveMiniPlayer();
  container.read(roomDirectoryBridgeProvider).detach();
  container.read(voiceWsProvider).disconnect();
  container.read(liveWsProvider).disconnect();
  container.read(voiceStateProvider).reset();
  container.read(liveStateProvider).reset();
  container.read(directoryEventsProvider).reset();
}

/// 登出 / 401 过期：完整销毁窄屏浮动小窗持有的会话（唯一 owner）。
///
/// 小窗宿主是**模块级**注册表（`pages/live_support.dart`），AppShell 卸载不会触发任何页面
/// 的 `dispose` ⇒ 必须在这条统一收口里显式销毁，否则 WS 连接与播放器会越过登录周期存活。
/// 幂等（无小窗时是 no-op）。
void aylaStopLiveMiniPlayer() {
  unawaited(aylaCloseLiveMiniPlayer());
}
