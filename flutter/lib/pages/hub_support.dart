/// 三个 hub 页（VoiceHub / LiveHub / GamesHub）的页面级装配小工具。
///
/// ## 为什么是页面级模块而不是组件库件
/// 这里的三样东西**都是页面装配逻辑**，不是视觉件：
/// 1. `?type=` 与分类表的换算（web `useSearchParams` + `FILTERS.find(...)`）；
/// 2. 加载骨架的**网格排布**（web 的 `.conv-loading` 是 CSS grid，骨架块本身是既有件
///    `AylaSkeleton`）；
/// 3. 好友集合的一次性读取（web `useSocialPage("friends")` 第一页）。
/// 视觉数值全部可指回 CSS：`voice.css:506–518/649/656`、`live.css:607–614/618/644/651`。
///
/// ## 公开面
/// `aylaHubFilterOf` · `aylaHubFilterLabel` · `aylaHubColumns` ·
/// `aylaHubSkeletonGrid` · `aylaHubFriendIds`
library;

import 'package:flutter/material.dart';

import '../core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../core/models/game_room.dart' show AylaGameRoomStatus;
import '../core/models/post.dart' show AylaPost;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/models/visibility.dart' show AylaPostVisibility;
import '../state/directory_events.dart' show AylaDirectoryEvent;
import '../state/social_store.dart';
import '../theme/tokens.dart';
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/voice/voice_channels.dart' show AylaVoiceCardData;


/// 语音目录条目换人数（`voice.channel.member_count_changed` 帧 → 列表卡热更新）。
///
/// web 在 `useVoiceStore.patchChannel` 里就地改描述符；Flutter 侧的卡与条目都是
/// `@immutable`（无 `copyWith`）⇒ 由本纯函数按**逐字段搬运**生成新实例，
/// 不做近似、不改任何既有值（除人数）。
AylaDirectoryVoiceEntry aylaHubVoiceEntryWithMemberCount(
  AylaDirectoryVoiceEntry entry,
  int memberCount,
) {
  final AylaVoiceCardData card = entry.card;
  return AylaDirectoryVoiceEntry(
    card: AylaVoiceCardData(
      id: card.id,
      name: card.name,
      ownerNickname: card.ownerNickname,
      memberCount: memberCount,
      visibility: card.visibility,
      allowedGroupNames: card.allowedGroupNames,
      groupName: card.groupName,
      mine: card.mine,
    ),
    ownerId: entry.ownerId,
    createdAt: entry.createdAt,
    roomName: entry.roomName,
    allowedGroupIds: entry.allowedGroupIds,
  );
}

/// 直播目录条目换在看人数（`live.viewers.changed` 帧 → 列表卡热更新）。
///
/// web `patchChannels` 就地改 `viewer_count`；同 [aylaHubVoiceEntryWithMemberCount]
/// 的搬运口径（**人数是瞬态投影，不参与排序**）。
AylaDirectoryLiveEntry aylaHubLiveEntryWithViewerCount(
  AylaDirectoryLiveEntry entry,
  int viewerCount,
) {
  final AylaLiveCardData card = entry.card;
  return AylaDirectoryLiveEntry(
    card: AylaLiveCardData(
      id: card.id,
      title: card.title,
      cover: card.cover,
      status: card.status,
      ownerId: card.ownerId,
      ownerNickname: card.ownerNickname,
      viewerCount: viewerCount,
      visibility: card.visibility,
      allowedGroupNames: card.allowedGroupNames,
      groupName: card.groupName,
    ),
    ownerId: entry.ownerId,
    isOwner: entry.isOwner,
    startedAt: entry.startedAt,
    allowedGroupIds: entry.allowedGroupIds,
  );
}


/// 直播快照 → 目录条目（控制台把"当前频道更新/新建"同步进侧栏列表时用）。
///
/// web 在 `LiveStudioPage.tsx:41–61` 用 `applyOrdered` + `sortLiveChannels`
/// 把快照写回侧栏；Flutter 侧的侧栏读同一份 `AylaDirectoryLiveEntry` 投影 ⇒ 需要这条
/// 反向构造（`sortLiveChannels` 的排序在页面层用 `aylaHubSortLive` 表达）。
AylaDirectoryLiveEntry aylaHubLiveEntryFromSnapshot(
  AylaLiveChannelSnapshot channel, {
  required bool isOwner,
}) =>
    AylaDirectoryLiveEntry(
      card: channel.card,
      ownerId: channel.ownerId,
      isOwner: isOwner,
      startedAt: channel.startedAt,
      endedAt: channel.endedAt,
      createdAt: channel.createdAt,
      allowedGroupIds: channel.allowedGroupIds,
    );

/// 频道快照 → 目录条目（全局 `voiceState` 的描述符写回目录投影时用）。
///
/// 与 [aylaHubLiveEntryFromSnapshot] 同因：web 的 `useVoiceStore.channels` **就是**
/// `VoiceChannelDescriptor`（`stores/voice.ts:44`），目录 record 只是它的一个查询投影
/// （`stores/directory.ts:144` 的 `cachedItems` 直接返回 store 的数组）⇒ 两处同源。
/// Flutter 侧目录条目是**卡投影 + 活动事实**（`AylaDirectoryVoiceEntry`），
/// 快照是**完整描述符**（`AylaVoiceChannelSnapshot`）⇒ 需要这条反向构造。
AylaDirectoryVoiceEntry aylaHubVoiceEntryFromSnapshot(
  AylaVoiceChannelSnapshot channel,
) =>
    AylaDirectoryVoiceEntry(
      card: channel.card,
      ownerId: channel.ownerId,
      createdAt: channel.createdAt,
      roomName: channel.roomName,
      allowedGroupIds: channel.allowedGroupIds,
    );

/// 直播间排序（web `utils/sortChannels.ts` 的 `sortLiveChannels`，逐条照排）：
/// 1. 在播（`status === "live"`）置顶，按 `started_at` 降序；
/// 2. 曾播（`started_at != null`）但现在未播 → 按 `ended_at` 降序（**下播不回初始位**）；
/// 3. 从未开播 → 按 `created_at` 降序。
///
/// 排序事实源**全是后端持久字段**（无前端计数器 / 无本地时间戳 bump）⇒ 刷新不丢、多端一致
/// （web 文件头原话）。字符串比较即 ISO 时间比较（与 web 的 `localeCompare` 同语义）。
List<AylaDirectoryLiveEntry> aylaHubSortLive(
  List<AylaDirectoryLiveEntry> items,
) {
  final List<AylaDirectoryLiveEntry> sorted =
      List<AylaDirectoryLiveEntry>.of(items);
  sorted.sort((AylaDirectoryLiveEntry a, AylaDirectoryLiveEntry b) {
    final bool aLive = a.card.status == AylaLiveStatus.live;
    final bool bLive = b.card.status == AylaLiveStatus.live;
    if (aLive != bLive) return aLive ? -1 : 1;
    if (aLive) {
      return (b.startedAt ?? '').compareTo(a.startedAt ?? '');
    }
    final bool everA = a.startedAt != null;
    final bool everB = b.startedAt != null;
    if (everA != everB) return everA ? -1 : 1;
    if (everA) return (b.endedAt ?? '').compareTo(a.endedAt ?? '');
    return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
  });
  return sorted;
}

/// 目录事件对**已加载语音条目**的就地效应（纯投影）—— web `ws/chat.ts` 的
/// `voice.channel.*` 分支 + `stores/voice.ts` 的 `upsertChannel/patchChannel/removeChannel`
/// 三档对「目录列表」的净效果。
///
/// 返回 `(items, refresh)`：
/// - `deleted` ⇒ 去掉该条（web `items.filter`），`refresh: false`；
/// - 人数 `patched`（`voice.channel.member_count_changed`）⇒ 换该条人数，`refresh: false`
///   （web `stores/voice.ts:156–165` 的 `patchChannel`：**只改描述符、不重取**；
///   排序由 store 的 `sortVoiceChannels` 承担 ⇒ Flutter 侧在投影处用 [aylaHubSortVoice]）；
/// - 其余（`voice.channel.created` / `.updated` 的 `emitInvalidated`）⇒ 原列表 +
///   `refresh: true`（web 置 `invalidated` 由用户点刷新；Flutter 侧照
///   `voice_hub_page.dart:153` 的既有口径**直接重取首页**）。
({List<AylaDirectoryVoiceEntry> items, bool refresh}) aylaHubApplyVoiceEvent(
  List<AylaDirectoryVoiceEntry> items,
  AylaDirectoryEvent event,
) {
  if (event.deleted) {
    return (
      items: <AylaDirectoryVoiceEntry>[
        for (final AylaDirectoryVoiceEntry entry in items)
          if (entry.card.id != event.id) entry,
      ],
      refresh: false,
    );
  }
  final int? count = event.memberCount;
  if (count == null) return (items: items, refresh: true);
  return (
    items: <AylaDirectoryVoiceEntry>[
      for (final AylaDirectoryVoiceEntry entry in items)
        if (entry.card.id == event.id)
          aylaHubVoiceEntryWithMemberCount(entry, count)
        else
          entry,
    ],
    refresh: false,
  );
}

/// 同上，直播档（web `ws/chat.ts` 的 `live.channel.*` / `live.viewers.changed`）。
///
/// - `deleted` ⇒ 去掉该条；
/// - 人数 `patched`（`live.viewers.changed`）⇒ 只换在看人数（web `stores/live.ts:218–224`
///   的 `patchViewerCount` 原话：**瞬态投影，不拉 REST、不标失效、不改排序**）；
/// - 其余（created / updated / status.changed）⇒ `refresh: true`。
({List<AylaDirectoryLiveEntry> items, bool refresh}) aylaHubApplyLiveEvent(
  List<AylaDirectoryLiveEntry> items,
  AylaDirectoryEvent event,
) {
  if (event.deleted) {
    return (
      items: <AylaDirectoryLiveEntry>[
        for (final AylaDirectoryLiveEntry entry in items)
          if (entry.card.id != event.id) entry,
      ],
      refresh: false,
    );
  }
  final int? count = event.memberCount;
  if (count == null) return (items: items, refresh: true);
  return (
    items: <AylaDirectoryLiveEntry>[
      for (final AylaDirectoryLiveEntry entry in items)
        if (entry.card.id == event.id)
          aylaHubLiveEntryWithViewerCount(entry, count)
        else
          entry,
    ],
    refresh: false,
  );
}

/// 语音房排序判据 —— web `VoiceChannelDescriptor` 里 `sortVoiceChannels` 真正读的四个字段
/// （`utils/sortChannels.ts:32–46`：`member_count` / `last_occupied_at` /
/// `last_vacant_at` / `created_at`）。
///
/// ## 为什么单独一个判据类（而不是直接排 `AylaDirectoryVoiceEntry`）
/// web 的目录条目**就是** `VoiceChannelDescriptor`（含上述四字段）。Flutter 侧分了两层：
/// - 分页条目 `AylaDirectoryVoiceEntry`（`core/api/voice_api.dart:18–62`）只带
///   `card.memberCount` 与 `createdAt`；
/// - **全局**频道快照 `AylaVoiceChannelSnapshot`（同文件 `:71–187`）带全部四字段
///   （`memberCount` / `lastOccupiedAt` / `lastVacantAt` / `createdAt`），
///   字段名与 web 逐条对应。
/// ⇒ 与 web **同源**的做法是：排序读**全局那份**（web `stores/directory.ts:161` 正是
/// `record.items.map((item) => after.get(String(item.id)) ?? item)` —— 用 voice store 的
/// 描述符**替换** directory record 的同 id 项，侧栏行在 web 上就是 voice store 那一份）。
/// 缺席（该 id 不在全局表里）⇒ 按「无历史」档处理，**不伪造时间戳**。
@immutable
class AylaVoiceSortFacts {
  const AylaVoiceSortFacts({
    required this.memberCount,
    this.lastOccupiedAt,
    this.lastVacantAt,
    this.createdAt,
  });

  /// `member_count`（`Number(a.member_count) > 0` 判「有人区」，web `sortChannels.ts:34`）。
  final int memberCount;

  /// `last_occupied_at`（ISO；null = 后端未给）。
  final String? lastOccupiedAt;

  /// `last_vacant_at`（ISO；null = 后端未给）。
  final String? lastVacantAt;

  /// `created_at`（ISO；null = 后端未给 ⇒ 按 web `b.created_at.localeCompare` 的空串档）。
  final String? createdAt;

  /// 从全局频道快照取（字段逐一搬运，不改值）。
  factory AylaVoiceSortFacts.ofSnapshot(AylaVoiceChannelSnapshot c) =>
      AylaVoiceSortFacts(
        memberCount: c.memberCount ?? 0,
        lastOccupiedAt: c.lastOccupiedAt,
        lastVacantAt: c.lastVacantAt,
        createdAt: c.createdAt,
      );

  /// 从分页条目取（**只有** `memberCount` 与 `createdAt` 可用；两个时间戳留 null
  /// —— 见类文档的字段缺口登记）。
  factory AylaVoiceSortFacts.ofEntry(AylaDirectoryVoiceEntry entry) =>
      AylaVoiceSortFacts(
        memberCount: entry.card.memberCount ?? 0,
        createdAt: entry.createdAt,
      );
}

/// ISO 时间字符串 → ms（web `toMs`，`utils/sortChannels.ts:26–30`：null/非法 → 0）。
///
/// web 实现是 `Date.parse(value)` + `Number.isFinite`；Dart 的 `DateTime.tryParse`
/// 对非法值返回 null ⇒ 归 0，**同序**（null 与非法都排在最早）。
int aylaSortToMs(String? value) {
  if (value == null || value.isEmpty) return 0;
  return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
}

/// 语音房排序（web `utils/sortChannels.ts:32–46` 的 `sortVoiceChannels`，逐条照排）：
/// 1. **有人区**（`member_count > 0`）整体置顶，内部按 `last_occupied_at` 新→旧；
/// 2. **无人但有历史**（`last_occupied_at != null \|\| last_vacant_at != null`）
///    ⇒ 按 `last_vacant_at` 新→旧（**变空不回初始位**）；
/// 3. **从未有人** ⇒ `created_at` 降序。
///
/// 排序事实源**全是后端持久字段**（无前端计数器 / 无本地时间戳 bump）⇒ 刷新不丢、多端一致
/// （web 文件头原话）。字符串比较即 ISO 时间比较（与 web 的 `toMs` 差值同序）。
///
/// ⚠️ [factsOf] 缺席的条目按 [AylaVoiceSortFacts.ofEntry] 处理（只有人数与创建时间）。
/// ⚠️ Dart 的 `List.sort` **不稳定**（web 的 `Array.sort` 稳定）⇒ 显式带原索引做末位比较。
List<AylaDirectoryVoiceEntry> aylaHubSortVoice(
  List<AylaDirectoryVoiceEntry> items, {
  Map<String, AylaVoiceSortFacts> factsOf = const <String, AylaVoiceSortFacts>{},
}) {
  final List<AylaDirectoryVoiceEntry> sorted =
      List<AylaDirectoryVoiceEntry>.of(items);
  final Map<AylaDirectoryVoiceEntry, int> order = <AylaDirectoryVoiceEntry, int>{
    for (int i = 0; i < sorted.length; i++) sorted[i]: i,
  };
  sorted.sort((AylaDirectoryVoiceEntry a, AylaDirectoryVoiceEntry b) {
    final AylaVoiceSortFacts fa =
        factsOf[a.card.id] ?? AylaVoiceSortFacts.ofEntry(a);
    final AylaVoiceSortFacts fb =
        factsOf[b.card.id] ?? AylaVoiceSortFacts.ofEntry(b);
    final bool aOccupied = fa.memberCount > 0;
    final bool bOccupied = fb.memberCount > 0;
    if (aOccupied != bOccupied) return aOccupied ? -1 : 1;
    if (aOccupied) {
      final int byOccupied = aylaSortToMs(fb.lastOccupiedAt) -
          aylaSortToMs(fa.lastOccupiedAt);
      if (byOccupied != 0) return byOccupied;
      return (order[a] ?? 0) - (order[b] ?? 0);
    }
    final bool everA = fa.lastOccupiedAt != null || fa.lastVacantAt != null;
    final bool everB = fb.lastOccupiedAt != null || fb.lastVacantAt != null;
    if (everA != everB) return everA ? -1 : 1;
    if (everA) {
      final int byVacant =
          aylaSortToMs(fb.lastVacantAt) - aylaSortToMs(fa.lastVacantAt);
      if (byVacant != 0) return byVacant;
      return (order[a] ?? 0) - (order[b] ?? 0);
    }
    final int byCreated =
        (fb.createdAt ?? '').compareTo(fa.createdAt ?? '');
    if (byCreated != 0) return byCreated;
    return (order[a] ?? 0) - (order[b] ?? 0);
  });
  return sorted;
}

/// `?type=` → 合法分类键（未知/缺省 → `all`；web `VoiceHubPage.tsx:53` 同）。
String aylaHubFilterOf(List<({String key, String label})> filters, String? raw) {
  if (raw == null) return 'all';
  for (final ({String key, String label}) item in filters) {
    if (item.key == raw) return item.key;
  }
  return 'all';
}

/// 分类键 → 文案（`AylaDirectoryContent.label` 的 tabpanel 可访问名用）。
String aylaHubFilterLabel(
  List<({String key, String label})> filters,
  String key,
) {
  for (final ({String key, String label}) item in filters) {
    if (item.key == key) return item.label;
  }
  return '';
}

/// `.voice-hub .conv-loading` / `.live-hub .conv-loading` 的列数：
/// <769 → 2；769–1439 → 3；≥1440 → 4。
int aylaHubColumns(BuildContext context) {
  final double w = MediaQuery.sizeOf(context).width;
  if (w >= AylaBreakpoints.lg) return 4; // 1440
  if (w > AylaBreakpoints.sm) return 3; // >768
  return 2;
}

/// 加载骨架网格（web `.conv-loading` 的两根骨架）。
///
/// - [skeletonHeight]：web inline style 的高（语音 64 / 直播 96）；
/// - 首根骨架带 `marginBottom: 8`（web inline style）⇒ 用 bottom padding 表达；
/// - [gap]：语音 `gap: var(--sp-3)`（`voice.css:509`）、直播 `gap: var(--sp-4)`
///   （`live.css:609`）；
/// - [padding]：语音 `padding: var(--sp-3) var(--sp-4)`（`voice.css:510`）；
///   直播只有窄屏才带同样的 padding（`live.css:621`）。
Widget aylaHubSkeletonGrid(
  BuildContext context, {
  required double skeletonHeight,
  required double gap,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
}) {
  const int count = 2; // web 恒两根
  final int cols = aylaHubColumns(context);
  return Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: <Widget>[
        for (int start = 0; start < count; start += cols)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: gap,
            children: <Widget>[
              for (int i = start; i < count && i < start + cols; i++)
                Expanded(
                  child: Padding(
                    // 首根 `marginBottom: 8`（web inline style）
                    padding: EdgeInsets.only(bottom: i == 0 ? 8 : 0),
                    child: AylaSkeleton(height: skeletonHeight),
                  ),
                ),
              // 网格语义：末行不足列数时补空位（列宽不拉伸）
              for (int i = count; i < start + cols; i++)
                const Expanded(child: SizedBox.shrink()),
            ],
          ),
      ],
    ),
  );
}

/// 好友集合（web `useSocialPage("friends")` 的 `items.map(f => f.user.id)`）。
///
/// ⚠️ 与 web 同：**只取第一页**（`stores/social.ts:129` 的 `limit: 30`）——
/// 超过一页的好友不会被前端二次过滤命中；这是 web 的现状（页面层过滤兜底），
/// 不是本实现的选择。失败 → 空集合（好友 tab 显示空态，不伪造好友关系）。
/// 数据源改为**共享 store**（web `useSocialPage("friends")` ⇒ `stores/social.ts`）：
/// 首次取页后 60 秒内（`social.ts:150`）任意页面再问都不发请求；
/// `appInit` 也会预取同组合。未登录时 store 直返（`social.ts:148`）⇒ 空集合。
Future<Set<String>> aylaHubFriendIds() async {
  const AylaSocialOptions options = AylaSocialOptions();
  try {
    await aylaSocialStore.load(AylaSocialKind.friends, options);
    final List<AylaUserPublic> friends =
        aylaSocialStore.itemsAs<AylaUserPublic>(AylaSocialKind.friends, options);
    return <String>{for (final AylaUserPublic user in friends) user.id};
  } catch (_) {
    return const <String>{};
  }
}

/// 语音大厅分类的前端二次过滤（web VoiceHubPage.tsx:76–87，逐条）。
///
/// `all` 不在这里判（调用方直接跳过），但保留 `default: true` 以免未知分类静默丢弃。
bool aylaHubMatchVoice(
  AylaDirectoryVoiceEntry entry,
  String filter, {
  Set<String> friendIds = const <String>{},
  String? currentUserId,
}) {
  switch (filter) {
    case 'public':
      return entry.card.visibility == AylaPostVisibility.public;
    case 'friends':
      return friendIds.contains(entry.ownerId);
    case 'occupied':
      return (entry.card.memberCount ?? 0) > 0;
    case 'mine':
      return currentUserId != null && entry.ownerId == currentUserId;
    default:
      return true;
  }
}

/// 直播大厅分类的前端二次过滤（web LiveHubPage.tsx:63–75，逐条）。
bool aylaHubMatchLive(
  AylaDirectoryLiveEntry entry,
  String filter, {
  Set<String> friendIds = const <String>{},
}) {
  switch (filter) {
    case 'live':
      return entry.card.status == AylaLiveStatus.live;
    case 'public':
      return entry.card.visibility == AylaPostVisibility.public;
    case 'friends':
      return friendIds.contains(entry.ownerId);
    case 'offline':
      return entry.card.status != AylaLiveStatus.live;
    case 'mine':
      return entry.isOwner;
    default:
      return true;
  }
}

/// 帖子分类 → 后端查询（web `PostsHubPage.tsx:54–60` 的 `TAB_QUERY`）。
///
/// 口径（tsx 52–53 注释）：「我的」独立拉 `scope=mine`；公开/好友由**后端**过滤
/// （不依赖「全部」的分页进度）；热门/全部拉 feed 后**前端**排序/过滤。
class AylaPostTabQuery {
  const AylaPostTabQuery({
    required this.scope,
    this.visibility,
    this.friends = false,
  });

  /// `scope`（`feed` / `mine`；web `PostScope`）。
  final String scope;

  /// `visibility`（仅公开档传 `public`）。
  final String? visibility;

  /// `friends=1`（仅好友档传）。
  final bool friends;
}

/// 分类 → 后端参数（逐条对齐 tsx 54–60；`all`/`hot` 只传 `scope=feed`）。
AylaPostTabQuery aylaPostTabQuery(String filter) {
  switch (filter) {
    case 'public':
      return const AylaPostTabQuery(scope: 'feed', visibility: 'public');
    case 'friends':
      return const AylaPostTabQuery(scope: 'feed', friends: true);
    case 'mine':
      return const AylaPostTabQuery(scope: 'mine');
    default:
      return const AylaPostTabQuery(scope: 'feed');
  }
}

/// 帖子分类的前端二次过滤 + 热门排序（web `PostsHubPage.tsx:124–129`，逐条）。
///
/// - 热门档：**只排序不筛内容**（`view_count` 降序；两侧任一为 null 时按 web 的
///   `NaN` 比较语义**保持原顺序**，不把 null 当 0 排序）；
/// - 公开档：`visibility === "public"`；
/// - 好友档：`author_id ∈ 好友集合`（`author_id` 缺席 ⇒ 不命中，不伪造）；
/// - 其余（全部 / 我的）：原样返回（我的档后端过滤已完成）。
List<AylaPost> aylaHubVisiblePosts(
  List<AylaPost> posts,
  String filter, {
  Set<String> friendIds = const <String>{},
}) {
  switch (filter) {
    case 'hot':
      final List<AylaPost> sorted = List<AylaPost>.of(posts);
      sorted.sort((AylaPost a, AylaPost b) {
        final int? av = a.viewCount;
        final int? bv = b.viewCount;
        if (av == null || bv == null) return 0; // web: NaN 比较恒 false ⇒ 原序
        return bv.compareTo(av);
      });
      return sorted;
    case 'public':
      return <AylaPost>[
        for (final AylaPost p in posts)
          if (p.visibility == AylaPostVisibility.public) p,
      ];
    case 'friends':
      return <AylaPost>[
        for (final AylaPost p in posts)
          if (p.authorId != null && friendIds.contains(p.authorId)) p,
      ];
    default:
      return posts;
  }
}

/// 桌游大厅分类的前端二次过滤（web GamesHubPage.tsx:70–82，逐条）。
bool aylaHubMatchGame(
  AylaDirectoryGameEntry entry,
  String filter, {
  Set<String> friendIds = const <String>{},
}) {
  switch (filter) {
    case 'public':
      return entry.card.visibility == AylaPostVisibility.public;
    case 'friends':
      return friendIds.contains(entry.ownerId);
    case 'mine':
      return entry.isOwner;
    case 'waiting':
      return entry.card.status == AylaGameRoomStatus.waiting;
    case 'playing':
      return entry.card.status == AylaGameRoomStatus.playing;
    default:
      return true;
  }
}
