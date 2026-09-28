/// 聚合搜索 API（web api/search.ts 37 行）。
///
/// - GET /search/?q=&types=&limit=&pagination=cursor&cursor=
///   —— 六类分组（user/group/post/live/game/voice）；每组 items + total
///   （截断后的条目 + 截断前的匹配总数分离）；q 空 → 400。
///
/// 六类的条目类型逐个对应 web：
/// users → UserPublic 的搜索页子集（本文件 AylaSearchUserItem）
/// groups → SearchGroupItem（本文件 AylaSearchGroupItem）
/// posts → Post · lives → LiveChannelDescriptor 卡投影 · games → GameRoom 卡投影 ·
/// voices → VoiceChannelDescriptor 卡投影。
///
/// ⚠️ 三域条目用**卡投影**（不是完整 descriptor）：搜索结果只渲染卡片
/// （SearchPage.tsx:440/448/455 传 action={null} / browsing），完整 descriptor 的
/// 其余字段没有消费者。
library;

import '../models/game_room.dart' show AylaGameCardData;
import '../models/post.dart' show AylaPost;
import '../models/subgroup.dart' show AylaGroupJoinPolicy;
import '../net/dio_client.dart';
import '../../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../../widgets/voice/voice_channels.dart' show AylaVoiceCardData;

/// 搜索结果里的用户条目（web SearchPage 消费的 UserPublic 字段子集）。
///
/// 为什么不是 AylaUserPublic：搜索用户行渲染 **signature 副行**
/// （SearchPage.tsx:405）+ 头像点击进主页 + 资料浮层 —— signature 只在
/// UserPublic（api/types.ts:13）里，而 AylaUserPublic 是 chat 域投影
/// （不含 signature，见其文件头）。这里只带出搜索页真正消费的字段。
class AylaSearchUserItem {
  const AylaSearchUserItem({
    required this.id,
    this.username,
    this.nickname,
    this.avatar,
    this.signature,
    this.online = false,
  });

  final String id;
  final String? username;
  final String? nickname;
  final String? avatar;
  final String? signature;

  /// 实时在线（后端 online 字段；web 侧由 presence store 覆盖 —— 见页面登记）。
  final bool online;

  /// 展示名（web 的 nickname || username）。
  String get displayName {
    final String nick = (nickname ?? '').trim();
    if (nick.isNotEmpty) return nick;
    return (username ?? '').trim();
  }

  static AylaSearchUserItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final String idText = id.toString();
    if (idText.isEmpty) return null;
    return AylaSearchUserItem(
      id: idText,
      username: raw['username']?.toString(),
      nickname: raw['nickname']?.toString(),
      avatar: raw['avatar']?.toString(),
      signature: raw['signature']?.toString(),
      online: raw['online'] == true,
    );
  }
}

/// 群搜索结果项（web SearchGroupItem，api/types.ts:1405–1417）。
class AylaSearchGroupItem {
  const AylaSearchGroupItem({
    required this.id,
    required this.title,
    this.isMember,
    this.avatar,
    this.memberCount,
    this.joinPolicy,
    this.createdAt,
  });

  final String id;
  final String title;

  /// 服务端权威的成员关系（独立于已加载的会话分页，types.ts:1407）。
  ///
  /// ⚠️ 三态：null = **响应没给**（旧后端）⇒ 页面回退到「已加入的会话集合」判断
  /// （SearchPage.tsx:144–148 的第四级兜底），不把「没给」当成「未加入」。
  final bool? isMember;

  /// 群头像 content URL（旧响应可缺省）。
  final String? avatar;

  final int? memberCount;

  /// 加入方式（旧数据缺失 → null；弹窗件按「申请制」文案兜底）。
  final AylaGroupJoinPolicy? joinPolicy;

  final String? createdAt;

  static AylaSearchGroupItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final String idText = id.toString();
    if (idText.isEmpty) return null;
    return AylaSearchGroupItem(
      id: idText,
      title: raw['title']?.toString() ?? '',
      isMember: raw['is_member'] is bool ? raw['is_member'] as bool : null,
      avatar: raw['avatar']?.toString(),
      memberCount: (raw['member_count'] as num?)?.toInt(),
      joinPolicy: AylaGroupJoinPolicy.parse(raw['join_policy']),
      createdAt: raw['created_at']?.toString(),
    );
  }
}

/// 某类结果组（web 的泛型 SearchGroup + 游标分页扩展，api/search.ts:12–17）。
class AylaSearchGroup<T> {
  const AylaSearchGroup({
    this.items = const <Never>[],
    this.total = 0,
    this.nextCursor,
    this.hasMore = false,
  });

  final List<T> items;

  /// 截断前的匹配总数。
  final int total;

  final String? nextCursor;
  final bool hasMore;

  static AylaSearchGroup<T>? fromJson<T>(
    Object? raw,
    T? Function(Object? raw) parseItem,
  ) {
    if (raw is! Map) return null;
    return AylaSearchGroup<T>(
      items: <T>[
        for (final Object? item
            in (raw['items'] as List<Object?>? ?? const <Object?>[]))
          if (parseItem(item) case final T parsed) parsed,
      ],
      total: (raw['total'] as num?)?.toInt() ?? 0,
      nextCursor: raw['next_cursor']?.toString(),
      hasMore: raw['has_more'] == true,
    );
  }
}

/// GET /search/ 的返回：**只含被请求的类型**（其余为 null）。
class AylaSearchResults {
  const AylaSearchResults({
    this.users,
    this.groups,
    this.posts,
    this.lives,
    this.games,
    this.voices,
  });

  final AylaSearchGroup<AylaSearchUserItem>? users;
  final AylaSearchGroup<AylaSearchGroupItem>? groups;
  final AylaSearchGroup<AylaPost>? posts;
  final AylaSearchGroup<AylaLiveCardData>? lives;
  final AylaSearchGroup<AylaGameCardData>? games;
  final AylaSearchGroup<AylaVoiceCardData>? voices;

  static AylaSearchResults fromJson(Object? raw) {
    if (raw is! Map) return const AylaSearchResults();
    return AylaSearchResults(
      users: AylaSearchGroup.fromJson<AylaSearchUserItem>(
        raw['users'],
        AylaSearchUserItem.fromJson,
      ),
      groups: AylaSearchGroup.fromJson<AylaSearchGroupItem>(
        raw['groups'],
        AylaSearchGroupItem.fromJson,
      ),
      posts: AylaSearchGroup.fromJson<AylaPost>(raw['posts'], AylaPost.fromJson),
      lives: AylaSearchGroup.fromJson<AylaLiveCardData>(
        raw['lives'],
        AylaLiveCardData.fromJson,
      ),
      games: AylaSearchGroup.fromJson<AylaGameCardData>(
        raw['games'],
        AylaGameCardData.fromJson,
      ),
      voices: AylaSearchGroup.fromJson<AylaVoiceCardData>(
        raw['voices'],
        AylaVoiceCardData.fromJson,
      ),
    );
  }

  /// 六类 total 之和（侧栏统计行，SearchPage.tsx:93–96）。
  int get totalResults =>
      (users?.total ?? 0) +
      (groups?.total ?? 0) +
      (posts?.total ?? 0) +
      (lives?.total ?? 0) +
      (games?.total ?? 0) +
      (voices?.total ?? 0);

  /// 六类是否全空（决定无结果空态，SearchPage.tsx:290–295）。
  bool get hasAnyResult => totalResults > 0;
}

class AylaSearchApi {
  const AylaSearchApi._();

  /// GET /search/?q=&types=&limit=&pagination=cursor&cursor= —— 一页分组结果。
  static Future<AylaSearchResults> searchPage({
    required String q,
    List<String>? types,
    int limit = 20,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'q': q,
      'pagination': 'cursor',
      'limit': limit.toString(),
    };
    if (types != null && types.isNotEmpty) query['types'] = types.join(',');
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/search/', query: query);
    return AylaSearchResults.fromJson(resp);
  }
}
