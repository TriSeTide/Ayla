/// 帖子领域模型 —— 对齐 web `Ayla/web/src/api/types.ts`（逐字段同源）。
///
/// 事实源：
/// - `types.ts:8–33` UserPublic（只取帖子/评论卡实际用到的字段）
/// - `types.ts:186–205` MediaKind / MediaDescriptor
/// - `types.ts:1214–1268` PostImage / Post / PostComment / PostListPage / PostScope
///
/// 纪律：**JSON 键名与后端一致（snake_case）**；字段缺失就是缺失（null），
/// 不猜测、不造默认值（认知零规则：不得把"未知"伪装成某个具体值）。
library;

import 'media_kind.dart';

// 媒体种类定义在 `media_kind.dart`（2026-09-20 抽出，供 core/media 复用）；
// 这里 re-export，保持既有 `import '.../post.dart'` 调用点不变。
export 'media_kind.dart';

/// 帖子可见性（`types.ts:1227`：public / friends / group）。
///
/// 注意：**group 是独立维度**（白名单 allowed_groups），与 public/friends 可叠加；
/// 后端单值字段只是准入映射，标签由 [aylaVisibilityLabels] 生成。
enum AylaPostVisibility {
  public,
  friends,
  group;

  static AylaPostVisibility? parse(String? raw) => switch (raw) {
        'public' => AylaPostVisibility.public,
        'friends' => AylaPostVisibility.friends,
        'group' => AylaPostVisibility.group,
        _ => null,
      };

  /// 后端字段值。
  String get wire => name;
}

/// 媒体描述符（`MediaDescriptor`）。
class AylaMediaDescriptor {
  const AylaMediaDescriptor({
    required this.mediaId,
    this.kind,
    this.mimeType,
    this.size,
    this.status,
    this.width,
    this.height,
    this.duration,
    this.thumbnail,
    this.waveform,
    this.createdAt,
  });

  /// 媒体 id（字符串）。
  final String mediaId;

  /// 种类（未知 = null）。
  final AylaMediaKind? kind;

  final String? mimeType;
  final int? size;
  final String? status;
  final int? width;
  final int? height;

  /// 秒（voice）。
  final double? duration;

  /// 缩略图相对路径（`/api/v1/media/{id}/thumbnail`；无则 null）。
  final String? thumbnail;

  /// 波形相对路径（voice；无则 null）。
  final String? waveform;

  final String? createdAt;

  static AylaMediaDescriptor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['media_id'];
    if (id is! String || id.isEmpty) return null;
    return AylaMediaDescriptor(
      mediaId: id,
      kind: AylaMediaKind.parse(raw['kind'] as String?),
      mimeType: raw['mime_type'] as String?,
      size: (raw['size'] as num?)?.toInt(),
      status: raw['status'] as String?,
      width: (raw['width'] as num?)?.toInt(),
      height: (raw['height'] as num?)?.toInt(),
      duration: (raw['duration'] as num?)?.toDouble(),
      thumbnail: raw['thumbnail'] as String?,
      waveform: raw['waveform'] as String?,
      createdAt: raw['created_at'] as String?,
    );
  }
}

/// 帖子作者（UserPublic 中帖子卡用到的子集 + presence 运行事实）。
class AylaPostAuthor {
  const AylaPostAuthor({
    required this.id,
    this.username,
    this.nickname,
    this.avatar,
    this.status,
    this.online = false,
    this.displayStatus,
  });

  final String id;
  final String? username;
  final String? nickname;

  /// 头像相对路径（可能指向媒体 content → 必须走签名链路）。
  final String? avatar;

  /// `auto / away / dnd / invisible`。
  final String? status;

  /// 实时在线（Redis presence；隐身对外视为离线）——运行事实，由页面注入。
  final bool online;

  /// 后端权威展示文案（auto→在线/离线、dnd→勿扰…）。
  final String? displayStatus;

  /// 展示名：nickname 优先，其次 username，最后 null（不造"未知用户"）。
  String? get displayName {
    final String n = (nickname ?? '').trim();
    if (n.isNotEmpty) return n;
    final String u = (username ?? '').trim();
    if (u.isNotEmpty) return u;
    return null;
  }

  static AylaPostAuthor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return AylaPostAuthor(
      id: id,
      username: raw['username'] as String?,
      nickname: raw['nickname'] as String?,
      avatar: raw['avatar'] as String?,
      status: raw['status'] as String?,
      online: raw['online'] == true,
      displayStatus: raw['display_status'] as String?,
    );
  }
}

/// 帖子图片（`PostImage`：media 可能为 null——不伪造）。
class AylaPostImage {
  const AylaPostImage({required this.id, this.media, this.order});

  final int id;
  final AylaMediaDescriptor? media;
  final int? order;

  static AylaPostImage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! num) return null;
    return AylaPostImage(
      id: id.toInt(),
      media: AylaMediaDescriptor.fromJson(raw['media']),
      order: (raw['order'] as num?)?.toInt(),
    );
  }
}

/// 帖子（`Post`）。
class AylaPost {
  const AylaPost({
    required this.id,
    this.author,
    this.authorId,
    this.authorNickname,
    this.title = '',
    this.body = '',
    this.visibility,
    this.groupId,
    this.groupName,
    this.allowedGroupIds = const <String>[],
    this.allowedGroupNames = const <String>[],
    this.images = const <AylaPostImage>[],
    this.commentCount,
    this.isAuthor = false,
    this.viewCount,
    this.isViewed = false,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final AylaPostAuthor? author;
  final String? authorId;

  /// 旧摘要里的昵称回退字段（web `PostCardData.author_nickname`）。
  final String? authorNickname;

  final String title;
  final String body;
  final AylaPostVisibility? visibility;

  /// 归属群 id（**来源标记，不承载可见性**）。
  final String? groupId;

  /// 归属群名（旧数据标签回退用）。
  final String? groupName;

  final List<String> allowedGroupIds;

  /// 白名单群名（标签展示来源）。
  final List<String> allowedGroupNames;

  final List<AylaPostImage> images;

  /// 评论数（null = 后端未给，**不写 0**）。
  final int? commentCount;

  /// 当前用户是否作者（决定编辑/删除入口）。
  final bool isAuthor;

  /// 浏览量（null = 未给）。
  final int? viewCount;

  final bool isViewed;
  final String? createdAt;
  final String? updatedAt;

  static AylaPost? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! num) return null;
    return AylaPost(
      id: id.toInt(),
      author: AylaPostAuthor.fromJson(raw['author']),
      authorId: raw['author_id'] as String?,
      authorNickname: raw['author_nickname'] as String?,
      title: (raw['title'] as String?) ?? '',
      body: (raw['body'] as String?) ?? '',
      visibility: AylaPostVisibility.parse(raw['visibility'] as String?),
      groupId: raw['group'] as String?,
      groupName: raw['group_name'] as String?,
      allowedGroupIds: _stringList(raw['allowed_group_ids']),
      allowedGroupNames: _stringList(raw['allowed_group_names']),
      images: <AylaPostImage>[
        for (final Object? item in (raw['images'] as List<Object?>? ?? const <Object?>[]))
          if (AylaPostImage.fromJson(item) case final AylaPostImage img) img,
      ],
      commentCount: (raw['comment_count'] as num?)?.toInt(),
      isAuthor: raw['is_author'] == true,
      viewCount: (raw['view_count'] as num?)?.toInt(),
      isViewed: raw['is_viewed'] == true,
      createdAt: raw['created_at'] as String?,
      updatedAt: raw['updated_at'] as String?,
    );
  }
}

/// 评论（`PostComment`：images[] 图文同发；media_id/media 为旧单图兼容）。
class AylaPostComment {
  const AylaPostComment({
    required this.id,
    this.postId,
    this.author,
    this.authorId,
    this.body = '',
    this.mediaId,
    this.media,
    this.images = const <AylaMediaDescriptor>[],
    this.replyTo,
    this.isAuthor = false,
    this.createdAt,
  });

  final int id;
  final String? postId;
  final AylaPostAuthor? author;
  final String? authorId;
  final String body;
  final String? mediaId;
  final AylaMediaDescriptor? media;
  final List<AylaMediaDescriptor> images;

  /// 被回复评论 id（字符串；不在当前列表时 UI 显示占位提示）。
  final String? replyTo;

  /// 当前用户是否该评论作者（决定删除入口）。
  final bool isAuthor;
  final String? createdAt;

  /// 该评论的全部图片 descriptor（images[] 优先，旧 media 单图兼容）——
  /// 对应 web `CommentList.tsx:104–109`。
  List<AylaMediaDescriptor> get allImages {
    if (images.isNotEmpty) return images;
    final AylaMediaDescriptor? single = media;
    return single == null
        ? const <AylaMediaDescriptor>[]
        : <AylaMediaDescriptor>[single];
  }

  static AylaPostComment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! num) return null;
    final Object? replyTo = raw['reply_to'];
    final Object? postId = raw['post_id'];
    return AylaPostComment(
      id: id.toInt(),
      postId: postId?.toString(),
      author: AylaPostAuthor.fromJson(raw['author']),
      authorId: raw['author_id'] as String?,
      body: (raw['body'] as String?) ?? '',
      mediaId: raw['media_id'] as String?,
      media: AylaMediaDescriptor.fromJson(raw['media']),
      images: <AylaMediaDescriptor>[
        for (final Object? item in (raw['images'] as List<Object?>? ?? const <Object?>[]))
          if (AylaMediaDescriptor.fromJson(item) case final AylaMediaDescriptor m) m,
      ],
      replyTo: replyTo?.toString(),
      isAuthor: raw['is_author'] == true,
      createdAt: raw['created_at'] as String?,
    );
  }
}

/// 游标分页（`PostListPage`）。
class AylaPostPage {
  const AylaPostPage({
    this.results = const <AylaPost>[],
    this.nextCursor,
    this.hasMore = false,
    this.total,
  });

  final List<AylaPost> results;
  final String? nextCursor;
  final bool hasMore;
  final int? total;

  static AylaPostPage fromJson(Object? raw) {
    if (raw is! Map) return const AylaPostPage();
    return AylaPostPage(
      results: <AylaPost>[
        for (final Object? item in (raw['results'] as List<Object?>? ?? const <Object?>[]))
          if (AylaPost.fromJson(item) case final AylaPost p) p,
      ],
      nextCursor: raw['next_cursor'] as String?,
      hasMore: raw['has_more'] == true,
      total: (raw['total'] as num?)?.toInt(),
    );
  }
}

/// 可见性标签（web `utils/visibility.ts getVisibilityLabels` 逐条同源）。
///
/// - public → ["公开"]；friends → ["好友"]（二者互斥，最多一个）；
/// - `allowedGroupNames` → 白名单群名（**可与公开/好友叠加**：「公开+群」）；
/// - group 可见且无白名单名 → 回退 `groupName`（旧数据兼容）；
/// - 一条都生不出来时按 visibility 兜底（friends→好友 / public→公开 / 否则群可见）。
List<String> aylaVisibilityLabels({
  AylaPostVisibility? visibility,
  List<String> allowedGroupNames = const <String>[],
  String? groupName,
}) {
  final List<String> labels = <String>[];
  if (visibility == AylaPostVisibility.public) {
    labels.add('公开');
  } else if (visibility == AylaPostVisibility.friends) {
    labels.add('好友');
  }
  if (allowedGroupNames.isNotEmpty) {
    labels.addAll(allowedGroupNames);
  } else if (visibility == AylaPostVisibility.group &&
      (groupName ?? '').isNotEmpty) {
    labels.add(groupName!);
  }
  if (labels.isEmpty) {
    if (visibility == AylaPostVisibility.friends) return <String>['好友'];
    if (visibility == AylaPostVisibility.public) return <String>['公开'];
    return <String>['群可见'];
  }
  return labels;
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if (item is String && item.isNotEmpty) item,
  ];
}

/// 待发布媒体草稿（web `PostMediaDraft`；选图/上传完成后由页面交给编辑器）。
class AylaPostMediaDraft {
  const AylaPostMediaDraft({
    required this.mediaId,
    required this.descriptor,
    this.localPath,
    this.uploadId,
  });

  /// 媒体 id（提交时随帖子一起发）。
  final String mediaId;

  /// 媒体描述符（kind/thumbnail 决定预览形态）。
  final AylaMediaDescriptor descriptor;

  /// 本地文件路径（图片即时预览；null = 无本地来源）。
  final String? localPath;

  /// 上传会话 id（移除时页面据此清理对象存储）。
  final String? uploadId;
}

/// 一次「选媒体 + 上传」的结果（失败数量交回编辑器展示与重试）。
class AylaMediaPickResult {
  const AylaMediaPickResult({
    this.drafts = const <AylaPostMediaDraft>[],
    this.failed = 0,
    this.overLimit = 0,
  });

  /// 本次成功上传的草稿。
  final List<AylaPostMediaDraft> drafts;

  /// 上传失败数量（web `failedFiles.length`）。
  final int failed;

  /// 超出 9 个上限被丢弃的数量（web：`最多添加 9 个媒体` 提示）。
  final int overLimit;
}

/// 发帖草稿（提交给页面的数据，字段对齐后端 `POST /posts/` 契约）。
class AylaPostDraft {
  const AylaPostDraft({
    required this.title,
    required this.body,
    this.groupId,
    required this.visibility,
    this.allowedGroupIds = const <String>[],
    this.mediaIds = const <String>[],
  });

  /// 标题（web 必填）。
  final String title;

  /// 正文（web 必填）。
  final String body;

  /// 归属群 id（一级 tab 为 null）。
  final String? groupId;

  /// 后端单值可见性（多选 → 单值映射见编辑器 `_backendVisibility`）。
  final AylaPostVisibility visibility;

  /// 群白名单（独立维度，可与 public/friends 叠加）。
  final List<String> allowedGroupIds;

  /// 图片/视频 media_id 列表（顺序即展示顺序）。
  final List<String> mediaIds;
}
