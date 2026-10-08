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

import '../core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../widgets/voice/voice_channels.dart' show AylaVoiceCardData;

import '../core/net/dio_client.dart' show DioClient;
import '../core/ws/live_ws.dart';
import '../core/ws/posts_frames.dart' show AylaPostsFramesBridge;
import '../core/ws/room_frames.dart' show AylaRoomDirectoryBridge;
import '../core/ws/voice_ws.dart';
import '../core/ws/ws_manager.dart' show WsManager, wsManager;
import '../pages/live_support.dart' show aylaCloseLiveMiniPlayer;
import 'auth_state.dart';
import 'boardgame_store.dart' show AylaBoardgameStore, aylaBoardgameStore;
import 'chat_providers.dart'
    show chatStateProvider, chatWsProvider, realtimeProvider;
import 'directory_events.dart';
import 'directory_store.dart' show aylaDirectoryStore;
import 'directory_tracking.dart' show AylaDirectoryTracking;
import 'live_state.dart';
import 'posts_store.dart' show aylaPostsStore;
import 'voice_state.dart';

/// voice 全局状态（成员表 / 当前频道 / 媒体与应用层连接态）。
final ChangeNotifierProvider<AylaVoiceState> voiceStateProvider =
    ChangeNotifierProvider<AylaVoiceState>((Ref ref) => AylaVoiceState());

/// live 全局状态（当前直播间 / SRS 判定 / 弹幕队列 / 在看人数）。
final ChangeNotifierProvider<AylaLiveState> liveStateProvider =
    ChangeNotifierProvider<AylaLiveState>((Ref ref) => AylaLiveState());

/// 目录热更新事件总线 —— **已退役**（2026-10-08）。
///
/// ## 为什么退役
/// 它是「帧 → **广播给页面** → 每个页面自己 patch」的旧架构：页面漏订阅就完全没有
/// 热更新（用户实报的语音房/直播/桌游/帖子列表页 + 群内第 2 列侧栏全都没有），
/// 且与 web 不符 —— web 的目录接口**是**域 store 的查询投影，帧只落 store，
/// 页面只读缓存（`stores/directory.ts:143–146 / 205–259`；消息域同理，
/// `ws/chat.ts:444` + Flutter `core/ws/chat_ws.dart:620`）。
///
/// 现架构 = `state/directory_tracking.dart`（store 订阅通路，负责新增/更新/重排/人数）
/// + `core/ws/room_frames.dart`（帧直连通路，负责 `createdIds` 与删除摘除）。
///
/// ⚠️ **本 provider 只为历史测试与兼容档保留**，生产不再消费：
/// - `roomDirectoryBridgeProvider` 只在**未注入 store** 时把它当兜底出口；
///   生产恒注入 `aylaDirectoryStore` ⇒ 兜底不生效。
/// - 新增代码**不得**订阅它（否则又回到「漏订阅就没热更新」）。
@Deprecated('目录热更新已改为「帧 → store」；请改用 aylaDirectoryStore')
final ChangeNotifierProvider<AylaDirectoryEvents> directoryEventsProvider =
    ChangeNotifierProvider<AylaDirectoryEvents>(
  (Ref ref) => AylaDirectoryEvents(),
);

/// voice 应用层 WS 客户端（单例）。
///
/// ⚠️ **依赖必须用 `read` 而不是 `watch`**（2026-10-02，与 `chatWsProvider` 同源的根因修复）：
/// 两个被依赖的 store 都是**高频 notify** 的（`voiceState` 收成员帧就 notify、
/// `realtime` 收连接状态就 notify）⇒ `watch` 会让本 provider 被反复重建，
/// 每次重建都会 `ref.onDispose(client.disconnect)` **把 voice WS 连接断掉**。
/// 它们是长生命周期单例（引用永不变化），连接对象的生命周期必须长于其通知频率。
final Provider<AylaVoiceWsClient> voiceWsProvider = Provider<AylaVoiceWsClient>(
  (Ref ref) {
    final AylaVoiceWsClient client = AylaVoiceWsClient(
      voiceState: ref.read(voiceStateProvider),
      realtime: ref.read(realtimeProvider),
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
///
/// 桥**直接写目录 store**（`directoryStore:` 注入）—— 与消息域的
/// `core/ws/chat_ws.dart:620` 的 `_message.upsertMessage(...)` 同型；
/// 页面只读 store，因此**不存在「页面漏订阅就没有热更新」**这一类缺陷。
final Provider<AylaRoomDirectoryBridge> roomDirectoryBridgeProvider =
    Provider<AylaRoomDirectoryBridge>((Ref ref) {
  // ⚠️ **依赖必须用 `read` 而不是 `watch`**（2026-10-02，与 `chatWsProvider` 同源的根因修复）：
  // 三个被依赖的 store 全是高频 notify 的（voice/live 收帧就 notify、directory 收目录事件就 notify）
  // ⇒ `watch` 会让本 provider 被反复重建，每次重建都 `ref.onDispose(bridge.detach)`
  // **把帧桥从 chat WS 上摘掉** ⇒ voice/live/boardgame 帧全部不再被处理。
  // 桥本身是无状态的转发件，引用变化会破坏「只挂一次」的前提。
  // ⚠️ **闭包内不能用 `ref.read`**（与 `chatWsProvider` 同一条口径，见其
  // 「必须捕获 notifier 实例」的注释）：`currentUserId` 是在**帧到达时**才执行的，
  // 那时本 provider 的依赖可能刚被标脏、尚未 rebuild ⇒ `ProviderElementBase.read`
  // 命中断言「Cannot use ref functions after the dependency of a provider changed but
  // before the provider rebuilt」，**帧处理中断**。
  // 正解：先捕获根容器，容器级 `read` 不带该断言。
  final ProviderContainer container = ref.container;
  final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
    voiceState: ref.read(voiceStateProvider),
    liveState: ref.read(liveStateProvider),
    // web `stores/directory.ts` 的模块级 `useDirectoryStore`（帧直连通路的落点）。
    directoryStore: aylaDirectoryStore,
    boardgameStore: aylaBoardgameStore,
    currentUserId: () => container.read(authNotifierProvider).user?.id,
  );
  ref.onDispose(bridge.detach);
  return bridge;
});

/// 目录缓存的 **store 订阅通路** —— web `ensureDirectoryTracking`
/// （`stores/directory.ts:205–219`）的等价物（模块级单例，`main.dart` 启动期挂一次）。
///
/// 实现见 `state/directory_tracking.dart`（本文件只做 Riverpod 侧的装配）。
final AylaDirectoryTracking directoryTracking = AylaDirectoryTracking();

/// 启动期装配目录 store 订阅通路（幂等；`main.dart` 与 `aylaStartRoomFrames` 同处调用）。
void aylaStartDirectoryTracking({
  required AylaVoiceState voiceState,
  required AylaLiveState liveState,
  required AylaBoardgameStore boardgameStore,
  required String? Function() currentUserId,
}) => directoryTracking.start(
  voiceState: voiceState,
  liveState: liveState,
  boardgameStore: boardgameStore,
  currentUserId: currentUserId,
  store: aylaDirectoryStore,
);

/// 登出 / 会话过期：停掉订阅通路（web `disposeDirectoryTracking`，`stores/directory.ts:200–204`）。
void aylaStopDirectoryTracking() => directoryTracking.stop();

/// 桌游目录取页 → 全局 store 的落地钩子（web `stores/directory.ts:313–317`：
/// `else useBoardgameStore.getState().upsertRoom(item as GameRoom)`）。
///
/// ## 为什么用「可注入钩子」而不是在 store 里写 game 分支
/// [AylaDirectoryStore] 是 **kind 无关的通用件**（三个 kind 共用同一套 record/游标/
/// 失效逻辑），在其中内建 `game` 专用分支会污染通用契约、也把 state 层的 store
/// 依赖带进 store 文件（列依赖 → 反向依赖）。web 那边之所以能就地写，是因为
/// zustand store 是**模块级免依赖**的（`directory.ts` 直接 import 三个域 store，
/// 没有 Flutter 的 import 环问题）。
///
/// 因此这里选**方案 B（钩子）**：通用件只留一个 `Map<kind, upsert>` 承接口
/// （`directory_store.dart` 的 `itemUpsertHooks`），生产侧由本文件在启动时注入。
/// 收益：通用件零域知识；代价：钩子是**可变状态**，必须与 store 同生命周期
/// （见 [aylaStopPostsFrames] / [aylaStopRooms] 的注销与末尾的兜底注销）。
///
/// ## 覆盖范围（有意收窄，不伪造）
/// web 对三个 kind 都 upsert（live / voice / game）；Flutter 侧**只接 game**：
/// - live / voice 的目录条目类型（`AylaLiveCardData` / `AylaVoiceCardData`）是
///   **卡片投影**，缺 `created_at` / `allowed_group_ids`（活跃度判定要用的字段），
///   而 `state/live_state.dart` / `state/voice_state.dart` 的表键是它们自己的快照类型
///   ⇒ 需要一次投影转换，属 **live/voice 源补齐轮**（与本轮的 `game` 不同：
///   `AylaDirectoryGameEntry.room` 本身就是完整的 `AylaGameRoom`，直接落，无需转换）。
/// - 这里如实登记为**未覆盖**，不假装已接。
void _onGameDirectoryItem(Object item) {
  if (item is! AylaDirectoryGameEntry) return;
  aylaBoardgameStore.upsertRoom(item.room);
}

/// posts 帧桥（chat WS 的 `post.*` 四条分支）—— web `ws/chat.ts:766–840`。
///
/// ⚠️ **必须挂上才会生效**：与 [roomDirectoryBridgeProvider] 同因（帧从 chat 通道来，
/// 桥靠 `chat.onFrame` 接，由 [aylaStartPostsFrames] 在 app 启动时挂一次）。
final Provider<AylaPostsFramesBridge> postsFramesBridgeProvider =
    Provider<AylaPostsFramesBridge>((Ref ref) {
  // ⚠️ 与 `roomDirectoryBridgeProvider` 同口径：**依赖用 `read`、闭包用容器级 `read`**。
  // `chatStateProvider` 是高频 notify 的（收到消息就 notify）⇒ `watch` 会让本桥被
  // 反复重建、每次 `ref.onDispose(bridge.detach)` 把 posts 帧桥摘掉 ⇒ post.* 帧不再处理。
  // `currentUserId` 在帧到达时执行，闭包内 `ref.read` 会命中「依赖已变、尚未 rebuild」断言。
  final ProviderContainer container = ref.container;
  final AylaPostsFramesBridge bridge = AylaPostsFramesBridge(
    postsStore: aylaPostsStore,
    chatState: ref.read(chatStateProvider),
    currentUserId: () => container.read(authNotifierProvider).user?.id,
  );
  ref.onDispose(bridge.detach);
  return bridge;
});

/// 启动期挂载目录帧桥 + 注册桌游目录落地钩子
/// （`main.dart` 在 `initWsManager` 之后调用一次；幂等）。
///
/// 与 chat 通道的连接时机**解耦**：桥只登记 `onFrame` 回调，chat 未连时不消费任何帧。
void aylaStartRoomFrames(ProviderContainer container) {
  final AylaRoomDirectoryBridge bridge =
      container.read(roomDirectoryBridgeProvider);
  bridge.attach(container.read(chatWsProvider));
  _wireDirectoryTracking(
    voiceState: container.read(voiceStateProvider),
    liveState: container.read(liveStateProvider),
    currentUserId: () => container.read(authNotifierProvider).user?.id,
  );
}

/// 目录热更新的**共同装配**（两条通路 + 取页落地钩子）—— 三个入口共用一份，
/// 避免容器版 / WidgetRef 版各写一遍导致漂移。
void _wireDirectoryTracking({
  required AylaVoiceState voiceState,
  required AylaLiveState liveState,
  required String? Function() currentUserId,
}) {
  _registerDirectoryItemHooks(voiceState: voiceState, liveState: liveState);
  // ★ 目录缓存的 **store 订阅通路**（web `ensureDirectoryTracking`，:205–219）：
  // 三个域 store 一变就把新旧快照 diff 进目录缓存 ⇒ 所有读缓存的页面自动热更新。
  // ⚠️ 必须启动期装配（web 同：`loadDirectory` 首次调用时装配）——WS 帧可能在
  // 任何页面取数之前到达（chat_ws 已经写域 store），懒装配会漏掉这批早期帧。
  aylaStartDirectoryTracking(
    voiceState: voiceState,
    liveState: liveState,
    boardgameStore: aylaBoardgameStore,
    currentUserId: currentUserId,
  );
}

/// 目录取页结果 → 全局域 store 的落地钩子（web `stores/directory.ts:310–320`）。
///
/// web 对**三个 kind** 都 upsert（live / voice / game）；此前 Flutter 只接了 game
/// （见下一段注释的登记），本轮补齐 voice / live —— 两者的域 store 现在都有完整的
/// 描述符类型（`AylaVoiceChannelSnapshot` / `AylaLiveChannelSnapshot`），
/// 投影转换是纯搬运、无字段丢失。
void _registerDirectoryItemHooks({
  required AylaVoiceState voiceState,
  required AylaLiveState liveState,
}) {
  aylaDirectoryStore.itemUpsertHooks[AylaDirectoryKind.voice] =
      (Object item) => _onVoiceDirectoryItem(voiceState, item);
  aylaDirectoryStore.itemUpsertHooks[AylaDirectoryKind.live] =
      (Object item) => _onLiveDirectoryItem(liveState, item);
  aylaDirectoryStore.itemUpsertHooks[AylaDirectoryKind.game] =
      _onGameDirectoryItem;
}

/// 取页结果（voice 条目）→ `voiceState`（web `:315` 的 `upsertChannel`）。
///
/// 目录条目 → 快照是**逐字段搬运**（快照的字段是目录条目的超集；
/// `room_name` / `last_occupied_at` / `last_vacant_at` 各自对位）。
/// 缺席即缺席（不造默认值）——`ownerNickname` 为 null 时快照也是 null。
void _onVoiceDirectoryItem(AylaVoiceState state, Object item) {
  if (item is! AylaDirectoryVoiceEntry) return;
  final AylaVoiceCardData card = item.card;
  state.upsertChannel(
    AylaVoiceChannelSnapshot(
      id: card.id,
      name: card.name,
      roomName: item.roomName,
      ownerId: item.ownerId,
      ownerNickname: card.ownerNickname,
      memberCount: card.memberCount,
      visibility: card.visibility,
      allowedGroupNames: card.allowedGroupNames,
      groupName: card.groupName,
      mine: card.mine,
      createdAt: item.createdAt,
      lastOccupiedAt: item.lastOccupiedAt,
      lastVacantAt: item.lastVacantAt,
    ),
  );
}

/// 取页结果（live 条目）→ `liveState`（web `:314` 的 `upsertChannel`）。
void _onLiveDirectoryItem(AylaLiveState state, Object item) {
  if (item is! AylaDirectoryLiveEntry) return;
  state.upsertChannel(
    AylaLiveChannelSnapshot(
      id: item.card.id,
      title: item.card.title,
      description: item.description,
      cover: item.card.cover,
      status: item.card.status,
      ownerId: item.ownerId,
      ownerNickname: item.card.ownerNickname,
      isOwner: item.isOwner,
      visibility: item.card.visibility?.wire,
      allowedGroupIds: item.allowedGroupIds,
      groupName: item.card.groupName,
      allowedGroupNames: item.card.allowedGroupNames,
      viewerCount: item.card.viewerCount,
      startedAt: item.startedAt,
      endedAt: item.endedAt,
      createdAt: item.createdAt,
    ),
  );
}

/// 同上（`WidgetRef` 版；登录后的收尾/重连路径可再挂一次，幂等）。
void aylaStartRoomFramesForRef(WidgetRef ref) {
  ref.read(roomDirectoryBridgeProvider).attach(ref.read(chatWsProvider));
  _wireDirectoryTracking(
    voiceState: ref.read(voiceStateProvider),
    liveState: ref.read(liveStateProvider),
    currentUserId: () => ref.read(authNotifierProvider).user?.id,
  );
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

/// 登出 / 401 过期：断开两条房内通道 + 解绑两条帧桥 + 清空房内状态。
void aylaStopRooms(WidgetRef ref) {
  aylaStopLiveMiniPlayer();
  ref.read(roomDirectoryBridgeProvider).detach();
  aylaStopPostsFrames(ref);
  ref.read(voiceWsProvider).disconnect();
  ref.read(liveWsProvider).disconnect();
  // web `disposeDirectoryTracking`（`stores/directory.ts:200–204`）：退订 + reset。
  aylaStopDirectoryTracking();
  ref.read(voiceStateProvider).reset();
  ref.read(liveStateProvider).reset();
}

/// 同上（`ProviderContainer` 版，`main.dart` 的 `onSessionExpired` 用）。
void aylaStopRoomsForContainer(ProviderContainer container) {
  aylaStopLiveMiniPlayer();
  container.read(roomDirectoryBridgeProvider).detach();
  aylaStopPostsFramesForContainer(container);
  container.read(voiceWsProvider).disconnect();
  container.read(liveWsProvider).disconnect();
  // 同 [aylaStopRooms]：停订阅通路（web `disposeDirectoryTracking`）。
  aylaStopDirectoryTracking();
  container.read(voiceStateProvider).reset();
  container.read(liveStateProvider).reset();
}

/// 启动期挂载 posts 帧桥（`main.dart` 调用一次；幂等）。
///
/// 与 chat 通道的连接时机**解耦**：只登记 `onFrame` 回调，chat 未连时不消费任何帧。
void aylaStartPostsFrames(ProviderContainer container) {
  container.read(postsFramesBridgeProvider).attach(container.read(chatWsProvider));
}

/// 同上（`WidgetRef` 版；登录后的收尾/重连路径可再挂一次，幂等）。
void aylaStartPostsFramesForRef(WidgetRef ref) {
  ref.read(postsFramesBridgeProvider).attach(ref.read(chatWsProvider));
}

/// 登出 / 401 过期：解绑 posts 帧桥 + 清空 posts / boardgame 两份全局 store。
///
/// 与 web 的差异（如实登记）：web 的 `stores/posts.ts` / `stores/boardgame.ts` 在
/// `auth.ts:125–143` 的 `logout` 里**没有**被 reset（那两个 store 的 `reset` 只被测试调用）；
/// Flutter 侧在这里显式 reset，理由是**账号隔离**：这两份 store 现在是模块级单例
/// （跨登录周期存活），不 reset 的话下一位登录者会读到上一位的帖子/房间表。
/// 与既有链上的 `aylaSocialStore.reset()` / `aylaPostTabCache.clear()`
/// （`auth_bootstrap.dart:120–128`）同一口径。
void aylaStopPostsFrames(WidgetRef ref) {
  ref.read(postsFramesBridgeProvider).detach();
  aylaPostsStore.reset();
  aylaBoardgameStore.reset();
  aylaDirectoryStore.itemUpsertHooks.clear();
}

/// 同上（`ProviderContainer` 版）。
///
/// ⚠️ **不做账守卫**（2026-10-01 实测发现的必要修正）：`container.read(postsFramesBridgeProvider)`
/// 会**创建**该 provider ⇒ 未登录时（`main.dart` 的 `onSessionExpired` 可能在任何一次
/// 连接前触发）登出也会把 posts 帧桥实例建出来并 `ref.onDispose` 挂上。
/// 而桥的构造**只做注入**（不建 socket、不登记订阅），创建后 `attach` 才会挂 `onFrame`
/// ⇒ 这里改成「**只解绑已存在的实例**」，避免为登出路径凭空造出一个对象。
void aylaStopPostsFramesForContainer(ProviderContainer container) {
  if (container.exists(postsFramesBridgeProvider)) {
    container.read(postsFramesBridgeProvider).detach();
  }
  aylaPostsStore.reset();
  aylaBoardgameStore.reset();
  aylaDirectoryStore.itemUpsertHooks.clear();
}

/// 登出 / 401 过期：完整销毁窄屏浮动小窗持有的会话（唯一 owner）。
///
/// 小窗宿主是**模块级**注册表（`pages/live_support.dart`），AppShell 卸载不会触发任何页面
/// 的 `dispose` ⇒ 必须在这条统一收口里显式销毁，否则 WS 连接与播放器会越过登录周期存活。
/// 幂等（无小窗时是 no-op）。
void aylaStopLiveMiniPlayer() {
  unawaited(aylaCloseLiveMiniPlayer());
}
