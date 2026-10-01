/// 主页的页面级装配 —— web `components/home/groupActivity.ts`（399 行）里
/// 本页真正消费的部分 + `HomePage.tsx:35–47` 的骨架卡片。
///
/// ## 为什么是页面级模块
/// 这里全是不含样式的**纯逻辑**（排序 / 事件描述 / 轮播投影 / 角标存在性）与两块
/// 页面级骨架排布，没有一个是可复用视觉件 ⇒ 与 `hub_support.dart` 同一口径放在
/// `pages/`，纯函数可直接单测。
///
/// ## 逐条对应（每条的 web 行号）
/// - [kAylaNewContentWindowMs] / [aylaIsRecent] / [aylaToMs] —— `groupActivity.ts:22–68`；
/// - [aylaVisibleInGroup] —— `70–76`（白名单 `allowed_group_ids` **字符串比较**）；
/// - [AylaNewEvent] / [AylaGroupActivity] —— `26–55`；
/// - [aylaMessageEvent] —— `94–111`（含 poke 不加前缀、媒体类型占位）；
/// - [AylaHomeActivityMap.activityFor] —— `159–227`；
/// - [AylaHomeActivityMap.presenceFor] —— `116–152`（先读会话聚合，再扫目录）；
/// - [AylaHomeActivityMap.carouselFor] —— `300–398`（四类轮播卡，桌游档受
///   `SHOW_GAME_STATUS` 关闭 —— 与 web 同值 false）；
/// - [aylaSortGroupsByActivity] —— `238–259`（置顶 > 新内容时间新→旧 > 稳定索引）；
/// - [aylaHomeSkeletonGrid] —— `HomePage.tsx:35–47` + `home.css:210–215/239–242`
///   + `base.css:564–569`。
///
/// ## 与 web 的机制差异（登记）
/// web 的四份目录数据来自 `appInit.ts` 登录预加载 + ChatWS 增量维护的四个 store
/// （`live/voice/boardgame/posts`）。
/// **2026-10-01 更新**（用户实报「窄屏群列表…依然没有热更新排序 ws 接线」）：
/// ① **已接实时源** —— `home_page.dart` 订阅 `aylaDirectoryStore`（live/voice/game）、
/// `aylaPostsStore`、`aylaBoardgameStore`、`voiceState`/`liveState` 与 `chatStateProvider`，
/// 任一变化即重算本类的快照（web `groupActivity.ts:159–169` 的 `useGroupActivityMap`）；
/// ② `chatState.groupActivityAt`（WS bump，`stores/chat.ts:87–90`）**已接**：
/// 由 [AylaHomeActivityMap] 的 `groupActivityAt` 入参传入，与会话行的
/// `directory_activity_at` 取较大值；
/// ③ 仍只有**第一页**（web 的 store 同样是预加载首页 + WS 增量 ⇒ 口径等价）。
library;

import 'package:flutter/material.dart';

import '../core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../core/api/voice_api.dart' show AylaDirectoryVoiceEntry;
import '../core/models/chat_message.dart' show AylaMessageType;
import '../core/models/conversation.dart';
import '../core/models/game_room.dart' show AylaGameRoom, AylaGameRoomStatus;
import '../core/models/post.dart' show AylaPost, AylaPostImage;
import '../theme/tokens.dart';
import '../widgets/base/avatar_status_badges.dart'
    show AylaAvatarStatus, kShowGameStatus;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/group/group_card.dart'
    show AylaGroupCarouselSlide, AylaGroupSlideVoiceRoom;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;

/// 「新」的时间窗口：窗口内的事件才算"新内容"（`groupActivity.ts:23`）。
const int kAylaNewContentWindowMs = 24 * 60 * 60 * 1000;

/// 语音房轮播最多展示的房间数（`MAX_VOICE_ROOMS`，`groupActivity.ts:284`）。
const int kAylaMaxCarouselVoiceRooms = 3;

/// 事件种类（`groupActivity.ts:26`）。
enum AylaNewEventKind { message, live, voice, game, post }

/// 非文本消息类型 → 活跃度摘要占位（`groupActivity.ts:84–91`，与会话列表同口径）。
const Map<AylaMessageType, String> kAylaMediaEventPlaceholder =
    <AylaMessageType, String>{
  AylaMessageType.image: '[图片]',
  AylaMessageType.voice: '[语音]',
  AylaMessageType.file: '[文件]',
  AylaMessageType.emoji: '[表情]',
  AylaMessageType.video: '[视频]',
  AylaMessageType.system: '[系统消息]',
};

/// 一条「新内容」事件（`NewEvent`）。
class AylaNewEvent {
  const AylaNewEvent({required this.kind, required this.at, required this.text});

  final AylaNewEventKind kind;

  /// 事件时间（ms epoch）。
  final int at;

  /// 展示文本（如「小樱：今晚一起吃饭吗」「阿蓝 开播了 直播间1」）。
  final String text;
}

/// 群「新内容」聚合（`GroupActivity`）。
class AylaGroupActivity {
  const AylaGroupActivity({this.lastNewAt = 0, this.lastEvent});

  /// 最近一次「新内容」事件时间（ms）；无则 0。
  final int lastNewAt;

  /// 最近一条事件（展示用）；无则 null。
  final AylaNewEvent? lastEvent;

  bool get hasActivity => lastNewAt > 0;
}

/// `NO_ACTIVITY`（`groupActivity.ts:55`）。
const AylaGroupActivity kAylaNoActivity = AylaGroupActivity();

/// ISO 时间戳 → ms（无效返回 0；`groupActivity.ts:58–62`）。
int aylaToMs(String? iso) {
  if (iso == null || iso.isEmpty) return 0;
  final DateTime? parsed = DateTime.tryParse(iso);
  return parsed == null ? 0 : parsed.millisecondsSinceEpoch;
}

/// 是否在「新」窗口内（不早于 `now - window`、不晚于 `now + 1min` 时钟容差；
/// `groupActivity.ts:65–68`）。
/// **宽屏主页的重定向目标** —— web `HomePage.tsx:128` 的原句逐算子对照：
///
/// ```js
/// const target = recentValid
///   ? recentGroupId
///   : resolvedRecent ?? (recentGroupId && resolvedRecent === undefined ? null : groups[0]?.id);
/// ```
///
/// ⚠️ 这段翻译错过两次（2026-10-01 用户两次实机反馈），故抽成纯函数 + 表格单测锁死：
/// · 「跳两次侧栏」= 没等 prefs 读盘完成就按 `groups[0]` 跳（web 读 localStorage 是同步的，
///   本就没有这个中间态）⇒ 由调用方把 `prefsReady` 传进来；
/// · 「没有跳到首个群」= 把 JS 的空值合并 `resolvedRecent ?? …` 写成了 Dart 三元
///   `_recentResolved ? _resolvedRecent : …` ⇒ 已校验但取不到时返回 null 而不是回落到
///   `groups[0]`，页面就永远停在空态。
///
/// 取值链（R = resolvedRecent，recent = 上次进过的群）：
/// | R | recent | 结果 |
/// |---|---|---|
/// | 非空 | — | R |
/// | null（**已校验、不可用**） | 任意 | **groups[0]** |
/// | 未校验（undefined） | 有值 | null（继续等，避免跳错群再跳一次） |
/// | 未校验（undefined） | 空 | groups[0] |
String? aylaWideHomeTarget({
  required bool prefsReady,
  required bool recentValid,
  required String? recent,
  required bool recentResolved,
  required String? resolvedRecent,
  required List<String> groupIds,
}) {
  if (!prefsReady) return null; // 读盘未完成：等（否则会先跳 groups[0] 再跳 recent）
  if (recentValid) return recent;
  final String? resolved = resolvedRecent;
  if (resolved != null) return resolved;
  if (!recentResolved && recent != null) return null; // 尚未校验完 ⇒ 继续等
  return groupIds.isEmpty ? null : groupIds.first;
}

bool aylaIsRecent(int ms, int now) {
  if (ms <= 0) return false;
  return ms > now - kAylaNewContentWindowMs && ms < now + 60000;
}

/// 内容对本群可见：白名单 `allowed_group_ids` 含本群（`groupActivity.ts:71–76`）。
///
/// ⚠️ 归属群 FK **不承载可见性** —— 只有白名单算数。
bool aylaVisibleInGroup(String groupId, List<String> allowedGroupIds) {
  for (final String id in allowedGroupIds) {
    if (id == groupId) return true;
  }
  return false;
}

/// 取两个人名中可显示的一个（`groupActivity.ts:79–81` 的 `||` 链）。
String aylaDisplayName(String? nickname, String? username) {
  if (nickname != null && nickname.isNotEmpty) return nickname;
  if (username != null && username.isNotEmpty) return username;
  return '';
}

/// 消息事件（最后一条消息，含自己发的；**不依赖已读**；`groupActivity.ts:94–111`）。
AylaNewEvent? aylaMessageEvent(AylaLastMessagePreview? lastMessage, int now) {
  if (lastMessage == null) return null;
  final String? createdAt = lastMessage.createdAt;
  if (createdAt == null || createdAt.isEmpty) return null;
  final int at = aylaToMs(createdAt);
  if (!aylaIsRecent(at, now)) return null;
  final String who = lastMessage.senderName;
  // 混排消息用后端 preview；媒体消息 content 为空串 → 类型占位（tsx 102–105）
  final String preview = lastMessage.preview ?? '';
  final String content = preview.isNotEmpty
      ? preview
      : (lastMessage.content.isNotEmpty
          ? lastMessage.content
          : (kAylaMediaEventPlaceholder[lastMessage.type] ?? ''));
  // 戳一戳 preview 已是「A戳了戳B」完整文案，不加「发送者：」前缀（tsx 106–109）
  if (lastMessage.type == AylaMessageType.poke) {
    return AylaNewEvent(kind: AylaNewEventKind.message, at: at, text: content);
  }
  return AylaNewEvent(
    kind: AylaNewEventKind.message,
    at: at,
    text: '$who：$content',
  );
}

/// 群排序（`groupActivity.ts:238–259`）：置顶优先 → 组内按新内容时间新→旧 →
/// 无新内容**保持传入顺序**（稳定）。
List<T> aylaSortGroupsByActivity<T>(
  List<T> list,
  AylaGroupActivity Function(T item) keyOf, {
  bool Function(T item)? pinnedOf,
}) {
  final List<({T item, int index, bool pinned, int ts})> rows =
      <({T item, int index, bool pinned, int ts})>[
    for (int i = 0; i < list.length; i += 1)
      (
        item: list[i],
        index: i,
        pinned: pinnedOf?.call(list[i]) ?? false,
        ts: keyOf(list[i]).lastNewAt,
      ),
  ];
  rows.sort((a, b) {
    if (a.pinned != b.pinned) return b.pinned ? 1 : -1;
    if (a.ts != b.ts) return b.ts - a.ts;
    return a.index - b.index;
  });
  return <T>[for (final row in rows) row.item];
}

/// 主页活动所需的四份目录快照（`appInit.ts` 预加载的那一组）。
class AylaHomeCatalogs {
  const AylaHomeCatalogs({
    this.liveChannels = const <AylaDirectoryLiveEntry>[],
    this.voiceChannels = const <AylaDirectoryVoiceEntry>[],
    this.gameRooms = const <AylaGameRoom>[],
    this.posts = const <AylaPost>[],
  });

  /// 直播目录第一页。
  final List<AylaDirectoryLiveEntry> liveChannels;

  /// 语音目录第一页。
  final List<AylaDirectoryVoiceEntry> voiceChannels;

  /// 桌游目录第一页（角标存在性兜底用；轮播档恒关闭）。
  final List<AylaGameRoom> gameRooms;

  /// 帖子信息流第一页（limit 20；帖子轮播卡与"新帖"事件用）。
  final List<AylaPost> posts;
}

/// 「群新内容 / 角标 / 轮播」的纯函数集合（页面持有一个实例，数据变化时重建）。
///
/// 输入 = 当前页的群会话列表 + 四份目录快照；输出 = 三张查询表。
class AylaHomeActivityMap {
  AylaHomeActivityMap({
    required List<AylaConversationSummary> conversations,
    AylaHomeCatalogs catalogs = const AylaHomeCatalogs(),
    Map<String, int> groupActivityAt = const <String, int>{},
  })  : _conversations = conversations,
        _catalogs = catalogs,
        _activityAt = <String, int>{
          // 会话行自带的 `directory_activity_at`（`stores/chat.ts:145–148` 的取值来源）。
          for (final AylaConversationSummary c in conversations)
            if (c.isGroup && aylaToMs(c.directoryActivityAt) > 0)
              c.id: aylaToMs(c.directoryActivityAt),
        } {
    // `chatState.groupActivityAt`（web `groupActivity.ts:169` 订阅的同一个字段）：
    // WS 的「新内容」bump（`stores/chat.ts:87–90` / 帖子帧）写在这里。
    // 两条来源都是**单调时间戳** ⇒ 逐 key 取较大值（会话行的 `directory_activity_at`
    // 与 WS bump 谁更新谁胜出，不互相覆盖）。
    for (final MapEntry<String, int> e in groupActivityAt.entries) {
      final int row = _activityAt[e.key] ?? 0;
      if (e.value > row) _activityAt[e.key] = e.value;
    }
  }

  final List<AylaConversationSummary> _conversations;
  final AylaHomeCatalogs _catalogs;

  /// 群「最近收到新内容」的单调时间戳 —— web `chatState.groupActivityAt`
  /// （`groupActivity.ts:169/224`）与会话行的 `directory_activity_at`
  /// （`stores/chat.ts:145–148`）**取较大值**。
  ///
  /// 两个来源都是单调前进的：WS 的 bump 只前进（`chat.ts:88–90`），
  /// 会话行的 `directory_activity_at` 是后端算好的目录投影。
  final Map<String, int> _activityAt;

  /// 角标存在性（`groupActivity.ts:116–152`）。
  ///
  /// 先读会话聚合 `group_presence`（后端已算好；null = 未给）⇒ 否则扫三份目录。
  AylaGroupPresence presenceFor(String groupId) {
    for (final AylaConversationSummary c in _conversations) {
      if (c.id != groupId) continue;
      final AylaGroupPresence? aggregate = c.groupPresence;
      if (aggregate != null) return aggregate;
      break;
    }
    bool live = false;
    for (final AylaDirectoryLiveEntry c in _catalogs.liveChannels) {
      if (c.card.status == AylaLiveStatus.live &&
          aylaVisibleInGroup(groupId, c.allowedGroupIds)) {
        live = true;
        break;
      }
    }
    // 语音重点 =「有人」在语音房（member_count > 0），不是「有语音房」
    bool voice = false;
    for (final AylaDirectoryVoiceEntry c in _catalogs.voiceChannels) {
      if (aylaVisibleInGroup(groupId, c.allowedGroupIds) &&
          (c.card.memberCount ?? 0) > 0) {
        voice = true;
        break;
      }
    }
    bool game = false;
    for (final AylaGameRoom r in _catalogs.gameRooms) {
      if (aylaVisibleInGroup(groupId, r.allowedGroupIds)) {
        game = true;
        break;
      }
    }
    return AylaGroupPresence(live: live, voice: voice, game: game);
  }

  /// 新内容聚合（`groupActivity.ts:159–227`）。
  AylaGroupActivity activityFor(
    String groupId,
    AylaLastMessagePreview? lastMessage, {
    int? now,
  }) {
    final int nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    AylaNewEvent? best = aylaMessageEvent(lastMessage, nowMs);
    void consider(int at, AylaNewEvent Function() build) {
      if (!aylaIsRecent(at, nowMs)) return;
      final AylaNewEvent? current = best;
      if (current != null && at <= current.at) return;
      best = build();
    }

    for (final AylaDirectoryLiveEntry c in _catalogs.liveChannels) {
      if (c.card.status != AylaLiveStatus.live) continue;
      if (!aylaVisibleInGroup(groupId, c.allowedGroupIds)) continue;
      final int at = aylaToMs(c.startedAt);
      consider(
        at,
        () => AylaNewEvent(
          kind: AylaNewEventKind.live,
          at: at,
          text: '${c.card.ownerNickname ?? ''} 开播了 ${c.card.title}',
        ),
      );
    }
    for (final AylaDirectoryVoiceEntry c in _catalogs.voiceChannels) {
      if (!aylaVisibleInGroup(groupId, c.allowedGroupIds)) continue;
      final int at = aylaToMs(c.createdAt);
      // 显示用户填的频道名 name（room_name 是 LiveKit 内部名，如 room_fd18…）
      final String name = c.card.name.isNotEmpty ? c.card.name : c.roomName;
      consider(
        at,
        () => AylaNewEvent(
          kind: AylaNewEventKind.voice,
          at: at,
          text: '${c.card.ownerNickname ?? ''} 创建了语音房 $name',
        ),
      );
    }
    for (final AylaGameRoom r in _catalogs.gameRooms) {
      if (!aylaVisibleInGroup(groupId, r.allowedGroupIds)) continue;
      final int at = aylaToMs(r.createdAt);
      consider(
        at,
        () => AylaNewEvent(
          kind: AylaNewEventKind.game,
          at: at,
          text: '${aylaDisplayName(r.owner.nickname, r.owner.username)}'
              ' 创建了桌游房 ${r.name}',
        ),
      );
    }
    for (final AylaPost p in _catalogs.posts) {
      if (!aylaVisibleInGroup(groupId, p.allowedGroupIds)) continue;
      final int at = aylaToMs(p.createdAt);
      consider(
        at,
        () => AylaNewEvent(
          kind: AylaNewEventKind.post,
          at: at,
          text: '${aylaDisplayName(p.author?.nickname, p.author?.username)}'
              ' 发了新帖 ${p.title}',
        ),
      );
    }

    final int bumped = _activityAt[groupId] ?? 0;
    final AylaNewEvent? event = best;
    if (event == null) {
      if (bumped <= 0) return kAylaNoActivity;
      // 无「当前存在内容」推导出的新事件，但曾收到过新内容（帖子编辑/有人进语音房）：
      // 保留单调时间戳驱动排序，事件描述暂缺（列表 sub 退化为成员数兜底）。
      return AylaGroupActivity(lastNewAt: bumped);
    }
    return AylaGroupActivity(
      lastNewAt: event.at > bumped ? event.at : bumped,
      lastEvent: event,
    );
  }

  /// 群卡片状态轮播（`groupActivity.ts:300–398`）。
  ///
  /// [unreadCount] = 会话的 `unread_count`（**不含** `post_unread_count` ——
  /// `HomePage.tsx:190` 传的就是它）。
  List<AylaGroupCarouselSlide> carouselFor(
    String groupId,
    int? unreadCount, {
    int? postUnreadCount,
    int? now,
  }) {
    final int nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final List<AylaGroupCarouselSlide> slides = <AylaGroupCarouselSlide>[];

    // 1. 消息 + 语音合卡：语音按「有人」房间逐行（最多 3 个，人数降序）
    final List<AylaGroupSlideVoiceRoom> voiceRooms =
        <AylaGroupSlideVoiceRoom>[];
    for (final AylaDirectoryVoiceEntry c in _catalogs.voiceChannels) {
      if (!aylaVisibleInGroup(groupId, c.allowedGroupIds)) continue;
      final int count = c.card.memberCount ?? 0;
      if (count <= 0) continue;
      voiceRooms.add(AylaGroupSlideVoiceRoom(
        name: c.card.name.isNotEmpty ? c.card.name : c.roomName,
        memberCount: count,
      ));
    }
    voiceRooms.sort((a, b) => b.memberCount - a.memberCount);
    final List<AylaGroupSlideVoiceRoom> topRooms = voiceRooms
        .take(kAylaMaxCarouselVoiceRooms)
        .toList(growable: false);
    final int newCount = (unreadCount ?? 0) > 0 ? unreadCount! : 0;
    if (newCount > 0 || topRooms.isNotEmpty) {
      slides.add(AylaGroupCarouselSlide.messageVoice(
        newMessageCount: newCount,
        voiceRooms: topRooms,
      ));
    }

    // 2. 直播卡：每个正在直播的直播间一张
    for (final AylaDirectoryLiveEntry c in _catalogs.liveChannels) {
      if (c.card.status != AylaLiveStatus.live) continue;
      if (!aylaVisibleInGroup(groupId, c.allowedGroupIds)) continue;
      slides.add(AylaGroupCarouselSlide.live(
        host: c.card.ownerNickname ?? '',
        title: c.card.title,
        cover: (c.card.cover ?? '').isEmpty ? null : c.card.cover,
      ));
    }

    // 3. 帖子卡：窗口内最新一帖一张（含正文，图片上描边显示）
    AylaPost? latest;
    int latestAt = 0;
    for (final AylaPost p in _catalogs.posts) {
      if (!aylaVisibleInGroup(groupId, p.allowedGroupIds)) continue;
      final int at = aylaToMs(p.createdAt);
      if (!aylaIsRecent(at, nowMs)) continue;
      if (latest == null || at > latestAt) {
        latest = p;
        latestAt = at;
      }
    }
    final AylaPost? post = latest;
    if (post != null) {
      String? image;
      for (final AylaPostImage img in post.images) {
        final String? thumb = img.media?.thumbnail;
        if (thumb != null && thumb.isNotEmpty) {
          image = thumb;
          break;
        }
      }
      slides.add(AylaGroupCarouselSlide.post(
        title: post.title,
        body: post.body,
        image: image,
        hasUnread: (postUnreadCount ?? 0) > 0,
      ));
    }

    // 4. 桌游卡：开关强制关闭（与 web `SHOW_GAME_STATUS` 同值 false）
    if (kShowGameStatus) {
      for (final AylaGameRoom r in _catalogs.gameRooms) {
        if (!aylaVisibleInGroup(groupId, r.allowedGroupIds)) continue;
        if (r.status != AylaGameRoomStatus.playing) continue;
        slides.add(AylaGroupCarouselSlide.game(
          name: r.name,
          memberCount: r.memberCount,
          cover: null,
        ));
      }
    }

    return slides;
  }

  /// 会话列表 → 角标状态（`HomePage.tsx:207` 的
  /// `{unread: unread_count + post_unread_count, ...presenceFor(g.id)}`）。
  AylaAvatarStatus avatarStatusFor(AylaConversationSummary group) {
    final AylaGroupPresence presence = presenceFor(group.id);
    return AylaAvatarStatus(
      unread: group.unreadCount + (group.postUnreadCount ?? 0),
      live: presence.live,
      voice: presence.voice,
      game: presence.game,
    );
  }
}

/// 首屏骨架（`HomePage.tsx:35–47` 的 `SkeletonCards`）：
/// 两列网格 + 6 张骨架群卡（`home.css:210–215` 的 `.home-grid`、
/// `239–242` 的 `.group-card.is-skeleton`）。
///
/// 卡内两根骨架（`base.css:564–569`）：
/// ① 封面占位 = 卡片宽 `margin 8` + `aspect-ratio 4/3` + `border-radius 12`；
/// ② 标题占位 = 高 20 + `margin 8px 12px 12px` + 宽 60%。
Widget aylaHomeSkeletonGrid() {
  return Padding(
    // .home-grid: gap sp3 + padding 0 sp3 sp3
    padding: const EdgeInsets.only(
      left: AylaSpacing.sp3,
      right: AylaSpacing.sp3,
      bottom: AylaSpacing.sp3,
    ),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        const double gap = AylaSpacing.sp3;
        final double colW = (c.maxWidth - gap) / 2; // repeat(2, 1fr)
        // 封面占位宽 = 列宽 - 2×8（inline style margin: 8）
        final double coverH = (colW - 16) * 3 / 4; // aspect-ratio: 4 / 3
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (int i = 0; i < 6; i += 1)
              SizedBox(
                width: colW,
                child: Container(
                  // .group-card.is-skeleton: --glass-bg + 1px --glass-border
                  // （圆角同 .group-card 的 --radius-card）
                  decoration: BoxDecoration(
                    color: AylaColors.glassBg,
                    borderRadius: BorderRadius.circular(AylaRadii.rCard),
                    border: Border.all(color: AylaColors.glassBorder),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: SizedBox(
                          height: coverH,
                          child: const AylaSkeleton(radius: 12),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: SizedBox(
                          height: 20,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: 0.6,
                              child: AylaSkeleton(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
