/// 分享消息路由与展示文案（`Ayla/web/src/utils/shareRoutes.ts` 的 Dart 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [aylaShareTypeLabel] | `shareRoutes.ts:24–31` `SHARE_TYPE_LABELS` |
/// | [aylaShareTargetRoute] | `shareRoutes.ts:43–83`（`inGroupRoute` / `outRoute`）+ `132–140` `shareTargetRoute` |
/// | [aylaSharePreviewText] | `shareRoutes.ts:143–148` `sharePreviewText` |
///
/// ## 与 web 的差异（有意，登记）
/// web 的 `resolveShareTarget`（`shareRoutes.ts:118–129`）点击时会**异步查各域目录**
/// （`groupEntryIds`：voice / live / post / boardgame 四个 API，`scope=group:<id>`）
/// 判断目标是否在该群有条目，命中 → 群内路径，未命中/失败 → 群外路径。
///
/// Flutter 侧目录 API 属**页面层接线**，`lib/widgets` 不发起业务请求 ⇒ 默认走
/// **静态路由**（本文件 [aylaShareTargetRoute]，与 web 的 `shareTargetRoute` 同一条
/// 路由表：群聊上下文即群内路径）；页面层可注入 `onResolveTarget` 覆盖成异步存在性检查。
library;

import 'share_payload.dart';

/// 分享来源展示名（转发卡片副标题/兜底文案）。
String aylaShareTypeLabel(AylaShareType type) => switch (type) {
      AylaShareType.group => '群聊',
      AylaShareType.voice => '语音房',
      AylaShareType.live => '直播间',
      AylaShareType.post => '帖子',
      AylaShareType.boardgame => '桌游室',
      AylaShareType.user => '用户',
    };

/// 群内路径（`shareRoutes.ts:43–62`）：`groupId` 上下文中展示/直用。
String _inGroupRoute(AylaShareType type, String groupId, String targetId) {
  final String g = Uri.encodeComponent(groupId);
  final String id = Uri.encodeComponent(targetId);
  return switch (type) {
    AylaShareType.group => '/group/$id',
    AylaShareType.voice => '/group/$g/voice/$id',
    AylaShareType.live => '/group/$g/live/$id',
    AylaShareType.post => '/group/$g/posts/$id',
    // 桌游在群内是场景页（不带房 id）
    AylaShareType.boardgame => '/group/$g/games',
    AylaShareType.user => '/user/$id',
  };
}

/// 群外路径（`shareRoutes.ts:65–83`）。
String _outRoute(AylaShareType type, String targetId) {
  final String id = Uri.encodeComponent(targetId);
  return switch (type) {
    AylaShareType.group => '/group/$id',
    AylaShareType.voice => '/voice/$id',
    AylaShareType.live => '/live/$id',
    AylaShareType.post => '/posts/$id',
    AylaShareType.boardgame => '/games/$id',
    AylaShareType.user => '/user/$id',
  };
}

/// 静态路由（`shareRoutes.ts:132–140`）：`groupId` 非空即群内路径，不做存在性检查。
///
/// `targetId` 缺失 → null（web：`!payload.target_id` 直接返回 null，不跳转）。
String? aylaShareTargetRoute(AylaSharePayload? payload, String? groupId) {
  if (payload == null || payload.targetId.isEmpty) return null;
  if (groupId != null && groupId.isNotEmpty) {
    return _inGroupRoute(payload.shareType, groupId, payload.targetId);
  }
  return _outRoute(payload.shareType, payload.targetId);
}

/// 会话列表/引用预览兜底文案（`shareRoutes.ts:143–148`）：「[分享]标题」。
String aylaSharePreviewText(AylaSharePayload? payload, String? content) {
  final String title = (payload?.title ?? '').trim();
  if (title.isNotEmpty) return '[分享]$title';
  final String c = (content ?? '').trim();
  return c.isNotEmpty ? '[分享]$c' : '[分享]';
}
