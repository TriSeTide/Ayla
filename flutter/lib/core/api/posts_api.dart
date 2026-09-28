/// 帖子域 API —— web `api/posts.ts`（109 行）的等价物。
///
/// ## 逐条对应
/// | 本方法 | web | 后端 |
/// |---|---|---|
/// | [listPosts] | `api/posts.ts:15–34` | `GET /posts/?scope=&cursor=&limit=&owner=&visibility=&friends=` |
/// | [createPost] | `37–46` | `POST /posts/` |
/// | [getPost] | `49–51` | `GET /posts/<id>/` |
/// | [updatePost] | `54–56` | `PATCH /posts/<id>/` |
/// | [deletePost] | `59–61` | `DELETE /posts/<id>/` |
/// | [listCommentsPage] | `69–73` | `GET /posts/<id>/comments/?limit=&cursor=` |
/// | [listComments] | `64–66` | 无分页旧形态（保留：评论列首屏以外的兼容路径） |
/// | [createComment] | `76–89` | `POST /posts/<id>/comments/` |
/// | [deleteComment] | `92–96` | `DELETE /posts/comments/<id>/` |
/// | [reportPostViews] | `104–108` | `POST /posts/views/`（幂等，浏览与已读同源） |
///
/// ## 口径
/// - `scope` 是「信息流 / 群内 / 我的」三态（`types.ts` 的 `PostScope`）；`feed` 时
///   **不带 scope 参数**（web `api/posts.ts:26`：`scope !== "feed"` 才 set）；
/// - `images` 传的是 **media_id 列表**（全量替换语义，web `updatePost` 注释 53 行）；
/// - 详情/评论的非法项一律跳过（`fromJson → null`），不造占位对象。
library;

import '../models/post.dart';
import '../net/dio_client.dart';
import 'directory_page.dart';

class AylaPostsApi {
  const AylaPostsApi._();

  /// `GET /posts/` —— 信息流游标分页（web `api/posts.ts:15–34`）。
  static Future<AylaDirectoryPage<AylaPost>> listPosts({
    String? scope,
    String? cursor,
    int? limit,
    String? owner,
    String? visibility,
    bool friends = false,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{};
    if (scope != null && scope.isNotEmpty && scope != 'feed') {
      query['scope'] = scope;
    }
    if (cursor != null) query['cursor'] = cursor;
    if (limit != null) query['limit'] = '$limit';
    if (owner != null) query['owner'] = owner;
    if (visibility != null) query['visibility'] = visibility;
    if (friends) query['friends'] = '1';
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/posts/', query: query);
    return AylaDirectoryPage.fromJson<AylaPost>(resp, AylaPost.fromJson);
  }

  /// `POST /posts/` —— 发帖（`images` = media_id 列表）。
  static Future<AylaPost?> createPost({
    String? title,
    required String body,
    String? group,
    String? visibility,
    List<String> images = const <String>[],
    List<String> allowedGroupIds = const <String>[],
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{'body': body};
    if (title != null) payload['title'] = title;
    if (group != null) payload['group'] = group;
    if (visibility != null) payload['visibility'] = visibility;
    if (images.isNotEmpty) payload['images'] = images;
    if (allowedGroupIds.isNotEmpty) {
      payload['allowed_group_ids'] = allowedGroupIds;
    }
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/posts/', body: payload);
    return AylaPost.fromJson(resp);
  }

  /// `GET /posts/<id>/` —— 详情。
  static Future<AylaPost?> getPost(int postId) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/posts/$postId/');
    return AylaPost.fromJson(resp);
  }

  /// `PATCH /posts/<id>/` —— 编辑（仅作者；`images` 全量替换）。
  static Future<AylaPost?> updatePost(
    int postId, {
    String? title,
    String? body,
    String? visibility,
    List<String>? allowedGroupIds,
    List<String>? images,
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{};
    if (title != null) payload['title'] = title;
    if (body != null) payload['body'] = body;
    if (visibility != null) payload['visibility'] = visibility;
    if (allowedGroupIds != null) payload['allowed_group_ids'] = allowedGroupIds;
    if (images != null) payload['images'] = images;
    final Map<String, dynamic> resp = await DioClient.instance
        .patch<Map<String, dynamic>>('/posts/$postId/', body: payload);
    return AylaPost.fromJson(resp);
  }

  /// `DELETE /posts/<id>/` —— 删除（仅作者）。
  static Future<void> deletePost(int postId) async {
    await DioClient.instance.delete<Map<String, dynamic>>('/posts/$postId/');
  }

  /// `GET /posts/<id>/comments/` —— 评论游标页（按 `created_at` 升序）。
  static Future<AylaDirectoryPage<AylaPostComment>> listCommentsPage(
    int postId, {
    int limit = 20,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': '$limit'};
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/posts/$postId/comments/', query: query);
    return AylaDirectoryPage.fromJson<AylaPostComment>(
      resp,
      AylaPostComment.fromJson,
    );
  }

  /// `POST /posts/<id>/comments/` —— 发评论（`reply_to` 须在本帖）。
  static Future<AylaPostComment?> createComment(
    int postId, {
    required String body,
    int? replyTo,
    String? mediaId,
    List<String> images = const <String>[],
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{'body': body};
    if (replyTo != null) payload['reply_to'] = replyTo;
    if (mediaId != null) payload['media_id'] = mediaId;
    if (images.isNotEmpty) payload['images'] = images;
    final Map<String, dynamic> resp = await DioClient.instance
        .post<Map<String, dynamic>>('/posts/$postId/comments/', body: payload);
    return AylaPostComment.fromJson(resp);
  }

  /// `DELETE /posts/comments/<id>/` —— 删评论（仅评论作者）。
  static Future<void> deleteComment(int commentId) async {
    await DioClient.instance
        .delete<Map<String, dynamic>>('/posts/comments/$commentId/');
  }

  /// `POST /posts/views/` —— 批量记录浏览（幂等）。返回 `{post_id: 最新 view_count}`。
  static Future<Map<String, int>> reportPostViews(
    List<int> postIds,
  ) async {
    if (postIds.isEmpty) return const <String, int>{};
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/posts/views/',
      body: <String, dynamic>{
        'post_ids': <String>[for (final int id in postIds) '$id'],
      },
    );
    final Object? updated = resp['updated'];
    if (updated is! Map) return const <String, int>{};
    return <String, int>{
      for (final MapEntry<Object?, Object?> e in updated.entries)
        if ((e.value as num?) != null) e.key.toString(): (e.value as num).toInt(),
    };
  }
}
