/// 分享弹窗的**页面级接线** —— web `components/share/ShareSheet.tsx` 的自取数等价物。
///
/// ## 为什么需要它
/// Flutter 的 [AylaShareSheet] 是**展示型**（数据与发送回调由页面注入，见 B5 组件交付），
/// 而 web 的 `ShareButton` 自带 `useShareTargets` 与 `send`。房头部（语音房/
/// 直播间）的分享键因此需要一个共享的注入器 —— 本文件就是它。
///
/// ## 数据源（web `ShareSheet.tsx` 的 `useSocialPage("groups")/("privates")`）
/// - 群聊目标：`GET /chat/conversations/?type=group&pagination=cursor`
/// - 私信目标：`GET /chat/conversations/?type=private&pagination=cursor`
/// - 发送：`POST /chat/conversations/<id>/messages/`（`type=share` +
///   `share_payload` + 可选 `subgroup_id`）
///
/// ## 登记（有意偏离）
/// `onLoadSubgroups` 传 null（= web 文档里的「不查子群，点群项按"仅默认组"直接发送」）：
/// Flutter 侧 `chat_api` 尚无 `listSubgroups`（子群域属群聊批次）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/chat_api.dart';
import '../core/models/chat_message.dart'
    show AylaCreateMessagePayload, AylaMessageType;
import '../core/models/conversation.dart';
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../state/paged_list.dart';
import '../widgets/base/overlays.dart';
import '../widgets/base/share.dart';

/// 分享目标控制器（每个宿主页面一份；持有两张目标分页表）。
class AylaShareController extends ChangeNotifier {
  AylaShareController({this.defaultContentBuilder});

  /// 默认正文构造（web：`[分享]` + `payload.title || 目标名`）。
  final String Function(AylaSharePayload payload, String targetTitle)?
      defaultContentBuilder;

  AylaPagedList<AylaConversationSummary>? _groups;
  AylaPagedList<AylaConversationSummary>? _privates;

  /// 群聊目标页。
  AylaPagedList<AylaConversationSummary> get groups => _groups ??= _create('group');

  /// 私信目标页。
  AylaPagedList<AylaConversationSummary> get privates =>
      _privates ??= _create('private');

  bool _started = false;

  /// 首帧后启动两张表（web 弹窗打开时取数；这里提前一档，弹窗打开即可见数据）。
  void start() {
    if (_started) return;
    _started = true;
    groups.load();
    privates.load();
  }

  AylaPagedList<AylaConversationSummary> _create(String type) {
    final AylaPagedList<AylaConversationSummary> list =
        AylaPagedList<AylaConversationSummary>(
      request: (String? cursor) =>
          AylaChatApi.listConversationsPage(cursor: cursor, type: type),
      keyOf: (AylaConversationSummary item) => item.id,
    );
    list.addListener(notifyListeners);
    return list;
  }

  @override
  void dispose() {
    _groups?.removeListener(notifyListeners);
    _privates?.removeListener(notifyListeners);
    _groups?.dispose();
    _privates?.dispose();
    _groups = null;
    _privates = null;
    super.dispose();
  }

  /// 群聊目标页投影（web `ShareTargets` 的 groups 档）。
  AylaShareTargetPage groupPage() => _pageOf(groups);

  /// 私信目标页投影。
  AylaShareTargetPage privatePage() => _pageOf(privates);

  AylaShareTargetPage _pageOf(AylaPagedList<AylaConversationSummary> list) {
    return AylaShareTargetPage(
      items: <AylaShareTarget>[
        for (final AylaConversationSummary item in list.items)
          _targetOf(item),
      ],
      loading: list.loading,
      hasMore: list.hasMore,
      loadMore: list.loadMore,
      refresh: list.refresh,
      error: list.error,
      invalidated: list.invalidated,
    );
  }

  static AylaShareTarget _targetOf(AylaConversationSummary item) {
    final AylaUserPublic? peer = item.peer;
    return AylaShareTarget(
      id: item.id,
      title: item.title,
      avatarUrl: item.avatar.isEmpty ? null : item.avatar,
      unreadCount: item.unreadCount,
      peerId: peer?.id,
      peerNickname: peer?.nickname,
      peerUsername: peer?.username,
      peerAvatarUrl: peer?.avatar,
    );
  }

  /// 发送分享（web `shareApi.sendMessage`；抛错 = 展示错误且不关闭弹窗）。
  Future<void> send(AylaShareSendRequest request) async {
    await AylaChatApi.sendMessage(
      request.conversationId,
      AylaCreateMessagePayload(
        content: request.content,
        type: AylaMessageType.share,
        subgroupId: request.subgroupId,
        sharePayload: request.payload,
      ),
    );
  }
}

/// 打开分享弹窗（root Overlay；web `ShareSheet` 由 `ShareButton` portal 挂载）。
///
/// 返回的 Future 在弹窗关闭后完成（发送成功也关闭 —— web 同）。
Future<void> aylaOpenShareSheet(
  BuildContext context, {
  required AylaSharePayload payload,
  required AylaShareController controller,
  String? currentUserId,
}) {
  controller.start();
  final Completer<void> done = Completer<void>();
  late final OverlayEntry entry;
  void close() {
    if (entry.mounted) entry.remove();
    if (!done.isCompleted) done.complete();
  }

  entry = aylaOverlayEntry(
    builder: (BuildContext ctx) => AnimatedBuilder(
      animation: controller,
      builder: (BuildContext ctx, Widget? _) => AylaShareSheet(
        payload: payload,
        groups: controller.groupPage(),
        privates: controller.privatePage(),
        currentUserId: currentUserId,
        onClose: close,
        onSend: (AylaShareSendRequest request) async {
          await controller.send(request);
          close();
        },
      ),
    ),
  );
  // ⚠️ 用**最近**的 Overlay，不要 `rootOverlay: true`：画布/测试宿主
  // （`theme/preview_theme.dart:55` 那层）没有 Navigator ⇒ 会抛
  // `No Overlay widget found` 刷屏（用户 2026-10-02 实报）。真实 app 里最近的就是 root ⇒ 等价。
  Overlay.of(context).insert(entry);
  return done.future;
}
