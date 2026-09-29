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

/// chat 全局状态（会话列表 + 未读投影 + 活跃排序）。
final ChangeNotifierProvider<AylaChatState> chatStateProvider =
    ChangeNotifierProvider<AylaChatState>((Ref ref) => AylaChatState());

/// message 全局状态（按会话分桶的消息缓存）。
///
/// 装配时接上**子群活跃度钩子**（web `stores/message.ts:97/136/177/326` 的
/// `useSubGroupStore.getState().recordMessageActivity(...)`）—— 消息落库即推进
/// 子群 `last_message_seq`，宽屏侧栏的子群活跃度排序据此即时刷新。
final ChangeNotifierProvider<AylaMessageState> messageStateProvider =
    ChangeNotifierProvider<AylaMessageState>((Ref ref) {
  final AylaMessageState state = AylaMessageState();
  state.onSubgroupActivity = (String convId, String? subgroupId, int seq) =>
      ref
          .read(subgroupStateProvider)
          .recordMessageActivity(convId, subgroupId, seq);
  return state;
});

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
    final AylaChatWsClient client = AylaChatWsClient(
      chatState: ref.watch(chatStateProvider),
      messageState: ref.watch(messageStateProvider),
      notices: ref.watch(noticesProvider),
      badges: ref.watch(badgesProvider),
      realtime: ref.watch(realtimeProvider),
      subgroupState: ref.watch(subgroupStateProvider),
      currentUserId: () => ref.read(authNotifierProvider).user?.id,
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
