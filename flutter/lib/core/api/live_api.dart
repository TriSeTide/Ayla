/// 直播目录 API（web api/live.ts 145 行的**目录子集**）。
///
/// 本轮（第二批三个 hub 页）只带出大厅需要的读接口：
/// - GET /live/channels/?limit=&cursor=&visibility=&friends=&status=&owner=&only_live=
///   —— 游标分页目录（api/live.ts:63–80）；
///
/// 其它（建/改/删、:start/:stop、/status/、弹幕、在看人数）随对应页面批次带出 ——
/// **不为没有消费者的能力提前开口子**（AGENTS.md §9）。
///
/// ## 目录条目为什么多一层
/// 卡面只消费 AylaLiveCardData 的字段（标题/封面/状态/人数/主播）；而「我的」分类的
/// **前端二次过滤**用的是 is_owner（LiveHubPage.tsx:71）—— 这个字段不在卡片
/// 投影里（web 的 LiveCardData 是 Partial，卡组件只读它要用的那几个）。故在 api 层
/// 保留一个 AylaDirectoryLiveEntry：卡投影 + 过滤事实，两者同源自同一份响应。
library;

import '../models/visibility.dart' show AylaPostVisibility;
import '../net/dio_client.dart';
import '../../widgets/live/live_hall.dart' show AylaLiveCardData;
import 'directory_page.dart';

/// 直播目录条目（卡投影 + 「我的」过滤事实 + 主页「新内容」事实）。
///
/// 多这一层的口径见文件头；[startedAt] / [allowedGroupIds] 沿用同一口径
/// （主页 `groupActivity.ts:175–184` 的「新开播」事件与白名单可见性都要它们，
/// 而卡投影 `AylaLiveCardData` 是 Partial、只承载渲染字段 ⇒ 不扩已验收的卡数据类）。
class AylaDirectoryLiveEntry {
  const AylaDirectoryLiveEntry({
    required this.card,
    this.ownerId = '',
    this.isOwner = false,
    this.startedAt,
    this.allowedGroupIds = const <String>[],
  });

  final AylaLiveCardData card;

  /// owner_id（web VoiceHubPage.tsx:83 的「我的」判据在语音侧用它；
  /// 直播侧 web 用 is_owner）。
  final String ownerId;

  /// is_owner（LiveHubPage.tsx:71）。
  final bool isOwner;

  /// `started_at`（`types.ts:1066`；null = 未开播/未知）——
  /// 「新开播」事件的**时间**（`groupActivity.ts:178`）。
  final String? startedAt;

  /// `allowed_group_ids`（`types.ts:1050`）—— 白名单可见性判据
  /// （`groupActivity.ts:70–76` 的 `visibleInGroup`）。
  final List<String> allowedGroupIds;

  static AylaDirectoryLiveEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaLiveCardData? card = AylaLiveCardData.fromJson(raw);
    if (card == null) return null;
    return AylaDirectoryLiveEntry(
      card: card,
      ownerId: raw['owner_id']?.toString() ?? '',
      isOwner: raw['is_owner'] == true,
      startedAt: raw['started_at'] as String?,
      allowedGroupIds: <String>[
        for (final Object? id
            in (raw['allowed_group_ids'] as List<Object?>? ?? const <Object?>[]))
          if (id != null) id.toString(),
      ],
    );
  }
}

class AylaLiveApi {
  const AylaLiveApi._();

  /// GET /live/channels/ —— 目录分页（DirectoryPage，条目为 LiveChannelDescriptor）。
  ///
  /// 过滤参数逐个对应 web LiveHubPage.tsx:46–52：
  /// visibility / friends / status(live|offline) / owner 由**后端执行**，
  /// 每个 tab 独立游标（web 的 filter 进 directory key）。
  static Future<AylaDirectoryPage<AylaDirectoryLiveEntry>>
      listLiveChannelsPage({
    int limit = 20,
    String? cursor,
    String? groupId,
    String? owner,
    bool friends = false,
    AylaPostVisibility? visibility,
    String? status,
    bool onlyLive = false,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': '$limit'};
    if (cursor != null) query['cursor'] = cursor;
    if (groupId != null) query['group_id'] = groupId;
    if (onlyLive) query['only_live'] = '1';
    if (owner != null) query['owner'] = owner;
    if (friends) query['friends'] = '1';
    if (visibility != null) query['visibility'] = visibility.wire;
    if (status != null) query['status'] = status;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/live/channels/', query: query);
    return AylaDirectoryPage.fromJson<AylaDirectoryLiveEntry>(
      resp,
      AylaDirectoryLiveEntry.fromJson,
    );
  }
}
