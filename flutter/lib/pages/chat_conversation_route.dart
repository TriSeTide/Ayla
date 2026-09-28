/// 会话路由适配（路由 `/chat/:conversationId`）—— web `pages/ChatConversationRoute.tsx`（73 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 22–25：先从 chat store 的缓存里取会话类型（命中即不请求）；
/// - tsx 31–50：未命中 → `GET /chat/conversations/<id>/?metadata=directory`，成功 `upsertConversation`，
///   失败置错；`retryToken` 变化重取（取消守卫用 `cancelled` 标志）；
/// - tsx 54–57：`type === "group"` ⇒ `<Navigate to={/group/:id + location.search} replace/>`
///   （**保留** `?msg=&seq=&subgroup=` 定位参数）；
/// - tsx 58–60：`type === "private"` ⇒ `PrivateChatPage`；
/// - tsx 61–63：错误 ⇒ `AsyncState status="error"`（文案「加载会话失败，请重试」+ 重试）；
/// - tsx 64–72：其余（类型未知/加载中）⇒ `AsyncState status="loading"`。
///   ⚠️ web 的 `AsyncState` 在 loading 档**忽略 children**（`AsyncState.tsx:17–19`），
///   所以 tsx 里的 `.route-loading` 三根骨架**不会渲染** ⇒ Flutter 侧同样只渲染加载态本体。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/models/conversation.dart';
import '../state/chat_providers.dart';
import '../state/chat_state.dart';
import '../widgets/base/dialogs.dart'
    show AylaAsyncState, AylaAsyncStatus;
import 'private_chat_page.dart';

class ChatConversationRoute extends ConsumerStatefulWidget {
  const ChatConversationRoute({
    super.key,
    required this.conversationId,
    this.query = '',
    this.jumpMessageId,
    this.jumpSeq,
  });

  final String conversationId;

  /// 原 `location.search`（群聊重定向时原样带过去）。
  final String query;

  final String? jumpMessageId;
  final int? jumpSeq;

  @override
  ConsumerState<ChatConversationRoute> createState() =>
      _ChatConversationRouteState();
}

class _ChatConversationRouteState extends ConsumerState<ChatConversationRoute> {
  AylaConversationType? _fetchedType;
  String? _error;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _maybeFetch();
  }

  @override
  void didUpdateWidget(covariant ChatConversationRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _fetchedType = null;
      _error = null;
      _maybeFetch();
    }
  }

  void _maybeFetch() {
    if (widget.conversationId.isEmpty) return;
    if (_cachedType != null || _fetching) return;
    _fetching = true;
    unawaited(() async {
      try {
        final AylaConversationSummary conv = await AylaChatApi
            .getConversationSummary(widget.conversationId);
        if (!mounted) return;
        ref.read(chatStateProvider).upsertConversation(conv);
        setState(() {
          _fetchedType = conv.type;
          _error = null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = '加载会话失败，请重试');
      } finally {
        _fetching = false;
      }
    }());
  }

  AylaConversationType? get _cachedType {
    final AylaChatState chat = ref.read(chatStateProvider);
    for (final AylaConversationSummary c in chat.conversations) {
      if (c.id == widget.conversationId) return c.type;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatStateProvider);
    final AylaConversationType? type = _cachedType ?? _fetchedType;

    if (type == AylaConversationType.group && widget.conversationId.isNotEmpty) {
      // 群聊由 `/group/:id` 承载（web `<Navigate replace/>`；保留 search 里的定位参数）。
      final String target =
          '/group/${Uri.encodeComponent(widget.conversationId)}${widget.query}';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(target);
      });
      return const AylaAsyncState(status: AylaAsyncStatus.loading);
    }
    if (type == AylaConversationType.private) {
      return PrivateChatPage(
        conversationId: widget.conversationId,
        jumpMessageId: widget.jumpMessageId,
        jumpSeq: widget.jumpSeq,
      );
    }
    if (_error != null) {
      return AylaAsyncState(
        status: AylaAsyncStatus.error,
        error: _error,
        onRetry: () {
          setState(() => _error = null);
          _maybeFetch();
        },
      );
    }
    return const AylaAsyncState(status: AylaAsyncStatus.loading);
  }
}
