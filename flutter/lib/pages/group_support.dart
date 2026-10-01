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
/// - ~~**posts / boardgame 两源未接**~~ ⇒ **2026-10-01 已接**：web 的活跃度与存在性读
///   `usePostsStore` / `useBoardgameStore` 的**跨页全量缓存**；
///   Flutter 侧补上了这两个全局 store（`state/posts_store.dart` 的 WS 增量四件套 +
///   `state/boardgame_store.dart`），并由 `core/ws/posts_frames.dart` /
///   `core/ws/room_frames.dart` 两条帧桥维护 ⇒ 五源齐（消息 + 直播 + 语音 + 桌游 + 帖子），
///   与 web `groupActivity.ts:159–169` 订阅的四个 store + `groupActivityAt` **逐条同源**。
///   缺失时**仍不伪造**（拿不到数据就是空列表，不编事件）。
/// - Flutter 的语音频道快照带 `createdAt`（`voice.channel.*` 帧维护），与 web 同源。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../core/models/chat_message.dart' show AylaMessageType;
import '../core/models/conversation.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../core/models/post.dart' show AylaPost;
import '../state/chat_state.dart';
import '../state/group_state.dart';
import '../state/social_store.dart';
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

/// 取两个人名中可显示的一个（web `displayName`，`groupActivity.ts:79–81`：
/// `nickname || username || ""`）。
String _displayName(String? nickname, String? username) {
  final String nick = nickname ?? '';
  if (nick.isNotEmpty) return nick;
  return username ?? '';
}

/// 群活跃度（web `useGroupActivityMap` 的返回函数，`groupActivity.ts:159–227`）。
///
/// 五源：最后一条消息（含自己发的，**不依赖已读**）+ 新开播 + 新语音房 +
/// 新桌游房 + 新帖子；无「当前存在内容」推导的事件但有单调 bump 时，
/// 只保留时间戳（事件描述暂缺，web 217–223）。
///
/// 逐条对应 `groupActivity.ts:171–226`：五源共用同一个 `best`，**取 `at` 最大者**
/// （web 的 `(!best || at > best.at)` 判据逐字照抄）；窗口判据同为
/// [_isRecent]（不早于 now-24h、不晚于 now+1min）。
AylaGroupActivity aylaGroupActivityOf({
  required String groupId,
  required AylaLastMessagePreview? lastMessage,
  required Iterable<AylaLiveChannelSnapshot> liveChannels,
  required Iterable<AylaVoiceChannelSnapshot> voiceChannels,
  required Iterable<AylaGameRoom> gameRooms,
  required Iterable<AylaPost> posts,
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
  // 新桌游房被创建：created_at 在窗口内（web 196–205）。
  for (final AylaGameRoom r in gameRooms) {
    if (!_visibleInGroup(groupId, r.allowedGroupIds)) continue;
    final int at = aylaActivityMs(r.createdAt);
    if (_isRecent(at, now) && (best == null || at > best.at)) {
      final String owner = _displayName(r.owner.nickname, r.owner.username);
      best = AylaGroupNewEvent(
        kind: 'game',
        at: at,
        text: '$owner 创建了桌游房 ${r.name}',
      );
    }
  }
  // 新帖子：created_at 在窗口内且白名单含本群（web 206–215）。
  for (final AylaPost post in posts) {
    if (!_visibleInGroup(groupId, post.allowedGroupIds)) continue;
    final int at = aylaActivityMs(post.createdAt);
    if (_isRecent(at, now) && (best == null || at > best.at)) {
      final String author =
          _displayName(post.author?.nickname, post.author?.username);
      best = AylaGroupNewEvent(
        kind: 'post',
        at: at,
        text: '$author 发了新帖 ${post.title}',
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

/// 群存在性角标（web `useGroupPresenceMap` 的返回函数，`groupActivity.ts:116–152`）。
///
/// 优先用会话摘要里的 `group_presence` 聚合字段；缺席时从 live/voice/game 三表推导
/// （**语音重点 = 「有人」在语音房**，不是「有语音房」；**桌游 = 白名单含本群**，
/// 不看 status —— web 144–149 逐字如此）。
AylaAvatarStatus aylaGroupPresenceOf({
  required String groupId,
  required AylaGroupPresence? aggregate,
  required Iterable<AylaLiveChannelSnapshot> liveChannels,
  required Iterable<AylaVoiceChannelSnapshot> voiceChannels,
  required Iterable<AylaGameRoom> gameRooms,
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
  // 桌游：白名单含本群即 true（web 144–149）—— **不看 status**，
  // 与 live 的 status=live 判据不同（那是「在播」，这是「有房间」）。
  bool game = false;
  for (final AylaGameRoom r in gameRooms) {
    if (_visibleInGroup(groupId, r.allowedGroupIds)) {
      game = true;
      break;
    }
  }
  return AylaAvatarStatus(live: live, voice: voice, game: game);
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
  required Iterable<AylaGameRoom> gameRooms,
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
            gameRooms: gameRooms,
          ),
        ),
    ];

/// 群目录控制器 —— web `GroupPage.tsx:92/196–213` 的等价物。
///
/// ## 与 web **同源**（2026-10-01 重写，用户实机「退出登录然后重新登录之后会出 bug，
/// 群列表不完全显示了」）
/// web 的群列表是
/// `const groupPage = useSocialPage("conversations", { type: "group" })`
/// （`GroupPage.tsx:92`）—— 它**直读 social store 的那一份缓存**，与主页
/// （`HomePage.tsx` 的同一 `useSocialPage`）**共用同一个 key**，而 `appInit.ts:35` 的
/// `loadSocial("conversations", { type: "group" })` 已在启动/登录后把它灌好。
///
/// ⚠️ 本类此前自建了一条**独立 `AylaPagedList`**（另一套请求、另一套游标）⇒ 与 social store
/// 是**两套数据**：退出再登录时 social store 已被 `aylaSocialStore.reset()` 清空并由预加载重灌，
/// 而这条独立分页只在 `chatState` 为空时才发请求、拿到的又只是**第一页** ⇒ 列表不完整、
/// 且与当前群合并后出现空条目。改成直读 social store 后两者天然同源、同一次预加载。
class AylaGroupDirectory extends ChangeNotifier {
  AylaGroupDirectory({required AylaChatState chatState}) : _chat = chatState {
    _pager.addListener(_forward);
    // ⚠️ **有缓存就不请求**（2026-10-01 用户实机：「每次进入主页都要加载群头像侧栏，
    // 是不是写死了啊」—— 正是这里：构造函数**无条件** `load()`）。
    // web 命中 `appInit.ts:35` 预取的那份 store（60 秒新鲜窗口，见 `social_store.dart`）
    // ⇒ 不发请求。仅在真的没有缓存时才补一次。
    if (_pager.items.isEmpty) unawaited(_pager.load());
  }

  /// 与主页/预加载**同 key** 的 social 频道（`GroupPage.tsx:92`）。
  final AylaSocialController<AylaConversationSummary> _pager =
      AylaSocialController<AylaConversationSummary>(
    store: aylaSocialStore,
    kind: AylaSocialKind.conversations,
    options: const AylaSocialOptions(type: 'group'),
  );

  final AylaChatState _chat;

  /// 目录条目（web `groupPage.items`）。
  List<AylaConversationSummary> get raw => _pager.items;

  bool get loading => _pager.loading;

  bool get loaded => _pager.loaded;

  bool get hasMore => _pager.hasMore;

  String? get error => _pager.error;

  /// web `useSocialPage` **恒返回 `invalidated: false`**（`hooks/useSocialPage.ts:24`）。
  bool get invalidated => false;

  Future<void> loadMore() => _pager.loadMore();

  Future<void> refresh() => _pager.refresh();

  /// 最近一次 [groupsWith] 因**类型过滤**丢弃的条数（>0 = 本 key 的投影里混入过非群条目）。
  ///
  /// 只作诊断上报，不改变返回结果 —— 过滤是 web 的第二道过滤本身，不是兜底。
  int get filteredOutCount => _filteredOutCount;
  int _filteredOutCount = 0;

  /// 目录 + 当前群（web tsx 196–203 `groups` 的 `useMemo`：
  /// `loaded` 不在已加载页里时，把 chatState 里的 `selected` 补到末尾）。
  ///
  /// ## 两道类型过滤（2026-10-01 用户实机「群列表排序完全错误」的根因 #1）
  /// web 的 `groupPage.items` **必然是纯群** —— 请求层就带了类型：
  /// `GroupPage.tsx:92` 的 `useSocialPage("conversations", { type: "group" })`
  /// ⇒ 后端 `GET /chat/conversations/?type=group` 只回群
  ///（Lead 实测：7 个群；不传 type 则 7 群 + 3 个私聊）。
  ///
  /// Flutter 侧本类构造时同样传了 `AylaSocialOptions(type: 'group')`、
  /// store 的 `_matches` 也按 `type` 判（`social_store.dart:645–649`）—— 两道都在，
  /// **但 `_pager.items` 是「该 key 的已在册投影」**：`reconcileCached` 会把它与
  /// `chatState.conversations`（**全部会话**，含私聊）对账，凡 `_matches` 判真者**前插**
  /// （`social_store.dart:607–613`）。任何一条私聊被判真，rail 就会显示它 ——
  /// 这正是实测现场（后端 `type=group` 只有 7 群，Flutter rail 显示 9 个，
  /// 多出的 `A`/`2`/`3` 正是那 3 个私聊）。
  ///
  /// ⇒ 这里补上 web 的第二道过滤：`HomePage.tsx:64–67` 的
  /// `conversations.filter((c) => c.type === "group")`。
  /// 窄屏 `home_page.dart:450–454` 的 `_groups()` 早有同一条 ⇒ 本处对齐后宽窄一致。
  List<AylaConversationSummary> groupsWith(String? selectedId) {
    final List<AylaConversationSummary> all = _pager.items;
    final List<AylaConversationSummary> loaded = <AylaConversationSummary>[
      for (final AylaConversationSummary c in all)
        if (c.isGroup) c,
    ];
    _filteredOutCount = all.length - loaded.length;
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
    _pager.removeListener(_forward);
    _pager.dispose();
    super.dispose();
  }
}
