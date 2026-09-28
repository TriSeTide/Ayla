/// 桌游 API（web api/boardgame.ts 99 行的**页面所需子集**）。
///
/// - GET /boardgame/rooms/?limit=&cursor=&visibility=&friends=&status=&owner=&mine=
///   —— 游标分页目录（api/boardgame.ts:32–49）；
/// - GET /boardgame/rooms/[id]/ —— 详情（房内占位界面用，api/boardgame.ts:68–70）；
/// - POST /boardgame/rooms/[id]:join/ —— 加入（幂等，api/boardgame.ts:84–88）；
/// - POST /boardgame/rooms/[id]:leave/ —— 离开（仅成员，api/boardgame.ts:95–98）。
///
/// ⚠️ web 的 createGameRoom / deleteGameRoom 会 window.dispatchEvent 通知群桌游页
/// 刷新（api/boardgame.ts:60–64/77–81）—— 那属建房间批次（CreateFab 接线），本轮不带出。
library;

import '../models/game_room.dart' show AylaGameCardData, AylaGameRoom;
import '../models/visibility.dart' show AylaPostVisibility;
import '../net/dio_client.dart';
import 'directory_page.dart';

/// 桌游目录条目（卡投影 + 房内完整房间 + 「我的」过滤事实）。
class AylaDirectoryGameEntry {
  const AylaDirectoryGameEntry({
    required this.card,
    required this.room,
    this.ownerId = '',
    this.isOwner = false,
  });

  /// 卡面投影（大厅网格 AylaGameRoomCard 的入参）。
  final AylaGameCardData card;

  /// 完整房间（GameRoom）—— 房内占位界面（AylaGameRoomPlaceholder）要的是完整模型。
  final AylaGameRoom room;

  /// owner_id（web 的「我的」判据是 is_owner，这里两者都留）。
  final String ownerId;

  /// is_owner（GamesHubPage.tsx:76）。
  final bool isOwner;

  static AylaDirectoryGameEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaGameCardData? card = AylaGameCardData.fromJson(raw);
    final AylaGameRoom? room = AylaGameRoom.fromJson(raw);
    if (card == null || room == null) return null;
    return AylaDirectoryGameEntry(
      card: card,
      room: room,
      ownerId: raw['owner_id']?.toString() ?? '',
      isOwner: raw['is_owner'] == true,
    );
  }
}

class AylaBoardgameApi {
  const AylaBoardgameApi._();

  /// GET /boardgame/rooms/ —— 目录分页（DirectoryPage，条目为 GameRoom）。
  ///
  /// 过滤参数逐个对应 web GamesHubPage.tsx:49–55：
  /// visibility / friends / status(waiting|playing) / owner 由后端执行。
  static Future<AylaDirectoryPage<AylaDirectoryGameEntry>> listGameRoomsPage({
    int limit = 20,
    String? cursor,
    String? groupId,
    String? owner,
    bool friends = false,
    bool mine = false,
    AylaPostVisibility? visibility,
    String? status,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': '$limit'};
    if (cursor != null) query['cursor'] = cursor;
    if (groupId != null) query['group_id'] = groupId;
    if (owner != null) query['owner'] = owner;
    if (mine) query['mine'] = '1';
    if (friends) query['friends'] = '1';
    if (visibility != null) query['visibility'] = visibility.wire;
    if (status != null) query['status'] = status;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/boardgame/rooms/', query: query);
    return AylaDirectoryPage.fromJson<AylaDirectoryGameEntry>(
      resp,
      AylaDirectoryGameEntry.fromJson,
    );
  }

  /// GET /boardgame/rooms/[id]/ —— 房间详情（房内占位界面用）。
  ///
  /// 缺 id/name 视为非法 → ApiException（调用方按「房间不存在」处理）。
  static Future<AylaGameRoom> getGameRoom(int roomId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/boardgame/rooms/$roomId/');
    final AylaGameRoom? room = AylaGameRoom.fromJson(resp);
    if (room == null) throw const ApiException(0, '房间数据格式不合法');
    return room;
  }

  /// POST /boardgame/rooms/[id]:join/ —— 加入（幂等；已在局返回同一成员）。
  static Future<void> joinGameRoom(int roomId) async {
    await DioClient.instance
        .post<Map<String, dynamic>>('/boardgame/rooms/$roomId:join/');
  }

  /// POST /boardgame/rooms/[id]:leave/ —— 离开（仅成员）。
  static Future<void> leaveGameRoom(int roomId) async {
    await DioClient.instance
        .post<Map<String, dynamic>>('/boardgame/rooms/$roomId:leave/');
  }
}
