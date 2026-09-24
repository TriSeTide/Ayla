/// 聊天消息模型（`Ayla/web/src/api/types.ts` 的 Dart 对应）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMessageType] | `types.ts:138–139` MessageType |
/// | [AylaMessageStatus] | `types.ts:140` MessageStatus |
/// | [AylaMediaSegment] | `types.ts:207–229` MediaSegment（判别联合） |
/// | [AylaLocalMediaPreview] | `types.ts:235–246` LocalMediaPreview |
/// | [AylaChatMessage] | `types.ts:247–286` ChatMessage |
/// | [AylaChatMessage.fromJson] | 后端 MessageSerializer 字段（snake_case） |
///
/// 纪律：JSON 键名与后端一致（snake_case）；字段缺失就是缺失（null），
/// 不猜测、不造默认值（同 `share_payload.dart` / `post.dart`）。
///
/// ⚠️ [AylaMediaDescriptor] 目前从 `post.dart` 复用（它与 `AylaMediaKind` 同源，
/// 由 `media_kind.dart` 抽出时保留了 `post.dart` 的 re-export 口径）。chat 域继续
/// 增长时可照同一先例把 descriptor 抽到 `core/models/media_descriptor.dart`——
/// 本批不动结构，避免影响既有调用点。
library;

import 'media_kind.dart';
import 'post.dart' show AylaMediaDescriptor;
import 'share_payload.dart';

/// 消息类型（`types.ts:138–139`）。
enum AylaMessageType {
  text,
  image,
  voice,
  file,
  emoji,
  video,
  mixed,
  system,
  poke,
  share;

  /// 后端字段值（`type`）。
  String get wire => name;

  /// 未知类型返回 null（**不 fallback 成 text**）。未知类型在 UI 上按文本分支
  /// 渲染（与 web 的 `message.type === …` 链式判断的实际行为一致）。
  static AylaMessageType? parse(String? raw) => switch (raw) {
        'text' => AylaMessageType.text,
        'image' => AylaMessageType.image,
        'voice' => AylaMessageType.voice,
        'file' => AylaMessageType.file,
        'emoji' => AylaMessageType.emoji,
        'video' => AylaMessageType.video,
        'mixed' => AylaMessageType.mixed,
        'system' => AylaMessageType.system,
        'poke' => AylaMessageType.poke,
        'share' => AylaMessageType.share,
        _ => null,
      };
}

/// 消息状态（`types.ts:140`）。
enum AylaMessageStatus {
  sent,
  delivered,
  read,
  recalled;

  /// 后端字段值（`status`）。
  String get wire => name;

  /// 未知状态返回 null。
  static AylaMessageStatus? parse(String? raw) => switch (raw) {
        'sent' => AylaMessageStatus.sent,
        'delivered' => AylaMessageStatus.delivered,
        'read' => AylaMessageStatus.read,
        'recalled' => AylaMessageStatus.recalled,
        _ => null,
      };
}

/// 结构化消息段类型（`types.ts:207–229` 的判别字段 `type`）。
enum AylaSegmentType {
  text,
  image,
  video,
  mention;

  static AylaSegmentType? parse(String? raw) => switch (raw) {
        'text' => AylaSegmentType.text,
        'image' => AylaSegmentType.image,
        'video' => AylaSegmentType.video,
        'mention' => AylaSegmentType.mention,
        _ => null,
      };
}

/// 结构化消息段（`type=mixed` 消息；`types.ts:207–229`）。
///
/// 判别联合在 Dart 侧用「[type] + 各自字段」表达：`text` 段只有 [text]；
/// `image`/`video` 段有 [mediaId] 与展开后的 [media]（乐观发送中为 null）；
/// `mention` 段有 [userId] 与展示名回退链（见 [mentionLabel]）。
class AylaMediaSegment {
  const AylaMediaSegment({
    required this.type,
    this.text = '',
    this.mediaId,
    this.media,
    this.userId,
    this.userNickname,
    this.userUsername,
    this.name,
  });

  final AylaSegmentType type;

  /// `text` 段正文。
  final String text;

  /// `image`/`video` 段的媒体 id。
  final String? mediaId;

  /// 服务端展开的 descriptor；乐观发送中（未上传）为 null。
  final AylaMediaDescriptor? media;

  /// `mention` 段被 @ 用户 id（字符串 UUID）。
  final String? userId;

  /// 服务端展开的被 @ 用户的昵称/用户名（历史消息用户已注销为 null）。
  final String? userNickname;
  final String? userUsername;

  /// 乐观消息本地显示名（服务端不返回此字段）。
  final String? name;

  /// 段内媒体是否为视频（`image`/`video` 两型的区分位）。
  bool get isVideo => type == AylaSegmentType.video;

  /// @ 展示名回退链（`utils/segment.ts:17–21` `mentionLabel`）：
  /// `user.nickname || user.username || name || "未知用户"`。
  String get mentionLabel =>
      _nonEmpty(userNickname) ??
      _nonEmpty(userUsername) ??
      _nonEmpty(name) ??
      '未知用户';

  /// 解析单个段；未知 `type` 返回 null（该段整体跳过，不伪造内容）。
  static AylaMediaSegment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaSegmentType? type = AylaSegmentType.parse(raw['type'] as String?);
    if (type == null) return null;
    final Object? user = raw['user'];
    return AylaMediaSegment(
      type: type,
      text: (raw['text'] as String?) ?? '',
      mediaId: raw['media_id'] as String?,
      media: AylaMediaDescriptor.fromJson(raw['media']),
      userId: raw['user_id'] as String?,
      userNickname: user is Map ? user['nickname'] as String? : null,
      userUsername: user is Map ? user['username'] as String? : null,
      name: raw['name'] as String?,
    );
  }

  static List<AylaMediaSegment> listFromJson(Object? raw) {
    if (raw is! List) return const <AylaMediaSegment>[];
    return raw
        .map(AylaMediaSegment.fromJson)
        .whereType<AylaMediaSegment>()
        .toList(growable: false);
  }
}

/// 乐观消息的本地媒体预览（未上传，仅本端可见；`types.ts:235–246`）。
///
/// ⚠️ 平台差异：web 的 [url] 是 `URL.createObjectURL` 产物（组件卸载时 revoke）；
/// Flutter 侧是**本地文件路径**（`XFile.path` / `File.path`），由持有方管理生命周期
/// （Flutter 没有 objectURL 需要释放）。
class AylaLocalMediaPreview {
  const AylaLocalMediaPreview({
    required this.id,
    required this.kind,
    required this.mimeType,
    required this.url,
    this.fileName,
    this.fileSize,
  });

  /// 段内唯一 id（与 segments 中媒体段一一对应）。
  final String id;

  /// `file` 为单文件消息（不走 mixed 段，仅乐观渲染/重试用）。
  final AylaMediaKind kind;

  final String mimeType;

  /// 本地文件路径（web：objectURL）。
  final String url;

  /// 文件消息的展示名与字节数（web 用 `File.name` / `File.size`）。
  final String? fileName;
  final int? fileSize;
}

/// 聊天消息（`types.ts:247–286` MessageSerializer 字段 + 应用侧乐观字段）。
class AylaChatMessage {
  const AylaChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    required this.content,
    required this.status,
    required this.seq,
    required this.createdAt,
    this.subgroupId,
    this.mediaId,
    this.media,
    this.segments = const <AylaMediaSegment>[],
    this.sharePayload,
    this.replyTo,
    this.replyToSeq,
    this.readByMe,
    this.pending = false,
    this.sendFailed = false,
    this.uploadProgress,
    this.idempotencyKey,
    this.localMedia = const <AylaLocalMediaPreview>[],
  });

  final String id;
  final String conversationId;
  final String senderId;

  /// 群聊子群归属（子群功能；null = 旧消息/默认组语义）。
  final String? subgroupId;

  /// 未知类型为 null → UI 按文本分支渲染（见 [AylaMessageType.parse]）。
  final AylaMessageType? type;

  /// 正文（媒体消息里是说明文字 / 文件名）。
  final String content;

  /// WS 帧路径只有字符串 media_id；descriptor 由消费方异步补拉后合并。
  final String? mediaId;

  /// 媒体 descriptor（REST 序列化返回）。
  final AylaMediaDescriptor? media;

  /// 图文混排段（`type=mixed`）。
  final List<AylaMediaSegment> segments;

  /// 分享载荷（`type=share`）。
  final AylaSharePayload? sharePayload;

  final String? replyTo;
  final int? replyToSeq;

  /// 当前登录用户的已读回执状态。
  final bool? readByMe;

  final AylaMessageStatus? status;

  /// 会话内单调递增序号（补发/分页游标）。
  final int seq;

  /// ISO 时间。
  final String createdAt;

  // ---- 以下为应用侧乐观发送字段（非后端契约）----

  /// 乐观发送中（气泡左侧加载态；seq=0，排序置底）。
  final bool pending;

  /// 发送失败（气泡左侧失败态，可重试/删除）。
  final bool sendFailed;

  /// 上传进度百分比 0–100（null = 无媒体或已上传完成）。
  final double? uploadProgress;

  /// 乐观消息幂等键（重试复用，服务端去重）。
  final String? idempotencyKey;

  /// 乐观消息的本地媒体预览（与 segments 媒体段按序对应；file 消息是单条）。
  final List<AylaLocalMediaPreview> localMedia;

  bool get recalled => status == AylaMessageStatus.recalled;

  bool get isSystem => type == AylaMessageType.system;

  bool get isShare => type == AylaMessageType.share;

  /// 媒体消息判定（`MessageBubble.tsx:46` `MEDIA_TYPES`）。
  /// `mixed` 也在其列 —— 它是「媒体消息」（走 MediaContent），只是内容为段流。
  bool get isMedia => switch (type) {
        AylaMessageType.image ||
        AylaMessageType.voice ||
        AylaMessageType.file ||
        AylaMessageType.emoji ||
        AylaMessageType.video ||
        AylaMessageType.mixed =>
          true,
        _ => false,
      };

  /// 合并 descriptor（等价 web `useMessageStore.mergeMedia` 后的重渲染输入：
  /// 消费方拉回 descriptor 后用它替换消息，避免滚动重渲染重复拉取）。
  AylaChatMessage copyWithMedia(AylaMediaDescriptor media) => AylaChatMessage(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        subgroupId: subgroupId,
        type: type,
        content: content,
        mediaId: mediaId,
        media: media,
        segments: segments,
        sharePayload: sharePayload,
        replyTo: replyTo,
        replyToSeq: replyToSeq,
        readByMe: readByMe,
        status: status,
        seq: seq,
        createdAt: createdAt,
        pending: pending,
        sendFailed: sendFailed,
        uploadProgress: uploadProgress,
        idempotencyKey: idempotencyKey,
        localMedia: localMedia,
      );

  /// 解析后端消息；缺 `id`/`conversation_id`/`sender_id` 视为非法 → null。
  static AylaChatMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? convId = raw['conversation_id'];
    final Object? senderId = raw['sender_id'];
    if (id is! String || convId is! String || senderId is! String) return null;
    return AylaChatMessage(
      id: id,
      conversationId: convId,
      senderId: senderId,
      subgroupId: raw['subgroup_id'] as String?,
      type: AylaMessageType.parse(raw['type'] as String?),
      content: (raw['content'] as String?) ?? '',
      mediaId: raw['media_id'] as String?,
      media: AylaMediaDescriptor.fromJson(raw['media']),
      segments: AylaMediaSegment.listFromJson(raw['segments']),
      sharePayload: AylaSharePayload.fromJson(raw['share_payload']),
      replyTo: raw['reply_to'] as String?,
      replyToSeq: (raw['reply_to_seq'] as num?)?.toInt(),
      readByMe: raw['read_by_me'] as bool?,
      status: AylaMessageStatus.parse(raw['status'] as String?),
      seq: (raw['seq'] as num?)?.toInt() ?? 0,
      createdAt: (raw['created_at'] as String?) ?? '',
      pending: raw['pending'] as bool? ?? false,
      sendFailed: raw['send_failed'] as bool? ?? false,
      uploadProgress: (raw['upload_progress'] as num?)?.toDouble(),
      idempotencyKey: raw['idempotency_key'] as String?,
      localMedia: _localMediaList(raw['local_media']),
    );
  }

  static List<AylaLocalMediaPreview> _localMediaList(Object? raw) {
    if (raw is! List) return const <AylaLocalMediaPreview>[];
    final List<AylaLocalMediaPreview> out = <AylaLocalMediaPreview>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final AylaMediaKind? kind = AylaMediaKind.parse(item['kind'] as String?);
      final Object? url = item['url'];
      if (kind == null || url is! String) continue;
      out.add(
        AylaLocalMediaPreview(
          id: (item['id'] as String?) ?? '',
          kind: kind,
          mimeType: (item['mime_type'] as String?) ?? '',
          url: url,
          fileName: item['file_name'] as String?,
          fileSize: (item['file_size'] as num?)?.toInt(),
        ),
      );
    }
    return List<AylaLocalMediaPreview>.unmodifiable(out);
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
