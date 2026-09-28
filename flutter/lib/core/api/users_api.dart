/// 用户 / 好友 API（web `api/users.ts` + `api/chat.ts` 的相关子集）。
///
/// 第 1 批只带出 [AylaUsersApi.getUserDetail]（他人主页）与好友申请，
/// 以及 `openPrivateConversation`；搜索 / 好友列表等随各自页面批次带出。
library;

import '../models/user_public.dart';
import '../net/dio_client.dart';

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
  });

  final AylaUserPublic user;
  final AylaFriendRelation relation;

  /// 个性签名（`UserPublic.signature`）。
  ///
  /// ⚠️ 挂在**本类**而不是 [AylaUserPublic]：后者是「chat 域投影」（只承载聊天渲染与
  /// 在线判定需要的字段，见其文件头）⇒ 不为一个页面去扩它的字段面。
  final String? signature;

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
    );
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
}