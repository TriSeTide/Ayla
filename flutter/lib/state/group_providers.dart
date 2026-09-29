/// 群聊域 Provider 汇总 —— group 导航状态 + 子群状态 + 群已读回执应用。
///
/// ## 为什么单独一个文件
/// 与 `chat_providers.dart` / `room_providers.dart` 同一约定：state 文件保持
/// **纯 ChangeNotifier**（不依赖 Riverpod），provider 集中声明。
///
/// ## 生命周期
/// 两个都是**非 autoDispose** 的全局 provider：路由切换（`/group/:id` ↔ `/group/:id/info`）
/// 不重建，与 web 的模块级单例 store 语义一致。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/chat_message.dart' show AylaChatMessage;
import '../core/models/conversation.dart' show AylaConversationSummary;
import 'chat_state.dart';
import 'group_state.dart';
import 'message_state.dart';
import 'subgroup_state.dart';

/// 群内场景导航状态（web `stores/group.ts` 的 `useGroupStore`）。
final ChangeNotifierProvider<AylaGroupState> groupStateProvider =
    ChangeNotifierProvider<AylaGroupState>((Ref ref) => AylaGroupState());

/// 子群状态（web `stores/subgroup.ts` 的 `useSubGroupStore`）。
final ChangeNotifierProvider<AylaSubGroupState> subgroupStateProvider =
    ChangeNotifierProvider<AylaSubGroupState>(
  (Ref ref) => AylaSubGroupState(),
);

/// 群已读回执统一应用 —— web `stores/subgroupRead.ts`（21 行）的等价物。
///
/// **纪律**：REST/WS 重复确认只按**明确序号**消除，不清空整个子群。
/// - 会话响应含未读序号 ⇒ 走 [AylaChatState.markReadSeqs]（按序号精确移除）；
/// - 旧响应缺序号（`unreadSeqs` 为空 ⇒ 服务端没给权威序号数组）⇒ 只减去本次
///   确实移除的条数，**禁止把未知剩余量归零**；
/// - 最后把命中的消息标记为「我已读」（气泡已读态的同源投影）。
void aylaApplySubgroupReadReceipt({
  required AylaSubGroupState subgroupState,
  required AylaChatState chatState,
  required AylaMessageState messageState,
  required String convId,
  required String subgroupId,
  required List<int> markedSeqs,
}) {
  final List<int> confirmed =
      markedSeqs.where((int seq) => seq > 0).toList(growable: false);
  if (confirmed.isEmpty) return;
  final int removed =
      subgroupState.markSubgroupReadSeqs(convId, subgroupId, confirmed);
  final AylaConversationSummary? conv = chatState.byId(convId);
  if (conv != null && conv.unreadSeqs.isNotEmpty) {
    chatState.markReadSeqs(convId, confirmed);
  } else if (removed > 0) {
    chatState.decrementUnread(convId, removed, seqs: confirmed);
  }
  final Set<int> read = confirmed.toSet();
  for (final AylaChatMessage message in messageState.messagesOf(convId)) {
    if (read.contains(message.seq)) {
      messageState.markReadByMe(convId, message.id);
    }
  }
}
