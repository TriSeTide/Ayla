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
import '../core/api/users_api.dart';
import '../core/api/voice_api.dart' show AylaDirectoryVoiceEntry;
import '../core/models/game_room.dart' show AylaGameRoomStatus;
import '../core/models/post.dart' show AylaPost;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/models/visibility.dart' show AylaPostVisibility;
import '../theme/tokens.dart';
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/base/loading.dart' show AylaSkeleton;

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
Future<Set<String>> aylaHubFriendIds() async {
  try {
    final List<AylaUserPublic> friends = await AylaUsersApi.listFriendsPage();
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
