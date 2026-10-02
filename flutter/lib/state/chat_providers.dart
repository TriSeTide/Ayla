/// 消息域 Provider 汇总 —— 把 web 的 6 个会话相关 store + WS 客户端接进 Riverpod。
///
/// ## 为什么集中在一个文件
/// 项目既有约定是「provider 与 state 同文件」（`auth_state.dart` / `shell_state.dart`）；
/// 消息域有 6 个互相引用的控制器 + 1 个 WS 客户端（后者要读全部前者），散在各文件会形成
/// 环形 import ⇒ 集中一处声明，state 文件保持**纯 ChangeNotifier**（不依赖 Riverpod）。
///
/// ## 生命周期
/// 全部是**非 autoDispose** 的全局 provider：路由切换（`/messages` ↔ `/chat/:id`）不重建，
/// 与 web 的模块级单例 store 语义一致；登出时由 [AylaChatWsClient.disconnect] 与页面清空。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/elysia_api.dart';
import '../core/models/elysia_profile.dart';
import '../core/ws/chat_ws.dart';
import '../core/ws/ws_manager.dart';
import 'auth_state.dart';
import 'badges_state.dart';
import 'chat_drafts.dart';
import 'chat_state.dart';
import 'group_providers.dart' show subgroupStateProvider;
import 'message_state.dart';
import 'notices_state.dart';
import 'realtime_state.dart';
import 'social_store.dart'
    show AylaSocialTracking, aylaSocialStore;
import 'subgroup_state.dart' show AylaSubGroupState;

/// chat 全局状态（会话列表 + 未读投影 + 活跃排序）。
final ChangeNotifierProvider<AylaChatState> chatStateProvider =
    ChangeNotifierProvider<AylaChatState>((Ref ref) => AylaChatState());

/// message 全局状态（按会话分桶的消息缓存）。
///
/// 装配时接上两个**子群域钩子**：
/// - **子群活跃度**（web `stores/message.ts:97/136/177/326` 的
///   `useSubGroupStore.getState().recordMessageActivity(...)`）—— 消息落库即推进
///   子群 `last_message_seq`，宽屏侧栏的子群活跃度排序据此即时刷新；
/// - **逐条已读投影**（web `stores/message.ts:85–88` 的 `withConfirmedRead`，
///   用于 96 / 135 / 176 / 324 四处入库路径）—— 已确认序号入库即 `readByMe=true`。
final ChangeNotifierProvider<AylaMessageState> messageStateProvider =
    ChangeNotifierProvider<AylaMessageState>((Ref ref) {
  final AylaMessageState state = AylaMessageState();
  state.onSubgroupActivity = (String convId, String? subgroupId, int seq) =>
      ref
          .read(subgroupStateProvider)
          .recordMessageActivity(convId, subgroupId, seq);
  // 入库前的逐条已读投影（web `stores/message.ts:85–88` 的 `withConfirmedRead`）：
  // websocket 路径自己查过（`chat_ws.dart:579`），REST 历史 / 乐观回包路径靠这一步，
  // 否则「服务端早已确认过的序号」在历史里读回 `readByMe=false`。
  state.isConfirmedRead = (String convId, int seq) =>
      ref.read(subgroupStateProvider).isSubgroupMessageConfirmedRead(convId, seq);
  return state;
});

/// 社交缓存订阅装配（web `ensureSocialTracking`，`stores/social.ts:108–120`）。
///
/// ## 为什么落在 chat_providers（而不是 room_providers）
/// web 的三条订阅里，两条读的是 **chat 域**的 store（`useChatStore.conversations` /
/// `useSubGroupStore.byGroup`），auth 那条由 `AylaSocialStore.userId` setter 承担
/// ⇒ **两个源都在本文件已经声明**（[chatStateProvider] / `group_providers.dart` 的
/// [subgroupStateProvider]），这里装配不需要新开跨域依赖。
/// 声明的 provider 是 [socialTrackingProvider]（启动期由 `main.dart` 建立）。
///
/// ⚠️ 与 web 的一处**机制差异**：web 在 `loadSocial` 首次调用时才
/// `ensureSocialTracking()`（懒装配，`stores/social.ts:145`）；Flutter 侧改由
/// 启动期显式建立（`main.dart` 的 `aylaStartSocialTracking`）——
/// 理由是 WS 帧可能在**任何**页面 `loadSocial` 之前就到达（`chat_ws` 把新消息写进
/// `chatState`），懒装配会让这批早期帧漏掉对账。装配本身零副作用（只挂监听）。
final Provider<AylaSocialTracking> socialTrackingProvider =
    Provider<AylaSocialTracking>((Ref ref) {
  // ⚠️ **用 `read` 而不是 `watch`**（2026-10-02，与 `chatWsProvider` 同一根因家族）：
  // 这两个 store 都是高频 notify 的 ⇒ `watch` 会让本 provider 被反复重建，
  // 每次重建都 `ref.onDispose(tracking.dispose)` **解绑监听再重绑**。
  // 虽然解绑/重绑不丢连接（比 chatWs 那种断连轻），但：① 无谓开销；
  // ② **重绑窗口期内到达的帧会漏掉对账**（sync 是挂在 changeNotifier 上的）。
  // 二者都是长生命周期单例（引用永不变化），`read` 才是正确语义。
  final AylaChatState chatState = ref.read(chatStateProvider);
  final AylaSubGroupState subgroupState = ref.read(subgroupStateProvider);
  final AylaSocialTracking tracking = AylaSocialTracking(store: aylaSocialStore)
    ..bind(chatState: chatState, subgroupState: subgroupState)
    // ⚠️ **取页回流装配**（web `stores/social.ts:170–181`）：`loadSocial` 的结果必须
    // 同时写回 chatState / subgroupState，否则 `chat_ws.dart:656` 的 `if (conv != null)`
    // 门控失效、发消息不 bump 排序（用户实报「根本不排上去」）。
    // 不接这一步 = 上面那半截（chatState → social 的对账）只有单向。
    ..bindRehydration(
      chatState: chatState,
      subgroupState: subgroupState,
    );
  ref.onDispose(tracking.dispose);
  return tracking;
});

/// 启动期建立社交缓存订阅（`main.dart` 调一次；幂等 —— provider 只建一次）。
void aylaStartSocialTracking(ProviderContainer container) {
  container.read(socialTrackingProvider);
}

/// 同上（`WidgetRef` 版；登录后的收尾/重连路径可再调一次，幂等）。
void aylaStartSocialTrackingForRef(WidgetRef ref) {
  ref.read(socialTrackingProvider);
}

/// 会话草稿（落盘；见 `state/chat_drafts.dart` 的偏离说明）。
final ChangeNotifierProvider<AylaChatDraftsController> chatDraftsProvider =
    ChangeNotifierProvider<AylaChatDraftsController>(
  (Ref ref) {
    final AylaChatDraftsController controller = AylaChatDraftsController();
    unawaited(controller.load());
    return controller;
  },
);

/// 实时通知（认证消息 tab 的实时退群通知等）。
final ChangeNotifierProvider<AylaNoticesController> noticesProvider =
    ChangeNotifierProvider<AylaNoticesController>(
  (Ref ref) => AylaNoticesController(),
);

/// 实时连接状态（四通道；**只记连接事实，不顶替业务数据**）。
final ChangeNotifierProvider<AylaRealtimeState> realtimeProvider =
    ChangeNotifierProvider<AylaRealtimeState>((Ref ref) => AylaRealtimeState());

/// 全站未读聚合（`GET /me/badges/`）。
final ChangeNotifierProvider<AylaBadgesController> badgesProvider =
    ChangeNotifierProvider<AylaBadgesController>(
  (Ref ref) => AylaBadgesController(),
);

/// 爱莉档案（未初始化 404 ⇒ null；多处消费只取一次）。
final FutureProvider<AylaElysiaProfile?> elysiaProfileProvider =
    FutureProvider<AylaElysiaProfile?>((Ref ref) => AylaElysiaApi.getProfile());

/// chat 通道客户端（单例）。
final Provider<AylaChatWsClient> chatWsProvider = Provider<AylaChatWsClient>(
  (Ref ref) {
    // ⚠️ **必须捕获 notifier 实例**，不能在回调里 @ref.read(authNotifierProvider)@。
    //
    // 回调是在**帧到达时**才执行的，而那时 @chatWsProvider@ 的依赖（本 provider
    // @@watch@ 了 chatState 等）可能刚被标记为 dirty、还没 rebuild ⇒ Riverpod 的
    // @ProviderElementBase.read@ 会命中断言
    // @Cannot use ref functions after the dependency of a provider changed but
    // before the provider rebuilt@（@riverpod-2.6.1/lib/src/framework/element.dart:673–678@）。
    //
    // 实测（本轮端到端锁 @group_pages_test.dart@ 的 rail 组）：根因 A 修好后
    // @_onMessageNew@ 的 @if (conv != null)@ 第一次真的命中 ⇒ @_previewSenderName@
    // 首次被调用 ⇒ 该断言当场抛出，**帧处理中断**。此前这段是死代码，故从未暴露。
    //
    // 口径：先拿到根容器（@Ref.container@，riverpod-2.6.1 的公开成员），
    // 再由它读**当前** auth 状态 —— 容器级 @read@ 不带 provider 的
    // @_didChangeDependency@ 断言，正是这里需要的（只读一个与本 provider 无关的值）。
    // ⚠️⚠️ **这里必须用 `read` 而不是 `watch`**（2026-10-02 根因修复，
    // 用户实报「整个 Flutter 几乎没有热更新」的总根因）。
    //
    // ## 事故（实测证据）
    // 原来六个依赖全用 `ref.watch`。它们都是**高频 notify 的 store**
    // （`chatStateProvider` 收到消息就 notify、`subgroupStateProvider` 收到子群帧就 notify…）
    // ⇒ Riverpod 每收到一次通知就把本 provider 标脏 ⇒ **下一次读取时重建**：
    // ```
    // [CHATWS-PROVIDER-BUILD] 新实例
    // [CHATWS-PROVIDER-DISPOSE] 旧实例被销毁（连接随之断开）
    // [CHATWS-PROVIDER-BUILD] 新实例          ← 又重建
    // [CHAT-SUBSCRIBE] channel=NULL            ← 新实例从没 attach 过 ⇒ 帧发不出去
    // ```
    // 每次重建都会：① 新建 client（`_channel == null`）；② 旧 client 走
    // `ref.onDispose(client.disconnect)` **把 WS 连接断掉**。
    // 结果：`registerAuthorizedGroups()` 拿到 10 个群后调 `subscribe()`，
    // 而此刻的 `_channel` 已是 null ⇒ `_sendJson` 静默 no-op ⇒
    // **subscribe 帧从未发出** ⇒ 后端不推送 ⇒ 消息/未读/排序全部不热更新。
    //
    // ## 为什么 `read` 是正确语义
    // 这六个 store 都是**长生命周期单例**（provider 自身只在容器销毁时 dispose，
    // 实例引用永不变化）—— 本 provider 需要的是「**它们在本次构建时的实例**」，
    // 而不是「它们变化时重建我」。连接对象的生命周期必须长于它们的通知频率。
    // `read` 取一次即可，与本文件既有注释（`currentUserId` 用容器级 `read` 的同一条理由）一致。
    final ProviderContainer container = ref.container;
    final AylaChatWsClient client = AylaChatWsClient(
      chatState: ref.read(chatStateProvider),
      messageState: ref.read(messageStateProvider),
      notices: ref.read(noticesProvider),
      badges: ref.read(badgesProvider),
      realtime: ref.read(realtimeProvider),
      subgroupState: ref.read(subgroupStateProvider),
      currentUserId: () => container.read(authNotifierProvider).user?.id,
    );
    ref.onDispose(client.disconnect);
    return client;
  },
);

/// 登录后启动 chat 通道（web `chatWS.connect()`）：绑定通道 + 连接 + 登记订阅。
///
/// 幂等：重复调用只会重新 `connect()`（`WsChannel` 自身按 token 重建连接）。
AylaChatWsClient aylaStartChatWs(WidgetRef ref) {
  final AylaChatWsClient client = ref.read(chatWsProvider);
  final WsManager? manager = wsManager;
  if (manager != null) client.attach(manager.chat);
  client.connect();
  return client;
}

/// 登出 / 401 过期：断开 chat 通道并清空消息域状态（web `useAuth.logout` + 各 store `reset`）。
///
/// `ProviderContainer` 版（`main.dart` 的 `onSessionExpired` 用；`WidgetRef` 版见下）。
void aylaStopChatWsForContainer(ProviderContainer container) {
  container.read(chatWsProvider).disconnect();
  container.read(chatStateProvider).reset();
  container.read(messageStateProvider).reset();
  container.read(noticesProvider).clear();
  container.read(badgesProvider).reset();
  container.read(realtimeProvider).reset();
}

/// 登出（页面/壳层用 [WidgetRef]）：与容器版同语义。
void aylaStopChatWs(WidgetRef ref) {
  ref.read(chatWsProvider).disconnect();
  ref.read(chatStateProvider).reset();
  ref.read(messageStateProvider).reset();
  ref.read(noticesProvider).clear();
  ref.read(badgesProvider).reset();
  ref.read(realtimeProvider).reset();
}
