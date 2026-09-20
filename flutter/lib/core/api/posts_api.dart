/// 帖子 REST 封装（对齐 web `Ayla/web/src/api/posts.ts:15–34` 与后端 `apps/posts/`）。
///
/// `GET /posts/` 游标分页：`{results, next_cursor, has_more, total?}`
/// （created_at + id 降序，cursor 由后端编解码）。
/// 参数：`scope`（feed 默认不传 / mine / group:{id}）、`cursor`、`limit`、
/// `owner`（他人主页）、`visibility`（分类选项卡）、`friends=1`（只看好友发布）。
library;

import '../models/post.dart';
import '../net/dio_client.dart';

/// 帖子列表接口（单例静态方法，与 [MediaSigner] 同风格）。
class AylaPostsApi {
  AylaPostsApi._();

  /// 默认每页条数（web `PostsHubPage`：`limit: 20`）。
  static const int pageSize = 20;

  /// 拉一页帖子；`scope == 'feed'` 时不传（后端默认 feed，对齐 `posts.ts:26`）。
  static Future<AylaPostPage> listPosts({
    String? scope,
    String? cursor,
    int limit = pageSize,
    String? owner,
    String? visibility,
    bool friends = false,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{'limit': limit};
    if (scope != null && scope.isNotEmpty && scope != 'feed') {
      query['scope'] = scope;
    }
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    if (owner != null && owner.isNotEmpty) query['owner'] = owner;
    if (visibility != null && visibility.isNotEmpty) {
      query['visibility'] = visibility;
    }
    if (friends) query['friends'] = '1';
    final Map<String, dynamic> raw =
        await DioClient.instance.get<Map<String, dynamic>>('/posts/', query: query);
    return AylaPostPage.fromJson(raw);
  }

  /// 单帖详情（`GET /posts/{id}/`；WS `post.created` 补全用）。
  static Future<AylaPost?> getPost(int postId) async {
    final Map<String, dynamic> raw =
        await DioClient.instance.get<Map<String, dynamic>>('/posts/$postId/');
    return AylaPost.fromJson(raw);
  }
}
