/// 私聊聊天页（路由 `/chat/:conversationId`）—— web `pages/PrivateChatPage.tsx`（73 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 22–38：`useParams` 的 conversationId + `?msg=&seq=`（收藏消息跳转定位，私聊无子群概念）；
/// - tsx 40–56：**窄屏** —— `FullScreenSwipeBack`（全屏右滑返回 `/messages`）+
///   `ConversationTransition(identity)` + `PrivateChatPane(onBack panelMotion externalJump)`；
/// - tsx 58–72：**宽屏** —— `.wide-messages` 两列（左列 `WideMessagesSidebar` 点其他会话切
///   `/chat/:id`；右列 `PrivateChatPane`，不渲染返回键）。
///
/// ## 群聊不进本页
/// 群聊会话由 `ChatConversationRoute` 重定向到 `/group/:id`（web 文件头原话）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import '../widgets/chat/messages_layout.dart';
import '../widgets/motion/gestures.dart'
    show AylaConversationTransition, AylaFullScreenSwipeBack;
import 'chat_support.dart';

class PrivateChatPage extends ConsumerWidget {
  const PrivateChatPage({
    super.key,
    required this.conversationId,
    this.jumpMessageId,
    this.jumpSeq,
  });

  final String conversationId;

  /// `?msg=`（收藏消息跳转）。
  final String? jumpMessageId;

  /// `?seq=`（跳转定位辅助）。
  final int? jumpSeq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final String? messageId = jumpMessageId;
    final ({String messageId, int seq})? externalJump =
        messageId == null || messageId.isEmpty
            ? null
            : (messageId: messageId, seq: jumpSeq ?? 0);
    final String identity = 'private:$conversationId';

    if (narrow) {
      return AylaFullScreenSwipeBack(
        enabled: true,
        onBack: () => context.go('/messages'),
        child: AylaConversationTransition(
          identity: identity,
          builder: (BuildContext context, String id) => AylaChatPaneHost(
            conversationId: conversationId,
            narrow: true,
            onBack: () => context.go('/messages'),
            externalJump: externalJump,
          ),
        ),
      );
    }

    return AylaWideMessages(
      children: <Widget>[
        AylaWideMessagesSidebarHost(
          activeId: conversationId,
          onSelect: (String id) =>
              context.go('/chat/${Uri.encodeComponent(id)}'),
        ),
        AylaWideMessagesPane(
          child: AylaConversationTransition(
            identity: identity,
            builder: (BuildContext context, String id) => AylaChatPaneHost(
              conversationId: conversationId,
              externalJump: externalJump,
            ),
          ),
        ),
      ],
    );
  }
}
