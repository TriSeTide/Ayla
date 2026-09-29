/// 直播目录 API（web api/live.ts 145 行的**目录子集**）。
///
/// 本轮（第二批三个 hub 页）只带出大厅需要的读接口：
/// - `GET /live/channels/`?limit=&cursor=&visibility=&friends=&status=&owner=&only_live=
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
import '../models/post.dart' show AylaMediaDescriptor;
import '../../widgets/live/live_channel_snapshot.dart';
import '../../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../../widgets/live/live_player.dart' show AylaLiveSrsStatus;
import 'directory_page.dart';
import 'media_page.dart';

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
    this.endedAt,
    this.createdAt,
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

  /// `ended_at`（`types.ts:1067`）—— 「曾播」档的排序事实（web `sortLiveChannels`）。
  ///
  /// 2026-09-28（房内页批次）纯增量：控制台侧栏要按 web `sortLiveChannels` 排序
  /// （在播 → 曾播 → 从未），而原条目只带 `startedAt` ⇒ 补两个后端已返回的字段
  /// （既有字段与解析一字未动）。
  final String? endedAt;

  /// `created_at`（`types.ts:1068`）—— 「从未开播」档的排序事实。
  final String? createdAt;

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
      startedAt: raw['started_at']?.toString(),
      endedAt: raw['ended_at']?.toString(),
      createdAt: raw['created_at']?.toString(),
      allowedGroupIds: <String>[
        for (final Object? id
            in (raw['allowed_group_ids'] as List<Object?>? ?? const <Object?>[]))
          if (id != null) id.toString(),
      ],
    );
  }
}

/// 弹幕行 —— `DanmakuItem`（`api/types.ts:1088–1100`）在 Flutter 侧的投影。
///
/// 为什么不是 `AylaDanmakuEntry` 本身：历史窗口要按 `created_at` 排序合并
/// （`useCursorHistory`），而展示投影 `AylaDanmakuEntry` 不带时间戳（它只服务渲染）。
/// 本类保留数据面字段；到展示投影的映射在页面层（`live_support.dart`），
/// 避免 api 层反向依赖 widgets 的渲染类型。
class AylaLiveDanmaku {
  const AylaLiveDanmaku({
    required this.id,
    required this.createdAt,
    this.senderUserId = '',
    this.senderNickname = '',
    this.senderAvatar = '',
    this.content = '',
    this.mediaId,
    this.media,
  });

  final String id;
  final String createdAt;
  final String senderUserId;
  final String senderNickname;
  final String senderAvatar;
  final String content;
  final String? mediaId;
  final AylaMediaDescriptor? media;

  /// 历史条目（GET `/danmaku/`；sender 键是 `user_id`）。
  static AylaLiveDanmaku? fromHistoryJson(Object? raw) =>
      _fromJson(raw, broadcast: false);

  /// WS 回帧（`DanmakuFrame`：**平铺**，sender 键是 `id`/`avatar`，见 `api/types.ts:1105–1117`）。
  static AylaLiveDanmaku? fromFrameJson(Object? raw) =>
      _fromJson(raw, broadcast: true);

  static AylaLiveDanmaku? _fromJson(Object? raw, {required bool broadcast}) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final Map<dynamic, dynamic>? sender =
        raw['sender'] is Map ? raw['sender'] as Map<dynamic, dynamic> : null;
    final Map<dynamic, dynamic>? media =
        raw['media'] is Map ? raw['media'] as Map<dynamic, dynamic> : null;
    // ⚠️ 不写成 `broadcast ? sender?['id'] : sender?['user_id']`：三元里的 `?[`
    // 会被解析成 null-aware 索引而报 non_bool_condition（实测踩过）。
    final Object? rawSenderId =
        sender == null ? null : (broadcast ? sender['id'] : sender['user_id']);
    return AylaLiveDanmaku(
      id: id.toString(),
      createdAt: raw['created_at']?.toString() ?? '',
      senderUserId: rawSenderId?.toString() ?? '',
      senderNickname: sender?['nickname']?.toString() ?? '',
      senderAvatar: sender?['avatar']?.toString() ?? '',
      content: raw['content']?.toString() ?? '',
      mediaId: raw['media_id']?.toString(),
      media: media == null ? null : AylaMediaDescriptor.fromJson(media),
    );
  }
}

/// 在看观众（`LiveViewerItem`，`api/types.ts:1128–1132`）。
class AylaLiveViewer {
  const AylaLiveViewer({
    required this.userId,
    this.nickname = '',
    this.avatar = '',
  });

  final String userId;
  final String nickname;
  final String avatar;

  static AylaLiveViewer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? userId = raw['user_id'];
    if (userId == null) return null;
    return AylaLiveViewer(
      userId: userId.toString(),
      nickname: raw['nickname']?.toString() ?? '',
      avatar: raw['avatar']?.toString() ?? '',
    );
  }
}

/// `GET /live/channels/<id>/status/` 的判定结果（`LiveStatusResult`，`api/types.ts:1078–1085`）。
class AylaLiveStatusResult {
  const AylaLiveStatusResult({
    required this.status,
    this.source = '',
    this.detail,
    this.optimistic,
  });

  /// SRS 实时判定（权威）。
  final AylaLiveSrsStatus status;

  /// `"srs"` / `"srs_unavailable"`。
  final String source;

  /// 细节（null = 无）。
  final String? detail;

  /// 应用侧乐观标记原样回显。
  final AylaLiveStatus? optimistic;

  static AylaLiveStatusResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaLiveSrsStatus? status = switch (raw['status']?.toString()) {
      'live' => AylaLiveSrsStatus.live,
      'idle' => AylaLiveSrsStatus.idle,
      'degraded' => AylaLiveSrsStatus.degraded,
      _ => null,
    };
    if (status == null) return null;
    return AylaLiveStatusResult(
      status: status,
      source: raw['source']?.toString() ?? '',
      detail: raw['detail']?.toString(),
      optimistic: AylaLiveStatus.parse(raw['optimistic']?.toString()),
    );
  }
}

/// `GET /live/channels/<id>/viewers/` 的响应（`LiveViewersResult`）。
class AylaLiveViewersResult {
  const AylaLiveViewersResult({
    required this.channelId,
    required this.count,
    this.hasMore = false,
    this.viewers = const <AylaLiveViewer>[],
  });

  final String channelId;
  final int count;
  final bool hasMore;
  final List<AylaLiveViewer> viewers;

  static AylaLiveViewersResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return AylaLiveViewersResult(
      channelId: raw['channel_id']?.toString() ?? '',
      count: (raw['count'] as num?)?.toInt() ?? 0,
      hasMore: raw['has_more'] == true,
      viewers: <AylaLiveViewer>[
        for (final Object? item
            in (raw['viewers'] as List<Object?>? ?? const <Object?>[]))
          if (AylaLiveViewer.fromJson(item) case final AylaLiveViewer v) v,
      ],
    );
  }
}

class AylaLiveApi {
  const AylaLiveApi._();

  /// `GET /live/channels/` —— 目录分页（DirectoryPage，条目为 LiveChannelDescriptor）。
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

  /// `GET /live/channels/<id>/` —— 频道详情（owner 可见 stream_key/rtmp_url，他人为 null）。
  static Future<AylaLiveChannelSnapshot> getLiveChannel(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/live/channels/${Uri.encodeComponent(channelId)}/');
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '直播间详情响应结构非法');
    }
    return channel;
  }

  /// `POST /live/channels/<id>:start/` —— 乐观开播（**不校验 SRS 真实流**；非 owner → 403）。
  ///
  /// ⚠️ action 路径是**冒号写法**（web `api/live.ts:6` 的契约要点）。
  static Future<AylaLiveChannelSnapshot> startLiveChannel(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/live/channels/${Uri.encodeComponent(channelId)}:start/');
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '开播响应结构非法');
    }
    return channel;
  }

  /// `POST /live/channels/<id>:stop/` —— 乐观下播；非 owner → 403。
  static Future<AylaLiveChannelSnapshot> stopLiveChannel(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/live/channels/${Uri.encodeComponent(channelId)}:stop/');
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '下播响应结构非法');
    }
    return channel;
  }

  /// `POST /live/channels/` —— 创建频道（创建者即 owner；201 回显 stream_key/rtmp_url，仅本次）。
  static Future<AylaLiveChannelSnapshot> createLiveChannel(
    String title, {
    String? group,
    String? description,
    String? cover,
    String? visibility,
    List<String>? allowedGroupIds,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{'title': title};
    if (group != null) body['group'] = group;
    if (description != null) body['description'] = description;
    if (cover != null) body['cover'] = cover;
    if (visibility != null) body['visibility'] = visibility;
    if (allowedGroupIds != null) body['allowed_group_ids'] = allowedGroupIds;
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/live/channels/', body: body);
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '创建直播间响应结构非法');
    }
    return channel;
  }

  /// `PATCH /live/channels/<id>/` —— owner 修改标题、介绍、封面、可见范围。
  static Future<AylaLiveChannelSnapshot> updateLiveChannel(
    String channelId, {
    String? title,
    String? description,
    String? cover,
    String? visibility,
    List<String>? allowedGroupIds,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (description != null) body['description'] = description;
    if (cover != null) body['cover'] = cover;
    if (visibility != null) body['visibility'] = visibility;
    if (allowedGroupIds != null) body['allowed_group_ids'] = allowedGroupIds;
    final Map<String, dynamic> resp = await DioClient.instance
        .patch<Map<String, dynamic>>(
      '/live/channels/${Uri.encodeComponent(channelId)}/',
      body: body,
    );
    final AylaLiveChannelSnapshot? channel =
        AylaLiveChannelSnapshot.fromJson(resp);
    if (channel == null) {
      throw const ApiException(0, '直播间资料保存响应结构非法');
    }
    return channel;
  }

  /// `DELETE /live/channels/<id>/` —— 删除频道；非 owner → 403；直播中（乐观 live）→ 400。
  static Future<void> deleteLiveChannel(String channelId) async {
    await DioClient.instance.delete<Map<String, dynamic>>(
      '/live/channels/${Uri.encodeComponent(channelId)}/',
    );
  }

  /// `GET /live/channels/<id>/status/` —— SRS 实时判定（**权威**；degraded = SRS 不可用）。
  static Future<AylaLiveStatusResult> getLiveChannelStatus(String channelId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/live/channels/${Uri.encodeComponent(channelId)}/status/');
    final AylaLiveStatusResult? result = AylaLiveStatusResult.fromJson(resp);
    if (result == null) {
      throw const ApiException(0, '直播状态响应结构非法');
    }
    return result;
  }

  /// `GET /live/channels/<id>/viewers/` —— 当前在看直播的人（运行事实）。
  ///
  /// ⚠️ presence 存储不可用 → **503**（`viewer_presence_unavailable`）——
  /// **读不到 ≠ 没人在看**，调用方必须区分（不写 0）。
  static Future<AylaLiveViewersResult> getLiveChannelViewers(
    String channelId,
  ) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/live/channels/${Uri.encodeComponent(channelId)}/viewers/');
    final AylaLiveViewersResult? result =
        AylaLiveViewersResult.fromJson(resp);
    if (result == null) {
      throw const ApiException(0, '在看人数响应结构非法');
    }
    return result;
  }

  /// `POST /live/channels/<id>/danmaku/` —— 发弹幕；空/超长（>200）→ 400。
  static Future<AylaLiveDanmaku> sendDanmaku(
    String channelId, {
    required String content,
    String? mediaId,
  }) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>(
      '/live/channels/${Uri.encodeComponent(channelId)}/danmaku/',
      body: <String, dynamic>{'content': content, 'media_id': mediaId},
    );
    final AylaLiveDanmaku? item = AylaLiveDanmaku.fromHistoryJson(resp);
    if (item == null) {
      throw const ApiException(0, '弹幕发送响应结构非法');
    }
    return item;
  }

  /// `GET /live/channels/<id>/danmaku/` —— 历史游标页（升序；`useCursorHistory` 的数据源）。
  static Future<AylaMediaCursorPage<AylaLiveDanmaku>> listDanmakuPage(
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
      '/live/channels/${Uri.encodeComponent(channelId)}/danmaku/',
      query: query,
    );
    final AylaMediaCursorPage<AylaLiveDanmaku>? page =
        AylaMediaCursorPage.parse<AylaLiveDanmaku>(
      resp,
      AylaLiveDanmaku.fromHistoryJson,
    );
    if (page == null) {
      throw const ApiException(0, '弹幕历史响应结构非法');
    }
    return page;
  }
}
