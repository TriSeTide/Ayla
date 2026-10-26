/// 用户 / 好友 API（web `api/users.ts` + `api/chat.ts` 的相关子集）。
///
/// 第 1 批只带出 [AylaUsersApi.getUserDetail]（他人主页）与好友申请，
/// 以及 `openPrivateConversation`；搜索 / 好友列表等随各自页面批次带出。
library;

import '../models/social_requests.dart' show AylaFriendRequest;
import '../models/user_public.dart';
import '../net/dio_client.dart';
import 'directory_page.dart';

/// 好友关系（web `api/types.ts:28` 的 `relation`）。
enum AylaFriendRelation {
  /// 自己（路由层会重定向 /profile）。
  self,

  /// 已互为好友。
  friend,

  /// 我已发出申请、待对方处理。
  pendingSent,

  /// 对方申请我（可去消息中心处理）。
  pendingReceived,

  /// 无关系。
  none;

  /// 解析后端字符串；**未识别的值回落 [none]**（后端新增枚举值时按「无关系」处理，
  /// 不做语义猜测）。
  static AylaFriendRelation fromJson(Object? raw) {
    return switch (raw?.toString()) {
      'self' => AylaFriendRelation.self,
      'friend' => AylaFriendRelation.friend,
      'pending_sent' => AylaFriendRelation.pendingSent,
      'pending_received' => AylaFriendRelation.pendingReceived,
      _ => AylaFriendRelation.none,
    };
  }
}

/// `GET /users/{id}/` 的返回：公开资料 + 与我的好友关系 + 展示内容开关。
class AylaUserDetail {
  const AylaUserDetail({
    required this.user,
    required this.relation,
    required this.showContent,
    this.signature,
    this.liveRoomId,
    this.voiceRoomId,
  });

  final AylaUserPublic user;
  final AylaFriendRelation relation;

  /// 个性签名（`UserPublic.signature`）。
  ///
  /// ⚠️ 挂在**本类**而不是 [AylaUserPublic]：后者是「chat 域投影」（只承载聊天渲染与
  /// 在线判定需要的字段，见其文件头）⇒ 不为一个页面去扩它的字段面。
  final String? signature;

  /// `UserPublic.live_room_id`（`types.ts:26`）——正在直播的频道 id（null = 没在播）。
  ///
  /// ⚠️ 与 [signature] 同源理由：**不**挂到 [AylaUserPublic] 上。个人主页内容分区用它拉
  /// 直播间详情（`pages/profile_content_support.dart` 的 `owner.live_room_id` 口径，tsx:73）。
  final String? liveRoomId;

  /// `UserPublic.voice_room_id`（`types.ts:24`）——正在语音的房间 id（null = 不在语音）。
  final String? voiceRoomId;

  /// `show_content`（对方开启「向他人展示内容」才渲染他的内容分区）。
  final bool showContent;

  /// 解析；缺 `id` 视为非法 → null（与 [AylaUserPublic.fromJson] 同口径）。
  static AylaUserDetail? fromJson(Map<String, dynamic> json) {
    final AylaUserPublic? user = AylaUserPublic.fromJson(json);
    if (user == null) return null;
    return AylaUserDetail(
      user: user,
      relation: AylaFriendRelation.fromJson(json['relation']),
      showContent: json['show_content'] == true,
      signature: json['signature']?.toString(),
      // 数字 id → 字符串（同 `AuthUser` 与 `AylaUserPublic.id` 的口径；缺失即缺失）。
      liveRoomId: json['live_room_id']?.toString(),
      voiceRoomId: json['voice_room_id']?.toString(),
    );
  }
}

/// 用户公开资料的**懒拉缓存**（web `api/users.ts:25–66` 的 `ensureUser` 等价物）。
///
/// ## 为什么需要它（2026-10-26，用户实报「直播标题栏完全没有头像图片」）
/// web 的 `LiveHostAvatar.tsx:24–48` 只拿到 `ownerId` + `owner_nickname`，
/// **头像 URL 靠 `ensureUser(ownerId)` 懒拉**（频道描述符里根本没有 `owner_avatar`）。
/// Flutter 侧此前没有这个能力 ⇒ `AylaLiveHostAvatar` 从来收不到 `avatarUrl`
/// ⇒ 主播头像**永远是首字光环**。
///
/// 与 web 逐条对齐：
/// - 命中缓存同步返回（web `getCachedUser`，渲染层无闪烁）；
/// - 并发去重：同一 id 只发一次请求（web `pending` Map）；
/// - 失败返回 null **不抛错**（渲染层回退首字符，web `.catch(() => null)`）。
class AylaUserDirectory {
  AylaUserDirectory._();

  static final Map<String, AylaUserPublic> _cache = <String, AylaUserPublic>{};
  static final Map<String, Future<AylaUserPublic?>> _pending =
      <String, Future<AylaUserPublic?>>{};

  /// 已缓存则同步返回（无则 null）。
  static AylaUserPublic? cached(String userId) => _cache[userId];

  /// 把已有资料写入缓存（来自会话成员等现成数据源，避免重复请求）。
  static void put(AylaUserPublic user) => _cache[user.id] = user;

  /// 按 id 懒拉公开资料并缓存；失败/未命中返回 null（**不抛错**）。
  static Future<AylaUserPublic?> ensure(String userId) {
    if (userId.isEmpty) return Future<AylaUserPublic?>.value();
    final AylaUserPublic? hit = _cache[userId];
    if (hit != null) return Future<AylaUserPublic?>.value(hit);
    final Future<AylaUserPublic?>? inFlight = _pending[userId];
    if (inFlight != null) return inFlight;
    final Future<AylaUserPublic?> task =
        AylaUsersApi.getUserDetail(userId).then<AylaUserPublic?>
      ((AylaUserDetail detail) {
        _cache[detail.user.id] = detail.user;
        return detail.user;
      }).catchError((Object _) {
        // 懒拉失败静默（web `ensureUser` 的 `.catch(() => null)`）。
        return null;
      }).whenComplete(() {
        _pending.remove(userId);
      });
    _pending[userId] = task;
    return task;
  }

  /// 测试用：清空缓存（web `_clearUserCache`）。
  static void clearCache() {
    _cache.clear();
    _pending.clear();
  }
}

class AylaUsersApi {
  const AylaUsersApi._();

  /// `GET /users/{id}/` —— 他人主页：公开资料 + relation（web `api/users.ts:34–37`）。
  static Future<AylaUserDetail> getUserDetail(String userId) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.get<Map<String, dynamic>>(
      '/users/${Uri.encodeComponent(userId)}/',
    );
    final AylaUserDetail? detail = AylaUserDetail.fromJson(resp);
    if (detail == null) {
      throw const ApiException(0, '用户资料格式不合法');
    }
    return detail;
  }

  /// POST /friends/requests/ —— 发起好友申请（web `api/users.ts:94–99`）。
  static Future<void> createFriendRequest({required String toUserId}) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/friends/requests/',
      body: <String, String>{'to_user_id': toUserId},
    );
  }

  /// POST /chat/conversations/private/ —— 打开（或新建）与某用户的私聊
  /// （web `api/chat.ts:59–64`），返回会话 id。
  static Future<String> openPrivateConversation(String userId) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/private/',
      body: <String, String>{'user_id': userId},
    );
    return resp['id']?.toString() ?? '';
  }

  /// `GET /users/search/?pagination=cursor&limit=&q=&cursor=` —— 用户搜索分页
  /// （web `api/users.ts:14–16` 的 `searchUsersPage`；消费点 = 建群弹窗的成员搜索，
  /// `GroupCreateDialog.tsx:29` 的 `useSocialPage("users", { q })`）。
  ///
  /// 响应是 `SocialPage<UserPublic>` ⇒ 复用 [AylaDirectoryPage] 的游标页契约。
  static Future<AylaDirectoryPage<AylaUserPublic>> searchUsersPage(
    String q, {
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
      'q': q,
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/users/search/', query: query);
    return AylaDirectoryPage.fromJson<AylaUserPublic>(
      resp,
      AylaUserPublic.fromJson,
    );
  }

  /// GET /friends/?pagination=cursor&limit= —— 好友列表第一页
  /// （web `api/users.ts:77–79` 的 `listFriendsPage`；`SocialPage<Friendship>`）。
  ///
  /// 只服务于三个 hub 页「好友」分类的前端二次过滤（web 也只取第一页，
  /// `stores/social.ts:129` 的 `limit: 30`）⇒ 只返回 `Friendship.user`。
  /// 失败向上抛（调用方 `hub_support.aylaHubFriendIds` 兜底为空集合）。
  static Future<List<AylaUserPublic>> listFriendsPage({
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/friends/', query: query);
    return <AylaUserPublic>[
      for (final Object? item
          in (resp['results'] as List<Object?>? ?? const <Object?>[]))
        if (item is Map && AylaUserPublic.fromJson(item['user']) != null)
          AylaUserPublic.fromJson(item['user'])!,
    ];
  }

  /// GET /friends/?pagination=cursor&limit=&cursor= —— 好友游标页
  /// （web `api/users.ts:77–79` 的 `listFriendsPage`；`SocialPage<Friendship>`）。
  ///
  /// ⚠️ 会话列表里的好友行需要 `items` / `total` / `hasMore` / `loadMore` 全套投影
  /// ⇒ 本批（消息域）另立游标页版；既有的 [listFriendsPage]（hub 页二次过滤用）保持
  /// 「只取第一页的 user 集合」语义不变。
  static Future<AylaDirectoryPage<AylaUserPublic>> listFriendsPageOf({
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/friends/', query: query);
    return AylaDirectoryPage.fromJson<AylaUserPublic>(
      resp,
      (Object? raw) =>
          raw is Map<String, dynamic> ? AylaUserPublic.fromJson(raw['user']) : null,
    );
  }

  /// `GET /friends/requests/?pagination=cursor&limit=&direction=received&status=pending`
  /// —— 待我处理的好友申请（web `stores/social.ts:136`）。
  static Future<AylaDirectoryPage<AylaFriendRequest>>
      listFriendRequestsPage({
    int limit = 30,
    String? cursor,
    String direction = 'received',
    String status = 'pending',
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
      'direction': direction,
      'status': status,
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/friends/requests/', query: query);
    return AylaDirectoryPage.fromJson<AylaFriendRequest>(
      resp,
      (Object? raw) =>
          raw is Map<String, dynamic> ? AylaFriendRequest.fromJson(raw) : null,
    );
  }

  /// `POST /friends/requests/<id>/action/` —— 同意/拒绝好友申请（web `api/users.ts:101–110`）。
  static Future<void> actionFriendRequest(String requestId, bool accept) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/friends/requests/${Uri.encodeComponent(requestId)}/action/',
      body: <String, dynamic>{'action': accept ? 'accept' : 'reject'},
    );
  }

  /// `DELETE /friends/<user_id>/` —— 解除好友（web `api/users.ts:112–117`）。
  static Future<void> deleteFriend(String userId) async {
    await DioClient.instance.delete<void>(
      '/friends/${Uri.encodeComponent(userId)}/',
    );
  }
}
