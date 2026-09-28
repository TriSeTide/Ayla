/// 语音目录 API（web api/voice.ts 219 行的**目录子集**）。
///
/// 本轮（第二批三个 hub 页）只带出大厅需要的读接口：
/// - GET /voice/channels/?limit=&cursor=&visibility=&friends=&occupied=&owner=
///   —— 游标分页目录（api/voice.ts:38–54），响应带 total_member_count
///   （侧栏「X 房间在线 · Y 人在聊」的第二个数字，directory.ts:7）；
///
/// join / leave / heartbeat / members / messages / 爱莉 voice-calls 等随房内页批次带出。
library;

import '../models/visibility.dart' show AylaPostVisibility;
import '../net/dio_client.dart';
import '../../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import 'directory_page.dart';

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

class AylaVoiceApi {
  const AylaVoiceApi._();

  /// GET /voice/channels/ —— 目录分页（DirectoryPage，条目为 VoiceChannelDescriptor）。
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
}
