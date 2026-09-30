/// 群场景页面层共享 —— web `pages/GroupPage.tsx`（539 行）的取数/排序段 +
/// `components/home/groupActivity.ts`（399 行）的群活跃度投影。
///
/// ## 分工
/// - 场景解析 [aylaGroupSceneFromRoute] = tsx 216–224（route param → `GroupScene`）；
/// - 群目录 [AylaGroupDirectory] = tsx 92/196–213（`useSocialPage("conversations",{type:"group"})`
///   + `conversations` 合并当前群 + `sortGroupsByActivity`）；
/// - 活跃度 [aylaGroupActivityOf] = `groupActivity.ts:93–226`；
/// - 存在性角标 [aylaGroupPresenceOf] = `groupActivity.ts:116–152`。
///
/// ## 与 web 的机制差异（登记）
/// - **posts / boardgame 两源未接**：web 的活跃度与存在性读 `usePostsStore` /
///   `useBoardgameStore` 的**跨页全量缓存**；Flutter 侧这两个域只有页面级目录
///   （`AylaPagedList`，随页面销毁），没有全局 store ⇒ 本页只接
///   「消息 + 直播 + 语音」三源。缺失时**不伪造**（该群只是不因新帖/新桌游房排前）；
/// - Flutter 的语音频道快照带 `createdAt`（`voice.channel.*` 帧维护），与 web 同源。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/chat_api.dart';
import '../core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../core/models/chat_message.dart' show AylaMessageType;
import '../core/models/conversation.dart';
import '../state/chat_state.dart';
import '../state/group_state.dart';
import '../state/paged_list.dart';
import '../widgets/base/avatar_status_badges.dart' show AylaAvatarStatus;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/shell/channel_sidebar.dart' show AylaGroupScene;
import '../widgets/shell/server_rail.dart' show AylaServerRailGroup;

/// 「新内容」时间窗口（web `groupActivity.ts:23`：24 小时）。
const int kAylaNewContentWindowMs = 24 * 60 * 60 * 1000;

/// 路由参数 → 场景（web `GroupPage.tsx:216–224`）。
///
/// 优先级与 web **逐条一致**：`postId` > `voiceChannelId` > `liveChannelId` >
/// `scene`（且必须在 `VALID_SCENES` 里）> 缺省 `chat`。
AylaGroupScene aylaGroupSceneFromRoute({
  String? scene,
  String? postId,
  String? voiceChannelId,
  String? liveChannelId,
}) {
  if (postId != null && postId.isNotEmpty) return AylaGroupScene.posts;
  if (voiceChannelId != null && voiceChannelId.isNotEmpty) {
    return AylaGroupScene.voice;
  }
  if (liveChannelId != null && liveChannelId.isNotEmpty) {
    return AylaGroupScene.live;
  }
  if (scene != null && kAylaValidGroupScenes.contains(scene)) {
    return AylaGroupState.parseScene(scene) ?? AylaGroupScene.chat;
  }
  return AylaGroupScene.chat;
}

/// 一条「新内容」事件（web `groupActivity.ts:29–35` `NewEvent`）。
@immutable
class AylaGroupNewEvent {
  const AylaGroupNewEvent({
    required this.kind,
    required this.at,
    required this.text,
  });

  /// `message` / `live` / `voice` / `game` / `post`（web 同名字符串）。
  final String kind;

  /// 事件时间（Unix 毫秒）。
  final int at;

  /// 展示文案（如「小樱：今晚一起吃饭吗」）。
  final String text;
}

/// 群「新内容」聚合结果（web `groupActivity.ts:48–53`）。
@immutable
class AylaGroupActivity {
  const AylaGroupActivity({this.lastNewAt = 0, this.lastEvent});

  /// 最近一次新内容事件时间（毫秒）；无 = 0。
  final int lastNewAt;

  /// 最近一条事件（展示用）；无 = null。
  final AylaGroupNewEvent? lastEvent;

  /// 是否有「新内容」（web `hasGroupActivity`）。
  bool get hasActivity => lastNewAt > 0;

  static const AylaGroupActivity none = AylaGroupActivity();
}

/// ISO 时间戳 → 毫秒（无效 → 0）。web `toMs`。
int aylaActivityMs(String? iso) {
  if (iso == null || iso.isEmpty) return 0;
  final DateTime? parsed = DateTime.tryParse(iso);
  return parsed?.millisecondsSinceEpoch ?? 0;
}

/// 是否在「新」窗口内（web `isRecent`：不早于 now-window 且不晚于 now+1min 时钟容差）。
bool _isRecent(int ms, int now) =>
    ms > 0 && ms > now - kAylaNewContentWindowMs && ms < now + 60000;

/// 内容对本群可见（web `visibleInGroup`：白名单含本群）。
bool _visibleInGroup(String groupId, List<String> allowed) =>
    allowed.any((String id) => id == groupId);

/// 非文本消息类型 → 活跃度摘要占位（web `groupActivity.ts:84–91` 逐字）。
const Map<String, String> kAylaMediaEventPlaceholder = <String, String>{
  'image': '[图片]',
  'voice': '[语音]',
  'file': '[文件]',
  'emoji': '[表情]',
  'video': '[视频]',
  'system': '[系统消息]',
};

/// 消息事件（web `messageEvent`，含 poke 特例）。
AylaGroupNewEvent? aylaMessageEvent(
  AylaLastMessagePreview? lastMessage,
  int now,
) {
  if (lastMessage == null) return null;
  final int at = aylaActivityMs(lastMessage.createdAt);
  if (!_isRecent(at, now)) return null;
  final String who = lastMessage.senderName;
  final String content = (lastMessage.preview ?? '').isNotEmpty
      ? lastMessage.preview!
      : lastMessage.content.isNotEmpty
          ? lastMessage.content
          : kAylaMediaEventPlaceholder[lastMessage.type?.wire ?? ''] ?? '';
  // 戳一戳 preview 已是「A戳了戳B」完整文案，不加「发送者：」前缀（避免 A：A戳了A戳了B）。
  if (lastMessage.type == AylaMessageType.poke) {
    return AylaGroupNewEvent(kind: 'message', at: at, text: content);
  }
  return AylaGroupNewEvent(kind: 'message', at: at, text: '$who：$content');
}

/// 群活跃度（web `useGroupActivityMap` 的返回函数）。
///
/// 三源：最后一条消息（含自己发的，**不依赖已读**）+ 新开播 + 新语音房。
/// 无「当前存在内容」推导的事件但有单调 bump 时，只保留时间戳（事件描述暂缺）。
AylaGroupActivity aylaGroupActivityOf({
  required String groupId,
  required AylaLastMessagePreview? lastMessage,
  required Iterable<AylaLiveChannelSnapshot> liveChannels,
  required Iterable<AylaVoiceChannelSnapshot> voiceChannels,
  required Map<String, int> groupActivityAt,
  int? nowMs,
}) {
  final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  AylaGroupNewEvent? best = aylaMessageEvent(lastMessage, now);
  for (final AylaLiveChannelSnapshot c in liveChannels) {
    if (c.status != AylaLiveStatus.live) continue;
    if (!_visibleInGroup(groupId, c.allowedGroupIds)) continue;
    final int at = aylaActivityMs(c.startedAt);
    if (_isRecent(at, now) && (best == null || at > best.at)) {
      best = AylaGroupNewEvent(
        kind: 'live',
        at: at,
        text: '${c.ownerNickname ?? ''} 开播了 ${c.title}',
      );
    }
  }
  for (final AylaVoiceChannelSnapshot c in voiceChannels) {
    if (!_visibleInGroup(groupId, c.allowedGroupIds)) continue;
    final int at = aylaActivityMs(c.createdAt);
    if (_isRecent(at, now) && (best == null || at > best.at)) {
      // 显示用户填的频道名 name（room_name 是 LiveKit 内部名）。
      best = AylaGroupNewEvent(
        kind: 'voice',
        at: at,
        text: '${c.ownerNickname ?? ''} 创建了语音房 ${c.name}',
      );
    }
  }
  final int bumped = groupActivityAt[groupId] ?? 0;
  if (best == null) {
    if (bumped <= 0) return AylaGroupActivity.none;
    return AylaGroupActivity(lastNewAt: bumped);
  }
  return AylaGroupActivity(
    lastNewAt: best.at > bumped ? best.at : bumped,
    lastEvent: best,
  );
}

/// 群存在性角标（web `useGroupPresenceMap` 的返回函数）。
///
/// 优先用会话摘要里的 `group_presence` 聚合字段；缺席时从 live/voice 快照推导
/// （**语音重点 = 「有人」在语音房**，不是「有语音房」）。
/// 桌游源未接（见文件头偏离）⇒ 该项保持 `null`（未知，不是 false）。
AylaAvatarStatus aylaGroupPresenceOf({
  required String groupId,
  required AylaGroupPresence? aggregate,
  required Iterable<AylaLiveChannelSnapshot> liveChannels,
  required Iterable<AylaVoiceChannelSnapshot> voiceChannels,
}) {
  if (aggregate != null) {
    return AylaAvatarStatus(
      live: aggregate.live,
      voice: aggregate.voice,
      game: aggregate.game,
    );
  }
  bool live = false;
  for (final AylaLiveChannelSnapshot c in liveChannels) {
    if (c.status == AylaLiveStatus.live &&
        _visibleInGroup(groupId, c.allowedGroupIds)) {
      live = true;
      break;
    }
  }
  bool voice = false;
  for (final AylaVoiceChannelSnapshot c in voiceChannels) {
    if (_visibleInGroup(groupId, c.allowedGroupIds) &&
        (c.memberCount ?? 0) > 0) {
      voice = true;
      break;
    }
  }
  // 桌游源未接（见文件头偏离）：与 web 缺 store 时同 —— 该项保持 false，
  // 而不是把「未知」伪造成 true。
  return AylaAvatarStatus(live: live, voice: voice);
}

/// 群排序：置顶优先 → 有新内容排前（组内按最近事件时间新→旧）→ 无新内容保持传入顺序
/// —— web `sortGroupsByActivity`（`groupActivity.ts:238–259`）。
List<AylaConversationSummary> aylaSortGroupsByActivity(
  List<AylaConversationSummary> list,
  AylaGroupActivity Function(AylaConversationSummary item) keyOf,
) {
  final List<({AylaConversationSummary item, int index, bool pinned, int ts})>
      rows = <({AylaConversationSummary item, int index, bool pinned, int ts})>[
    for (int i = 0; i < list.length; i++)
      (
        item: list[i],
        index: i,
        pinned: list[i].isPinned ?? false,
        ts: keyOf(list[i]).lastNewAt,
      ),
  ];
  rows.sort((a, b) {
    if (a.pinned != b.pinned) return b.pinned ? 1 : -1;
    if (a.ts != b.ts) return b.ts - a.ts;
    return a.index - b.index;
  });
  return <AylaConversationSummary>[for (final r in rows) r.item];
}

/// 宽屏 ServerRail 的行数据（web `ServerRail` 的 `groups` prop，tsx 409–414）。
List<AylaServerRailGroup> aylaServerRailGroups({
  required List<AylaConversationSummary> groups,
  required Iterable<AylaLiveChannelSnapshot> liveChannels,
  required Iterable<AylaVoiceChannelSnapshot> voiceChannels,
}) =>
    <AylaServerRailGroup>[
      for (final AylaConversationSummary g in groups)
        AylaServerRailGroup(
          id: g.id,
          title: g.title,
          avatarUrl: g.avatar.isEmpty ? null : g.avatar,
          isPinned: g.isPinned ?? false,
          unreadCount: g.unreadCount,
          postUnreadCount: g.postUnreadCount ?? 0,
          presence: aylaGroupPresenceOf(
            groupId: g.id,
            aggregate: g.groupPresence,
            liveChannels: liveChannels,
            voiceChannels: voiceChannels,
          ),
        ),
    ];

/// 群目录控制器 —— web `GroupPage.tsx:92/196–213` 的等价物。
///
/// 取 `type=group` 的会话游标页；与 `chatState` 里的**当前群摘要**合并
/// （「直达群路由时该群可能不在第一页」），再按活跃度排序。
/// 目录本身由 [AylaPagedList] 承载（游标推进 / 在途作废 / 失败保留已有内容）。
class AylaGroupDirectory extends ChangeNotifier {
  AylaGroupDirectory({required AylaChatState chatState}) : _chat = chatState {
    _list.addListener(_forward);
    // ⚠️ **有缓存就不请求**（2026-10-01 用户实机：「每次进入主页都要加载群头像侧栏，
    // 是不是写死了啊」—— 正是这里：构造函数**无条件** `load()`）。
    // web 的群列表读的是 **social store**，而 `appInit.ts:35` 的
    // `loadSocial("conversations", { type: "group" })` 已预加载它 ⇒ 命中 60 秒缓存、
    // **不发请求**（这就是用户说的「web 不需要」）。Flutter 侧改用 `chatState` 的会话摘要
    //（预加载已灌入，见 `app_preload.dart` 的 `_seedChatStateFromSocial`）当首屏数据源；
    // 只有它为空（未预加载 / 新登录 / 真的没有群）时才发本页的分页请求。
    if (_cachedGroups.isEmpty) unawaited(_list.load());
  }

  /// `chatState` 里的群会话（= web 读 social store 的那份缓存）。
  List<AylaConversationSummary> get _cachedGroups =>
      <AylaConversationSummary>[
        for (final AylaConversationSummary c in _chat.conversations)
          if (c.isGroup) c,
      ];

  final AylaChatState _chat;
  final AylaPagedList<AylaConversationSummary> _list =
      AylaPagedList<AylaConversationSummary>(
    request: (String? cursor) => AylaChatApi.listConversationsPage(
      cursor: cursor,
      type: 'group',
    ),
    keyOf: (AylaConversationSummary c) => c.id,
  );

  List<AylaConversationSummary> get raw => _list.items;

  bool get loading => _list.loading;

  bool get loaded => _list.loaded;

  /// 是否还有更多：本页分页没加载过时**视为可能还有**（缓存只有一页 ⇒ 需要「展开更多」
  /// 才能拉到后面几页；此前它恒 false 会让入口消失）。
  bool get hasMore => _list.hasMore || !_list.loaded;

  String? get error => _list.error;

  bool get invalidated => _list.invalidated;

  Future<void> loadMore() => _list.loadMore();

  Future<void> refresh() => _list.refresh();

  /// 目录 + 当前群（web tsx 196–203：`selected` 不在已加载页里时补上）。
  List<AylaConversationSummary> groupsWith(String? selectedId) {
    // 优先用 chatState 的缓存（= web 读 store）；本页分页有数据时以它为准（已翻页）。
    final List<AylaConversationSummary> cached = _cachedGroups;
    final List<AylaConversationSummary> loaded =
        _list.items.isNotEmpty ? _list.items : cached;
    if (selectedId == null || selectedId.isEmpty) return loaded;
    final AylaConversationSummary? selected = _chat.byId(selectedId);
    if (selected == null ||
        !selected.isGroup ||
        loaded.any((AylaConversationSummary c) => c.id == selected.id)) {
      return loaded;
    }
    return <AylaConversationSummary>[...loaded, selected];
  }

  void _forward() => notifyListeners();

  @override
  void dispose() {
    _list.removeListener(_forward);
    _list.dispose();
    super.dispose();
  }
}
