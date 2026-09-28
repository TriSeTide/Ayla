/// 收藏 API（web `api/favorites.ts` 53 行 + `api/types.ts:1270–1319`）。
///
/// - GET /favorites/?type=&limit=&cursor= —— 游标分页的收藏列表（DirectoryPage，条目为 Favorite）；
/// - POST /favorites/status/ —— **有界批量**状态查询（单次上限 100 个 id）；
/// - POST /favorites/ —— 幂等收藏（201 新建 / 200 已存在）；
/// - DELETE /favorites/[id]/ —— 取消收藏。
///
/// 收藏条目 = `{id, user_id, target_type, target_id, target, created_at}`，
/// 其中 `target` 是**按类型不同的投影**（后端 `favorites/target_cards.py`）：
/// post / live / voice / game / message 五类 —— 解析后喂给已交付件
/// [AylaFavoriteResultData]（`widgets/base/directory_result_cards.dart:188`）。
///
/// ## 依赖方向（登记）
/// 本文件 import `widgets/base/directory_result_cards.dart` 与三域卡数据类：
/// 收藏条目的页面投影**就是**那些件的输入契约，重复定义会产生第二份
/// `AylaFavoriteTargetType` 枚举与第二份 `AylaFavoriteResultData`（认知零规则：
/// 类别只能有一个权威来源）。视觉件本身仍在 widgets 层，本层只做「响应 → 投影」。
library;

import '../net/dio_client.dart';
import '../../widgets/base/directory_result_cards.dart';
import '../../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import '../models/game_room.dart' show AylaGameCardData;
import '../models/chat_message.dart' show AylaChatMessage;
import '../models/post.dart' show AylaPost;
import 'directory_page.dart';

/// 收藏条目：已交付件的投影 + 跳转所需事实。
///
/// - [card] 与 web `FavoriteResultCard` 的入参一一对应；
/// - [targetId] 是 web `openTarget` 用的目标 id（`FavoritesPage.tsx:36–67`
///   按 `target_type` 跳 `/posts/{id}` / `/live/{id}` / `/voice/{id}` / `/games/{id}` /
///   `/chat/{conversation_id}?msg=&seq=&subgroup=`）——**不是** target 里的 `id`；
/// - [messageSenderNickname] 是消息卡 heading 的发送者名（web `target.sender_nickname`；
///   消息投影 `AylaChatMessage` 不承载昵称 ⇒ 由本层单独带出）。
class AylaFavoriteEntry {
  const AylaFavoriteEntry({
    required this.card,
    required this.targetId,
    this.createdAt,
    this.messageSenderNickname,
  });

  final AylaFavoriteResultData card;
  final String targetId;
  final String? createdAt;
  final String? messageSenderNickname;

  /// 解析一条收藏；缺 `id` / `target_type` 视为非法 → null。
  static AylaFavoriteEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? targetType = raw['target_type'];
    if (id == null || targetType == null) return null;
    final int? favoriteId = id is int ? id : int.tryParse(id.toString());
    if (favoriteId == null) return null;
    final AylaFavoriteTargetType? type =
        _targetTypeFromWire(targetType.toString());
    if (type == null) return null;
    final Map<String, dynamic>? target = raw['target'] is Map
        ? (raw['target'] as Map).cast<String, dynamic>()
        : null;
    return AylaFavoriteEntry(
      card: AylaFavoriteResultData(
        id: favoriteId,
        targetType: type,
        post: type == AylaFavoriteTargetType.post
            ? AylaPost.fromJson(target)
            : null,
        live: type == AylaFavoriteTargetType.live
            ? AylaLiveCardData.fromJson(target)
            : null,
        voice: type == AylaFavoriteTargetType.voice
            ? AylaVoiceCardData.fromJson(target)
            : null,
        game: type == AylaFavoriteTargetType.game
            ? AylaGameCardData.fromJson(target)
            : null,
        message: type == AylaFavoriteTargetType.message
            ? AylaChatMessage.fromJson(target)
            : null,
      ),
      targetId: raw['target_id']?.toString() ?? '',
      createdAt: raw['created_at']?.toString(),
      messageSenderNickname: target?['sender_nickname']?.toString(),
    );
  }
}

/// 后端 `target_type` 字面量 → 枚举；未知值 → null（不 fallback 成某个类别）。
AylaFavoriteTargetType? _targetTypeFromWire(String wire) => switch (wire) {
      'post' => AylaFavoriteTargetType.post,
      'live' => AylaFavoriteTargetType.live,
      'voice' => AylaFavoriteTargetType.voice,
      'game' => AylaFavoriteTargetType.game,
      'message' => AylaFavoriteTargetType.message,
      _ => null,
    };

/// `POST /favorites/status/` 的返回。
class AylaFavoriteStatuses {
  const AylaFavoriteStatuses({required this.targetType, required this.statuses});

  final String targetType;

  /// target_id → 收藏 id（null = 未收藏）。
  final Map<String, int?> statuses;
}

class AylaFavoritesApi {
  const AylaFavoritesApi._();

  /// GET /favorites/?type=&limit=&cursor= —— 收藏列表（游标分页）。
  ///
  /// `type` 为空 = 「全部」分类（不传该参数）。
  static Future<AylaDirectoryPage<AylaFavoriteEntry>> listFavoritesPage({
    String? type,
    int limit = 20,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': '$limit'};
    if (type != null) query['type'] = type;
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/favorites/', query: query);
    return AylaDirectoryPage.fromJson<AylaFavoriteEntry>(
      resp,
      AylaFavoriteEntry.fromJson,
    );
  }

  /// POST /favorites/status/ —— 有界批量状态查询（web 硬上限 100，`api/favorites.ts:24–30`）。
  static Future<AylaFavoriteStatuses> getFavoriteStatuses(
    String targetType,
    List<String> targetIds,
  ) async {
    if (targetIds.length > 100) {
      throw const ApiException(0, '一次最多查询 100 个收藏状态');
    }
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/favorites/status/',
      body: <String, dynamic>{
        'target_type': targetType,
        'target_ids': targetIds,
      },
    );
    final Map<String, dynamic> raw =
        (resp['statuses'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    return AylaFavoriteStatuses(
      targetType: resp['target_type']?.toString() ?? '',
      statuses: <String, int?>{
        for (final MapEntry<String, dynamic> entry in raw.entries)
          entry.key: (entry.value as num?)?.toInt(),
      },
    );
  }

  /// POST /favorites/ —— 收藏（幂等）；返回收藏 id。
  static Future<int> addFavorite(String targetType, String targetId) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/favorites/',
      body: <String, dynamic>{
        'target_type': targetType,
        'target_id': targetId,
      },
    );
    final int? id = (resp['id'] as num?)?.toInt();
    if (id == null) throw const ApiException(0, '收藏响应缺少 id');
    return id;
  }

  /// DELETE /favorites/[id]/ —— 取消收藏。
  static Future<void> removeFavorite(int favoriteId) async {
    await DioClient.instance
        .delete<Map<String, dynamic>>('/favorites/$favoriteId/');
  }
}
