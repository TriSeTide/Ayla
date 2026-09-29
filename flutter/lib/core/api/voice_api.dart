/// 语音目录 API（web api/voice.ts 219 行的**目录子集**）。
///
/// 本轮（第二批三个 hub 页）只带出大厅需要的读接口：
/// - `GET /voice/channels/`?limit=&cursor=&visibility=&friends=&occupied=&owner=
///   —— 游标分页目录（api/voice.ts:38–54），响应带 total_member_count
///   （侧栏「X 房间在线 · Y 人在聊」的第二个数字，directory.ts:7）；
///
/// join / leave / heartbeat / members / messages / 爱莉 voice-calls 等随房内页批次带出。
library;

import '../models/visibility.dart' show AylaPostVisibility;
import '../net/dio_client.dart';
import '../../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import 'directory_page.dart';
import 'media_page.dart';

/// 语音目录条目（卡投影 + 「我的」过滤事实 + 主页「新内容」事实）。
class AylaDirectoryVoiceEntry {
  const AylaDirectoryVoiceEntry({
    required this.card,
    this.ownerId = '',
    this.createdAt,
    this.roomName = '',
    this.allowedGroupIds = const <String>[],
  });

  final AylaVoiceCardData card;

  /// owner_id —— 「我的」分类的前端二次过滤判据
  /// （VoiceHubPage.tsx:83：channel.owner_id === currentUserId；
  /// 语音卡投影不承载 owner_id，故在这里保留）。
  final String ownerId;

  /// `created_at`（`types.ts:881`）—— 「新语音房被创建」事件的时间
  /// （`groupActivity.ts:188`）。
  final String? createdAt;

  /// `room_name`（`types.ts:866`）—— 房间名兜底：web 取 `c.name || c.room_name`
  /// （`groupActivity.ts:192`）。
  final String roomName;

  /// `allowed_group_ids`（`types.ts:877`）—— 白名单可见性判据
  /// （`groupActivity.ts:70–76` 的 `visibleInGroup`）。
  final List<String> allowedGroupIds;

  static AylaDirectoryVoiceEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaVoiceCardData? card = AylaVoiceCardData.fromJson(raw);
    if (card == null) return null;
    return AylaDirectoryVoiceEntry(
      card: card,
      ownerId: raw['owner_id']?.toString() ?? '',
      createdAt: raw['created_at'] as String?,
      roomName: raw['room_name']?.toString() ?? '',
      allowedGroupIds: <String>[
        for (final Object? id
            in (raw['allowed_group_ids'] as List<Object?>? ?? const <Object?>[]))
          if (id != null) id.toString(),
      ],
    );
  }
}

/// 语音房频道快照 —— web `VoiceChannelDescriptor`（`api/types.ts:863–885`）在
/// Flutter 侧的投影。
///
/// 为什么单独一个类型：房内页需要 `owner_id` / `group` / `visibility` /
/// `member_count` 等字段，而 `AylaVoiceCardData`（列表卡投影）只承载渲染列表卡所需
/// （名字/人数/来源标签）——**不改动已验收的那个类**（跨组件改动需单独批准），由页面层
/// 在两个投影之间映射（与 `live_channel_snapshot.dart` 对直播侧做的一样）。
class AylaVoiceChannelSnapshot {
  const AylaVoiceChannelSnapshot({
    required this.id,
    required this.name,
    this.roomName = '',
    this.ownerId = '',
    this.ownerNickname,
    this.memberCount,
    this.visibility,
    this.group,
    this.groupName,
    this.allowedGroupIds = const <String>[],
    this.allowedGroupNames = const <String>[],
    this.mine = false,
    this.createdAt,
    this.lastOccupiedAt,
    this.lastVacantAt,
  });

  final String id;
  final String name;

  /// `room_name`（web 用 `c.name || c.room_name` 兜底）。
  final String roomName;

  final String ownerId;
  final String? ownerNickname;

  /// `member_count`；null = 后端没给（**不写 0**）。
  final int? memberCount;

  final AylaPostVisibility? visibility;

  /// 群归属（一级 tab 创建为 null）。
  final String? group;
  final String? groupName;
  final List<String> allowedGroupIds;
  final List<String> allowedGroupNames;

  /// 我是否在该频道（列表/详情视图注入）。
  final bool mine;

  final String? createdAt;

  /// 侧栏排序投影（后端持久化）。
  final String? lastOccupiedAt;
  final String? lastVacantAt;

  /// 卡投影（列表卡渲染用；同一份响应两处消费）。
  AylaVoiceCardData get card => AylaVoiceCardData(
        id: id,
        name: displayName,
        ownerNickname: ownerNickname,
        memberCount: memberCount,
        visibility: visibility,
        allowedGroupNames: allowedGroupNames,
        groupName: groupName,
        mine: mine,
      );

  /// head 标题（web `VoiceRoomBody` 的 `channelName={currentChannel.name}`）。
  String get displayName => name.isNotEmpty ? name : roomName;

  /// 可见性标签（web `getVisibilityLabels(channel)`；`card.visibilityLabels` 同源）。
  List<String> get visibilityLabels => card.visibilityLabels;

  /// 解析（缺席即缺席；未知 visibility → null）。
  static AylaVoiceChannelSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final String idText = id.toString();
    if (idText.isEmpty) return null;
    return AylaVoiceChannelSnapshot(
      id: idText,
      name: raw['name']?.toString() ?? '',
      roomName: raw['room_name']?.toString() ?? '',
      ownerId: raw['owner_id']?.toString() ?? '',
      ownerNickname: raw['owner_nickname']?.toString(),
      memberCount: (raw['member_count'] as num?)?.toInt(),
      visibility: AylaPostVisibility.parse(raw['visibility']?.toString()),
      group: raw['group']?.toString(),
      groupName: raw['group_name']?.toString(),
      allowedGroupIds: _stringList(raw['allowed_group_ids']),
      allowedGroupNames: _stringList(raw['allowed_group_names']),
      mine: raw['mine'] == true,
      createdAt: raw['created_at']?.toString(),
      lastOccupiedAt: raw['last_occupied_at']?.toString(),
      lastVacantAt: raw['last_vacant_at']?.toString(),
    );
  }

  /// 只改「人数 / 我在其中 / 排序投影」三档（web `patchChannel`）。
  AylaVoiceChannelSnapshot patch({
    int? memberCount,
    bool? mine,
    String? lastOccupiedAt,
    String? lastVacantAt,
  }) =>
      AylaVoiceChannelSnapshot(
        id: id,
        name: name,
        roomName: roomName,
        ownerId: ownerId,
        ownerNickname: ownerNickname,
        memberCount: memberCount ?? this.memberCount,
        visibility: visibility,
        group: group,
        groupName: groupName,
        allowedGroupIds: allowedGroupIds,
        allowedGroupNames: allowedGroupNames,
        mine: mine ?? this.mine,
        createdAt: createdAt,
        lastOccupiedAt: lastOccupiedAt ?? this.lastOccupiedAt,
        lastVacantAt: lastVacantAt ?? this.lastVacantAt,
      );
}

/// JSON 字符串数组（缺席 ⇒ 空数组；不造占位项）。
List<String> _stringList(Object? raw) => <String>[
      for (final Object? item in (raw as List<Object?>? ?? const <Object?>[]))
        if (item != null) item.toString(),
    ];

/// 成员行（`VoiceChannelMemberSerializer`，`api/types.ts:888–893`）。
class AylaVoiceMemberDescriptor {
  const AylaVoiceMemberDescriptor({
    required this.id,
    required this.userId,
    this.joinedAt,
    this.lastSeenAt,
  });

  final int id;
  final String userId;
  final String? joinedAt;
  final String? lastSeenAt;

  static AylaVoiceMemberDescriptor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? userId = raw['user_id'];
    if (userId == null) return null;
    return AylaVoiceMemberDescriptor(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      userId: userId.toString(),
      joinedAt: raw['joined_at']?.toString(),
      lastSeenAt: raw['last_seen_at']?.toString(),
    );
  }
}

/// 房内聊天消息（`VoiceChatMessage`，`api/types.ts:895–906`）。
class AylaVoiceChatMessage {
  const AylaVoiceChatMessage({
    required this.id,
    required this.channelId,
    required this.senderNickname,
    this.senderUserId = '',
    this.senderAvatarUrl = '',
    this.content = '',
    this.mediaId,
    this.thumbnailUrl,
    this.createdAt = '',
  });

  final String id;
  final String channelId;
  final String senderNickname;
  final String senderUserId;
  final String senderAvatarUrl;
  final String content;
  final String? mediaId;

  /// 缩略图 URL（web `resolveMediaPath(media.thumbnail) ?? mediaContentUrl(media_id)`）。
  final String? thumbnailUrl;
  final String createdAt;

  static AylaVoiceChatMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final Map<dynamic, dynamic>? sender =
        raw['sender'] is Map ? raw['sender'] as Map<dynamic, dynamic> : null;
    final Map<dynamic, dynamic>? media =
        raw['media'] is Map ? raw['media'] as Map<dynamic, dynamic> : null;
    return AylaVoiceChatMessage(
      id: id.toString(),
      channelId: raw['channel_id']?.toString() ?? '',
      senderNickname: sender?['nickname']?.toString() ?? '',
      senderUserId: sender?['user_id']?.toString() ?? '',
      senderAvatarUrl: sender?['avatar']?.toString() ?? '',
      content: raw['content']?.toString() ?? '',
      mediaId: raw['media_id']?.toString(),
      thumbnailUrl: media == null ? null : media['thumbnail']?.toString(),
      createdAt: raw['created_at']?.toString() ?? '',
    );
  }
}

/// `POST join/` 回执（`VoiceJoinResult`，`api/types.ts:909–913`）。
class AylaVoiceJoinResult {
  const AylaVoiceJoinResult({
    required this.channelId,
    required this.roomName,
    required this.joined,
  });

  final String channelId;
  final String roomName;
  final bool joined;

  static AylaVoiceJoinResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return AylaVoiceJoinResult(
      channelId: raw['channel_id']?.toString() ?? '',
      roomName: raw['room_name']?.toString() ?? '',
      joined: raw['joined'] == true,
    );
  }
}

/// 成员对账被中止（上游账号在读取途中变化）——web 抛 `AbortError` 的等价物。
///
/// 语义：**丢弃这次结果**，不要拿旧账号的对账铺新账号的成员表
/// （web `api/voice.ts:125/127`）。
class AylaVoiceReconcileAborted implements Exception {
  const AylaVoiceReconcileAborted(this.message);

  final String message;

  @override
  String toString() => message;
}

class AylaVoiceApi {
  const AylaVoiceApi._();

  /// `GET /voice/channels/` —— 目录分页（DirectoryPage，条目为 VoiceChannelDescriptor）。
  ///
  /// 过滤参数逐个对应 web VoiceHubPage.tsx:58–64：
  /// visibility / friends / occupied / owner 由**后端执行**。
  static Future<AylaDirectoryPage<AylaDirectoryVoiceEntry>>
      listVoiceChannelsPage({
    int limit = 20,
    String? cursor,
    String? groupId,
    String? owner,
    bool friends = false,
    bool occupied = false,
    AylaPostVisibility? visibility,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': '$limit'};
    if (cursor != null) query['cursor'] = cursor;
    if (groupId != null) query['group_id'] = groupId;
    if (owner != null) query['owner'] = owner;
    if (friends) query['friends'] = '1';
    if (occupied) query['occupied'] = '1';
    if (visibility != null) query['visibility'] = visibility.wire;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/voice/channels/', query: query);
    return AylaDirectoryPage.fromJson<AylaDirectoryVoiceEntry>(
      resp,
      AylaDirectoryVoiceEntry.fromJson,
    );
  }

  /// `GET /voice/channels/<id>/` —— 详情（含 member_count/mine）。
  ///
  /// web `api/voice.ts:65–69`；房内页在「大厅列表还没返回」时也直接拉详情
  /// （`VoiceHubPage.tsx:168–179`），保证房内界面能渲染。
  static Future<AylaVoiceChannelSnapshot> getVoiceChannel(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/voice/channels/${Uri.encodeComponent(channelId)}/');
    final AylaVoiceChannelSnapshot? channel =
        AylaVoiceChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '频道详情响应结构非法');
    }
    return channel;
  }

  /// `DELETE /voice/channels/<id>/` —— 删除频道（仅 owner，否则 403）。
  static Future<void> deleteVoiceChannel(String channelId) async {
    await DioClient.instance.delete<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/',
    );
  }

  /// `POST /voice/channels/<id>/join/` —— 加入频道（成员落表，幂等）。
  ///
  /// 媒体走 WS 音频中继；本接口**只改成员事实**（web 原话：媒体凭据已随 LiveKit 退役移除）。
  /// 错误语义：503 = 语音服务未配置 / 404 = 频道不存在（调用方按 status 分支提示）。
  static Future<AylaVoiceJoinResult> joinVoiceChannel(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/voice/channels/${Uri.encodeComponent(channelId)}/join/');
    final AylaVoiceJoinResult? result = AylaVoiceJoinResult.fromJson(resp);
    if (result == null) {
      throw const ApiException(0, '加入频道响应结构非法');
    }
    return result;
  }

  /// `POST /voice/channels/<id>/leave/` —— 离开（幂等，重复离开返回同样结果）。
  ///
  /// ## 有意偏离（登记）
  /// web `api/voice.ts:99–108` 为「被取代的 join 的补偿」单开一条
  /// `auth:false + noRetry401 + 显式 Authorization` 的通道（避免用**后来的账号**刷新重试）。
  /// Flutter 侧 `DioClient` 的公开方法不暴露逐请求 auth 开关（M0 基座，跨批次改动需单独批准）
  /// ⇒ 由**页面层在调用前核对账号未变**承担同一保护（`AylaVoiceSession.leave`），
  /// 语义等价、影响面更小。若将来 M0 开放逐请求 auth 选项，可回归 web 原形。
  static Future<void> leaveVoiceChannel(String channelId) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/leave/',
    );
  }

  /// `POST /voice/channels/<id>/heartbeat/` —— presence 心跳；非成员 → 403。
  ///
  /// 403 = 已被移出（调用方应视为超时清理，本地重置）；404 = 房间已删除。
  static Future<void> heartbeatVoiceChannel(String channelId) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/heartbeat/',
    );
  }

  /// `POST /voice/channels/<id>/members/<uid>/action/` —— 房主操作（踢出/转让）。
  static Future<void> actionVoiceMember(
    String channelId,
    String userId,
    String action,
  ) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/members/'
      '${Uri.encodeComponent(userId)}/action/',
      body: <String, dynamic>{'action': action},
    );
  }

  /// `GET /voice/channels/<id>/members/` —— 可见成员游标页（web 面板用，limit 20）。
  static Future<AylaMediaCursorPage<AylaVoiceMemberDescriptor>>
      listVoiceChannelMembersPage(
    String channelId, {
    String? cursor,
    int limit = 20,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/members/',
      query: query,
    );
    final AylaMediaCursorPage<AylaVoiceMemberDescriptor>? page =
        AylaMediaCursorPage.parse<AylaVoiceMemberDescriptor>(
      resp,
      AylaVoiceMemberDescriptor.fromJson,
    );
    if (page == null) {
      throw const ApiException(0, '成员分页响应结构非法');
    }
    return page;
  }

  /// `GET /voice/channels/<id>/members/` —— **完整成员对账**（join 后铺底 / WS 重连后补偿）。
  ///
  /// web `api/voice.ts:119–137`：以 `user_id` 去重、循环读到 `has_more=false`；
  /// 上游账号在读取途中变化 ⇒ 抛 [AylaVoiceReconcileAborted]（web 抛 AbortError），
  /// 调用方**丢弃结果**而不是拿旧账号的对账去铺新账号的成员表。
  static Future<List<AylaVoiceMemberDescriptor>> listVoiceChannelMembers(
    String channelId, {
    int pageSize = 100,
    bool Function()? isCurrent,
  }) async {
    final Map<String, AylaVoiceMemberDescriptor> rows =
        <String, AylaVoiceMemberDescriptor>{};
    final Set<String> seenCursors = <String>{};
    String? cursor;
    while (true) {
      if (isCurrent != null && !isCurrent()) {
        throw const AylaVoiceReconcileAborted('成员对账所属账号已改变');
      }
      final AylaMediaCursorPage<AylaVoiceMemberDescriptor> page =
          await listVoiceChannelMembersPage(
        channelId,
        cursor: cursor,
        limit: pageSize,
      );
      if (isCurrent != null && !isCurrent()) {
        throw const AylaVoiceReconcileAborted('成员对账所属账号已改变');
      }
      for (final AylaVoiceMemberDescriptor member in page.results) {
        rows[member.userId] = member;
      }
      if (!page.hasMore) return rows.values.toList(growable: false);
      final String? next = page.nextCursor;
      if (next == null || seenCursors.contains(next) || page.results.isEmpty) {
        throw const ApiException(0, '成员对账分页响应缺少有效的继续位置，请重试');
      }
      seenCursors.add(next);
      cursor = next;
    }
  }

  /// `GET /voice/channels/<id>/messages/` —— 房内聊天历史游标页。
  static Future<AylaMediaCursorPage<AylaVoiceChatMessage>>
      listVoiceChatMessagesPage(
    String channelId, {
    String? cursor,
    String? beforeId,
    int limit = 50,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
      if (beforeId != null) 'before_id': beforeId,
    };
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/messages/',
      query: query,
    );
    final AylaMediaCursorPage<AylaVoiceChatMessage>? page =
        AylaMediaCursorPage.parse<AylaVoiceChatMessage>(
      resp,
      AylaVoiceChatMessage.fromJson,
    );
    if (page == null) {
      throw const ApiException(0, '房内聊天历史响应结构非法');
    }
    return page;
  }

  /// `POST /voice/channels/<id>/messages/` —— 房内聊天（可带图片；`content` 空时后端写「图片」）。
  static Future<AylaVoiceChatMessage> sendVoiceChatMessage(
    String channelId, {
    required String content,
    String? mediaId,
  }) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>(
      '/voice/channels/${Uri.encodeComponent(channelId)}/messages/',
      body: <String, dynamic>{'content': content, 'media_id': mediaId},
    );
    final AylaVoiceChatMessage? message = AylaVoiceChatMessage.fromJson(resp);
    if (message == null) {
      throw const ApiException(0, '房内聊天响应结构非法');
    }
    return message;
  }
}
