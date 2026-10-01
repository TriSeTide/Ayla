/// 私聊会话运行时与消息域页面胶水 —— web `hooks/useChat.ts` + `components/chat/PrivateChatPane.tsx`
/// 的页面级等价物（Flutter 侧没有 hook ⇒ 用 ChangeNotifier 承载「一个会话的编排」）。
///
/// ## 逐条对应
/// | 本件 | web |
/// |---|---|
/// | [AylaConversationRuntime.open] | `PrivateChatPane.tsx:93–117`（拉成员详情 + openConversation + openBucket + subscribe + 拉历史） |
/// | [AylaConversationRuntime.loadMore] | `useChat.ts:126–175`（`before_seq` = 缓存最小 seq，页 50） |
/// | [AylaConversationRuntime.send] | `useChat.ts:323–490`（乐观插入 → 上传 → 发送 → 原地替换） |
/// | [AylaConversationRuntime.retry] / [remove] / [cancel] | `useChat.ts:496–630` |
/// | [AylaConversationRuntime.recall] | `useChat.ts:633–637`（限时 120s：`RECALL_SECONDS`） |
/// | [AylaConversationRuntime.markReadExact] / [markReadThrough] | `useChat.ts:650–699` |
/// | [AylaConversationRuntime.onInput] | `hooks/useTyping.ts`（节流 2s 声明 + 停 3s 撤销） |
/// | [peerTyping] / [typingActive] | `PrivateChatPane.tsx:119–133`（只处理本会话、忽略自己） |
/// | [blocked] | `PrivateChatPane.tsx:157–163`（私聊 + 对端已知 + 好友关系已加载 + 对端不是爱莉 + 非好友） |
///
/// ## 与 web 的机制差异（登记）
/// - **历史加载失败静默**（web `.catch(() => {})`），但错误留在 [lastHistoryError] 可观测 ——
///   页面不新增 web 没有的错误 UI；
/// - `AylaChatMessage.localMedia` 只存**本地路径**（无 `File` 对象）⇒ 媒体消息重试从路径重读字节；
///   无路径（理论上仅 web blob 场景）时**不重试**并保留失败态（不伪造成功）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/users_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/models/elysia_profile.dart';
import '../core/models/social_requests.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart';
import '../state/notices_state.dart';
import '../state/paged_list.dart';
import '../widgets/chat/conversation_list.dart';
import '../widgets/chat/elysia_entry.dart';
import '../widgets/chat/private_chat_pane.dart';
import '../widgets/chat/request_rows.dart';
import '../widgets/chat/wide_messages_sidebar.dart';
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../core/media/media_upload.dart' show AylaMediaUploader;
import '../core/models/chat_message.dart';
import '../core/models/conversation.dart';
import '../core/models/media_kind.dart' show AylaMediaKind;
import '../core/models/mention.dart';
import '../core/models/user_public.dart';
import '../core/ws/chat_ws.dart';
import '../state/badges_state.dart';
import '../state/chat_drafts.dart';
import '../state/chat_state.dart';
import '../state/message_state.dart';
import '../theme/tokens.dart';
import '../widgets/chat/message_input.dart'
    show AylaMessageInput, AylaMessageInputSubmission, AylaPickedMedia;

/// 首屏历史条数（web `useChat.ts:34` `INITIAL_HISTORY_LIMIT`）。
const int kAylaInitialHistoryLimit = 20;

/// 上拉翻页条数（web `useChat.ts:35` `HISTORY_PAGE_LIMIT`）。
const int kAylaHistoryPageLimit = 50;

/// 撤回时限（web `useChat.ts:26` `RECALL_SECONDS`，与后端 `MESSAGE_RECALL_SECONDS` 对齐）。
const int kAylaRecallSeconds = 120;

/// 输入区草稿键 —— web `MessageInput.tsx:90–91`：
/// `const draftKey = isGroup ? ${convId}:${subgroupId ?? ""} : convId`。
///
/// 群聊**每个子群一个独立草稿槽**；[subgroupId] 为 null 时得 `convId:`
/// （与 web 逐字一致 —— 不是 `convId`，两端不得各自发挥）。
String aylaSubgroupDraftKey(String conversationId, String? subgroupId) =>
    '$conversationId:${subgroupId ?? ''}';

/// 子群 id 的 **POST 参数**形态 —— web 四个出口（`useChat.ts:381/448/477` 与 477 同判据）
/// 都是 `subgroupId != null ? Number(subgroupId) : undefined`：
/// 非法（非数字）时 `Number()` 得 NaN、`JSON.stringify(NaN)` 得 `null` ⇒ 等价于"不发"，
/// 因此这里同样**返回 null**（[AylaCreateMessagePayload.toJson] 对 null 是不进 body，
/// 与 web 的 `undefined` 同义 —— 见 `core/models/chat_message.dart:478` 的「缺席即缺席」）。
int? aylaSubgroupIdParam(String? subgroupId) =>
    subgroupId == null ? null : int.tryParse(subgroupId);

/// typing 声明节流 / 停止延迟（web `useTyping.ts:11–12`）。
const int kAylaTypingDeclareIntervalMs = 2000;
const int kAylaTypingStopDelayMs = 3000;

/// 私聊会话运行时（一个会话一个实例；随 `AylaConversationTransition` 的 identity 切换重建）。
class AylaConversationRuntime extends ChangeNotifier {
  AylaConversationRuntime({
    required this.conversationId,
    required AylaChatState chatState,
    required AylaMessageState messageState,
    required AylaChatDraftsController drafts,
    required AylaBadgesController badges,
    required AylaChatWsClient ws,
    required String? Function() currentUserId,
    String? Function()? elysiaUserId,
  })  : _chat = chatState,
        _message = messageState,
        _drafts = drafts,
        _badges = badges,
        _ws = ws,
        _currentUserId = currentUserId,
        _elysiaUserId = elysiaUserId ?? (() => null);

  final String conversationId;
  final AylaChatState _chat;
  final AylaMessageState _message;
  final AylaChatDraftsController _drafts;
  final AylaBadgesController _badges;
  final AylaChatWsClient _ws;
  final String? Function() _currentUserId;
  final String? Function() _elysiaUserId;

  bool _disposed = false;
  void Function()? _frameOff;
  Timer? _typingStop;
  int _lastTypingSentMs = 0;
  final Map<String, bool> _peerTyping = <String, bool>{};
  final Map<String, CancelToken> _uploadCancels = <String, CancelToken>{};

  /// 好友关系查询：已加载标志（false = 未知 ⇒ **不禁用输入**，后端 403 才是权威）。
  bool _friendsLoaded = false;
  bool _peerIsFriend = false;

  /// 最近一次历史加载错误（页面不显示；只作可观测诊断）。
  String? lastHistoryError;

  /// 当前会话摘要（null = 尚未加载 ⇒ 头部按「私聊」占位）。
  AylaConversationSummary? get conversation => _chat.byId(conversationId);

  /// 当前会话消息（时间升序，pending 置底）。
  List<AylaChatMessage> get messages => _message.messagesOf(conversationId);

  /// 消息桶（null = 未打开）。
  AylaMessageBucket? get bucket => _message.bucketOf(conversationId);

  bool get hasMore => bucket?.hasMore ?? false;

  bool get loading => bucket?.loading ?? false;

  /// 「对方正在输入…」。
  bool get typingActive => _peerTyping.values.any((bool v) => v);

  /// 非好友禁发（web `PrivateChatPane.tsx:158–163`）。
  bool get blocked {
    final AylaConversationSummary? conv = conversation;
    final AylaUserPublic? peer = conv?.peer;
    final String? elysiaId = _elysiaUserId();
    return conv != null &&
        conv.isPrivate &&
        peer != null &&
        _friendsLoaded &&
        !(elysiaId != null && peer.id == elysiaId) &&
        !_peerIsFriend;
  }

  /// 输入区草稿键（web `MessageInput.tsx:91` 的 `draftKey` = 会话 id）。
  ///
  /// 私聊恒走 `isGroup === false` 分支（web `PrivateChatPane.tsx:249` 不传 members/groupId）
  /// ⇒ `draftKey === convId`；群聊的 `convId:subgroupId` 形态在
  /// `group_chat_page.dart` 由 [aylaSubgroupDraftKey] 表达（本运行时只服务私聊）。
  String get draftKey => conversationId;

  /// 当前草稿（`@[user_id]` 序列化格式）。
  String get draft => _drafts.draftFor(conversationId);

  /// 打开会话（进入页面 / 切到该会话时调用一次）。
  Future<void> open() async {
    if (_disposed) return;
    _chat.openConversation(conversationId);
    _message.openBucket(conversationId);
    _ws.subscribe(<String>[conversationId]);
    _frameOff ??= _ws.onFrame(_onFrame);
    await Future.wait(<Future<void>>[
      refreshMetadata(),
      _loadInitialHistory(),
      _resolveFriendship(),
    ]);
  }

  /// 拉会话详情（成员完整；web `PrivateChatPane.tsx:96–98`）。失败静默。
  Future<void> refreshMetadata() async {
    try {
      final AylaConversationSummary conv =
          await AylaChatApi.getConversationMetadata(conversationId);
      if (_disposed) return;
      _chat.upsertConversation(conv);
    } catch (_) {
      // 会话详情失败不阻断聊天（发送/已读仍由服务端裁决）
    }
  }

  Future<void> _loadInitialHistory() async {
    _message.setLoading(conversationId, true);
    try {
      final List<AylaChatMessage> list = await AylaChatApi.listMessages(
        conversationId,
        limit: kAylaInitialHistoryLimit,
      );
      if (_disposed) return;
      lastHistoryError = null;
      _message.prependHistory(
        conversationId,
        list,
        hasMore: list.length >= kAylaInitialHistoryLimit,
      );
      if (list.isEmpty) {
        // 明确「没有更早历史」（web `useChat.ts:107`）。
        _message.prependHistory(conversationId, const <AylaChatMessage>[],
            hasMore: false);
      }
    } catch (err) {
      lastHistoryError = err.toString();
    } finally {
      if (!_disposed) _message.setLoading(conversationId, false);
    }
  }

  Future<void> _resolveFriendship() async {
    final String? peerId = conversation?.peer?.id;
    if (peerId == null) return;
    try {
      final AylaUserDetail detail = await AylaUsersApi.getUserDetail(peerId);
      if (_disposed) return;
      _peerIsFriend = detail.relation == AylaFriendRelation.friend ||
          detail.relation == AylaFriendRelation.self;
      _friendsLoaded = true;
      _notify();
    } catch (_) {
      // 关系未知：不禁用输入（后端 403 权威拦截，web 同）
    }
  }

  /// 上拉加载更早历史（web `useChat.ts:126–175`）。
  Future<void> loadMore() async {
    final AylaMessageBucket? current = bucket;
    if (current == null || current.loading || !current.hasMore) return;
    int? minSeq;
    for (final AylaChatMessage m in current.messages) {
      if (m.seq > 0) {
        minSeq = m.seq;
        break;
      }
    }
    if (minSeq == null) return;
    _message.setLoading(conversationId, true);
    try {
      final List<AylaChatMessage> list = await AylaChatApi.listMessages(
        conversationId,
        beforeSeq: minSeq,
        limit: kAylaHistoryPageLimit,
      );
      if (_disposed) return;
      _message.prependHistory(
        conversationId,
        list,
        hasMore: list.length >= kAylaHistoryPageLimit,
      );
    } catch (_) {
      // 失败保留已加载内容（footer 由下一次上拉重试）
    } finally {
      if (!_disposed) _message.setLoading(conversationId, false);
    }
  }

  /// 按 seq 翻页直到目标消息在缓存里（web `useChat.ts:185–214`）。
  Future<bool> loadUntilSeq(int targetSeq, {int maxPages = 200}) async {
    if (targetSeq <= 0) return false;
    for (int page = 0; page < maxPages; page++) {
      final AylaMessageBucket? current = bucket;
      if (current == null) return false;
      if (current.messages.any((AylaChatMessage m) => m.seq == targetSeq)) {
        return true;
      }
      int? minSeq;
      for (final AylaChatMessage m in current.messages) {
        if (!m.pending && m.seq > 0) {
          minSeq = m.seq;
          break;
        }
      }
      if (minSeq == null || minSeq <= targetSeq || !current.hasMore) return false;
      final int before = minSeq;
      await loadMore();
      final AylaMessageBucket? next = bucket;
      if (next == null) return false;
      int? nextMin;
      for (final AylaChatMessage m in next.messages) {
        if (!m.pending && m.seq > 0) {
          nextMin = m.seq;
          break;
        }
      }
      if (nextMin == null || nextMin >= before) return false;
    }
    return false;
  }

  // ---------------- 发送 ----------------

  /// 乐观发送（web `useChat.ts:323–490`）。
  void send(AylaMessageInputSubmission submission) {
    final List<AylaDraftBlock> blocks = submission.blocks;
    final List<AylaPickedMedia> picked = submission.picked;
    final String text = aylaBlocksText(blocks).trim();
    final bool hasMention = aylaBlocksHasMention(blocks);
    final int? replyTo = int.tryParse(submission.replyToId ?? '');
    final String key = aylaNewIdempotencyKey();
    final String localId = 'local-$key';
    final String? me = _currentUserId();
    final String nowIso = DateTime.now().toUtc().toIso8601String();

    final AylaPickedMedia? fileItem = _firstOfKind(picked, AylaMediaKind.file);
    if (fileItem != null) {
      // 文件消息（type=file 单媒体，不走 mixed 段；content 存文件名）。
      _message.addPendingMessage(
        conversationId,
        AylaChatMessage(
          id: localId,
          conversationId: conversationId,
          senderId: me ?? '',
          type: AylaMessageType.file,
          content: fileItem.file.name,
          status: AylaMessageStatus.sent,
          seq: 0,
          createdAt: nowIso,
          replyTo: replyTo?.toString(),
          // web `useChat.ts:348` 乐观态同理（原样传）。
          subgroupId: submission.subgroupId,
          pending: true,
          uploadProgress: 0,
          idempotencyKey: key,
          localMedia: <AylaLocalMediaPreview>[_previewOf(fileItem)],
        ),
      );
      final CancelToken cancel = CancelToken();
      _uploadCancels[localId] = cancel;
      unawaited(() async {
        try {
          final AylaUploadOutcome? uploaded = await _uploadOne(
            fileItem,
            localId,
            cancel,
          );
          if (uploaded == null) return;
          _message.setMessageUploadProgress(conversationId, localId, null);
          final AylaChatMessage serverMsg = await AylaChatApi.sendMessage(
            conversationId,
            AylaCreateMessagePayload(
              type: AylaMessageType.file,
              content: fileItem.file.name,
              replyTo: replyTo,
              idempotencyKey: key,
              mediaId: uploaded.mediaId,
              // web `useChat.ts:381`（文件分支同判据）。
              subgroupId: aylaSubgroupIdParam(submission.subgroupId),
            ),
          );
          _message.resolvePendingMessage(
            conversationId,
            localId,
            key,
            serverMsg,
          );
        } catch (_) {
          if (!cancel.isCancelled) {
            _message.markMessageFailed(conversationId, localId);
          }
        } finally {
          _uploadCancels.remove(localId);
        }
      }());
      return;
    }

    // 无媒体且无 @ = 纯文本（旧 text 契约）；有媒体或有 @ = mixed + segments。
    final bool isMixed = picked.isNotEmpty || hasMention;
    final List<AylaMediaSegment> optimisticSegments = isMixed
        ? <AylaMediaSegment>[
            ...aylaBlocksToSegments(blocks),
            for (final AylaPickedMedia p in picked)
              AylaMediaSegment(type: _segmentTypeOf(p.kind), mediaId: ''),
          ]
        : const <AylaMediaSegment>[];
    _message.addPendingMessage(
      conversationId,
      AylaChatMessage(
        id: localId,
        conversationId: conversationId,
        senderId: me ?? '',
        type: isMixed ? AylaMessageType.mixed : AylaMessageType.text,
        content: text,
        segments: optimisticSegments,
        status: AylaMessageStatus.sent,
        seq: 0,
        createdAt: nowIso,
        replyTo: replyTo?.toString(),
        // web `useChat.ts:427` 乐观态 subgroup_id 是**原样传**（POST 才 Number()）。
        subgroupId: submission.subgroupId,
        pending: true,
        uploadProgress: picked.isEmpty ? null : 0,
        idempotencyKey: key,
        localMedia: <AylaLocalMediaPreview>[
          for (final AylaPickedMedia p in picked) _previewOf(p),
        ],
      ),
    );

    if (!isMixed) {
      unawaited(() async {
        try {
          final AylaChatMessage serverMsg = await AylaChatApi.sendMessage(
            conversationId,
            AylaCreateMessagePayload(
              type: AylaMessageType.text,
              content: text,
              replyTo: replyTo,
              idempotencyKey: key,
              // web `useChat.ts:448`：`subgroup_id: subgroupId != null ? Number(subgroupId) : undefined`。
              subgroupId: aylaSubgroupIdParam(submission.subgroupId),
            ),
          );
          _message.resolvePendingMessage(
            conversationId,
            localId,
            key,
            serverMsg,
          );
        } catch (_) {
          _message.markMessageFailed(conversationId, localId);
        }
      }());
      return;
    }

    final CancelToken cancel = CancelToken();
    _uploadCancels[localId] = cancel;
    unawaited(() async {
      try {
        final List<AylaUploadOutcome> uploaded = <AylaUploadOutcome>[];
        for (int i = 0; i < picked.length; i++) {
          final AylaUploadOutcome? one = await _uploadOne(
            picked[i],
            localId,
            cancel,
            index: i,
            total: picked.length,
          );
          if (one == null) return;
          uploaded.add(one);
        }
        _message.setMessageUploadProgress(conversationId, localId, null);
        final List<AylaOutgoingSegment> segments = <AylaOutgoingSegment>[
          for (final AylaMediaSegment seg in aylaBlocksToSegments(blocks))
            if (seg.type == AylaSegmentType.text)
              AylaOutgoingSegment.text(seg.text)
            else if (seg.type == AylaSegmentType.mention)
              AylaOutgoingSegment.mention(seg.userId ?? ''),
          for (int i = 0; i < uploaded.length; i++)
            picked[i].kind == AylaMediaKind.video
                ? AylaOutgoingSegment.video(uploaded[i].mediaId)
                : AylaOutgoingSegment.image(uploaded[i].mediaId),
        ];
        final AylaChatMessage serverMsg = await AylaChatApi.sendMessage(
          conversationId,
          AylaCreateMessagePayload(
            type: AylaMessageType.mixed,
            content: text,
            replyTo: replyTo,
            idempotencyKey: key,
            segments: segments,
            // web `useChat.ts:477`（与文本分支同判据）。
            subgroupId: aylaSubgroupIdParam(submission.subgroupId),
          ),
        );
        _message.resolvePendingMessage(
          conversationId,
          localId,
          key,
          serverMsg,
        );
      } catch (_) {
        if (!cancel.isCancelled) {
          _message.markMessageFailed(conversationId, localId);
        }
      } finally {
        _uploadCancels.remove(localId);
      }
    }());
  }

  /// 重试失败的乐观消息（复用原幂等键；web `useChat.ts:496–614`）。
  void retry(AylaChatMessage msg) {
    final String? key = msg.idempotencyKey;
    if (key == null) {
      _message.removeMessage(conversationId, msg.id);
      return;
    }
    _message.removeMessage(conversationId, msg.id);
    final String localId = 'local-$key';
    _message.addPendingMessage(
      conversationId,
      msg.copyWith(
        id: localId,
        pending: true,
        sendFailed: false,
        seq: 0,
        idempotencyKey: key,
        uploadProgress: msg.localMedia.isEmpty ? null : 0,
      ),
    );
    final bool hasMention = msg.segments
        .any((AylaMediaSegment s) => s.type == AylaSegmentType.mention);
    final bool isMixed = msg.localMedia.isNotEmpty || hasMention;
    if (!isMixed) {
      unawaited(() async {
        try {
          final AylaChatMessage serverMsg = await AylaChatApi.sendMessage(
            conversationId,
            AylaCreateMessagePayload(
              type: AylaMessageType.text,
              content: msg.content,
              replyTo: int.tryParse(msg.replyTo ?? ''),
              idempotencyKey: key,
            ),
          );
          _message.resolvePendingMessage(
            conversationId,
            localId,
            key,
            serverMsg,
          );
        } catch (_) {
          _message.markMessageFailed(conversationId, localId);
        }
      }());
      return;
    }
    // 媒体消息重试：从本地路径重读字节（无路径 ⇒ 保留失败态，不伪造成功）。
    final List<AylaPickedMedia> repicked = <AylaPickedMedia>[
      for (final AylaLocalMediaPreview p in msg.localMedia)
        AylaPickedMedia(
          id: p.id,
          kind: p.kind,
          file: AylaPickedFile(
            name: p.fileName ?? '',
            size: p.fileSize ?? 0,
            mimeType: p.mimeType,
            path: p.url.isEmpty ? null : p.url,
            readBytes: () async {
              final File file = File(p.url);
              return file.readAsBytes();
            },
          ),
        ),
    ];
    final CancelToken cancel = CancelToken();
    _uploadCancels[localId] = cancel;
    unawaited(() async {
      try {
        final List<AylaUploadOutcome> uploaded = <AylaUploadOutcome>[];
        for (int i = 0; i < repicked.length; i++) {
          final AylaUploadOutcome? one = await _uploadOne(
            repicked[i],
            localId,
            cancel,
            index: i,
            total: repicked.length,
          );
          if (one == null) return;
          uploaded.add(one);
        }
        _message.setMessageUploadProgress(conversationId, localId, null);
        final List<AylaOutgoingSegment> segments = <AylaOutgoingSegment>[
          for (final AylaMediaSegment seg in msg.segments)
            if (seg.type == AylaSegmentType.text)
              AylaOutgoingSegment.text(seg.text)
            else if (seg.type == AylaSegmentType.mention)
              AylaOutgoingSegment.mention(seg.userId ?? ''),
          for (int i = 0; i < uploaded.length; i++)
            repicked[i].kind == AylaMediaKind.video
                ? AylaOutgoingSegment.video(uploaded[i].mediaId)
                : AylaOutgoingSegment.image(uploaded[i].mediaId),
        ];
        final AylaChatMessage serverMsg = await AylaChatApi.sendMessage(
          conversationId,
          AylaCreateMessagePayload(
            type: AylaMessageType.mixed,
            content: msg.content,
            replyTo: int.tryParse(msg.replyTo ?? ''),
            idempotencyKey: key,
            segments: segments,
          ),
        );
        _message.resolvePendingMessage(
          conversationId,
          localId,
          key,
          serverMsg,
        );
      } catch (_) {
        if (!cancel.isCancelled) {
          _message.markMessageFailed(conversationId, localId);
        }
      } finally {
        _uploadCancels.remove(localId);
      }
    }());
  }

  /// 取消上传中的乐观消息（web `useChat.ts:617–624`）。
  void cancel(AylaChatMessage msg) {
    final CancelToken? token = _uploadCancels.remove(msg.id);
    if (token != null && !token.isCancelled) token.cancel('用户取消');
    _message.removeMessage(conversationId, msg.id);
  }

  /// 丢弃本地消息（乐观失败丢弃）。
  void remove(AylaChatMessage msg) {
    _message.removeMessage(conversationId, msg.id);
  }

  /// 撤回（仅自己 + 窗口内；后端 403/400 抛错由调用方提示）。
  Future<void> recall(AylaChatMessage msg) async {
    if (msg.status == AylaMessageStatus.recalled) return;
    try {
      await AylaChatApi.recallMessage(conversationId, msg.id);
      if (_disposed) return;
      _message.setRecalled(conversationId, msg.id);
    } catch (_) {
      // 撤回失败静默（web `PrivateChatPane.tsx:139–141`）
    }
  }

  /// 戳一戳（双击头像；web `PrivateChatPane.tsx:145–151`）。
  Future<void> poke(String targetUserId) async {
    try {
      await AylaChatApi.sendPoke(conversationId, targetUserId);
    } catch (_) {
      // 失败静默：WS 回帧才是渲染与排序的依据
    }
  }

  // ---------------- 已读 ----------------

  /// 精确标记一条已读（web `useChat.ts:684–699`）。
  Future<void> markReadExact(AylaChatMessage msg) async {
    try {
      final AylaMessageReadReceipt receipt =
          await AylaChatApi.markMessageRead(conversationId, msg.id, exact: true);
      if (_disposed) return;
      _message.markReadByMe(conversationId, msg.id);
      _chat.markReadSeqs(
        conversationId,
        receipt.markedSeqs ?? <int>[msg.seq],
      );
      unawaited(_badges.fetch());
    } catch (_) {
      // 已读失败保留未读红点（下次打开重试）
    }
  }

  /// 普通未读标签批量已读（服务端保留 @我/回复；web `useChat.ts:650–681`）。
  Future<void> markReadThrough(int throughSeq, List<String> excludeIds) async {
    try {
      await AylaChatApi.markConversationRead(
        conversationId,
        throughSeq: throughSeq,
        excludeMessageIds: excludeIds,
        preserveSpecial: true,
      );
    } catch (_) {
      return;
    }
    if (_disposed) return;
    final AylaConversationSummary? conv = _chat.byId(conversationId);
    final Set<int> special = <int>{
      ...?conv?.mentionUnreadSeqs,
      ...?conv?.replyUnreadSeqs,
    };
    final List<int> readSeqs = <int>[
      for (final int seq in conv?.unreadSeqs ?? const <int>[])
        if (seq <= throughSeq && !special.contains(seq)) seq,
    ];
    final String? me = _currentUserId();
    for (final AylaChatMessage m in messages) {
      if (m.seq > 0 &&
          m.seq <= throughSeq &&
          m.senderId != me &&
          !excludeIds.contains(m.id)) {
        readSeqs.add(m.seq);
        _message.markReadByMe(conversationId, m.id);
      }
    }
    _chat.markReadSeqs(conversationId, readSeqs);
    unawaited(_badges.fetch());
  }

  /// 输入回车/文本变化 → typing 声明（web `useTyping.ts:32–36`）。
  void onInput() {
    _declareTyping(true);
    _typingStop?.cancel();
    _typingStop = Timer(
      const Duration(milliseconds: kAylaTypingStopDelayMs),
      () => _declareTyping(false),
    );
  }

  void _declareTyping(bool isTyping) {
    if (!isTyping && _lastTypingSentMs == 0) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (isTyping && now - _lastTypingSentMs < kAylaTypingDeclareIntervalMs) return;
    _lastTypingSentMs = now;
    unawaited(
      AylaChatApi.declareTyping(conversationId, isTyping)
          .catchError((Object _) {}),
    );
  }

  /// 贴底状态上报（由 `AylaMessageList.onAtBottomChanged` 注入）。
  void setViewerAtBottom(bool atBottom) {
    _message.setViewerAtBottom(conversationId, atBottom);
  }

  // ---------------- 内部 ----------------

  void _onFrame(Map<String, dynamic> frame) {
    if (frame['type'] != 'typing') return;
    final Object? data = frame['data'];
    if (data is! Map) return;
    if ('${data['conversation_id']}' != conversationId) return;
    final String userId = '${data['user_id']}' ;
    final String? me = _currentUserId();
    if (me != null && userId == me) return;
    _peerTyping[userId] = data['is_typing'] == true;
    _notify();
  }

  Future<AylaUploadOutcome?> _uploadOne(
    AylaPickedMedia picked,
    String localId,
    CancelToken cancel, {
    int index = 0,
    int total = 1,
  }) async {
    final Uint8List bytes = await picked.file.readBytes();
    int last = 0;
    final result = await AylaMediaUploader.instance.uploadBytes(
      bytes: bytes,
      kind: picked.kind,
      mimeType: picked.file.mimeType,
      cancelToken: cancel,
      onProgress: (progress) {
        final int loaded = progress.loaded;
        last = loaded;
        final int pct = bytes.isEmpty
            ? 0
            : ((last / bytes.length) * 99).floor().clamp(0, 99);
        _message.setMessageUploadProgress(
          conversationId,
          localId,
          pct.toDouble(),
        );
      },
    );
    return AylaUploadOutcome(mediaId: result.mediaId);
  }

  static AylaPickedMedia? _firstOfKind(
    List<AylaPickedMedia> picked,
    AylaMediaKind kind,
  ) {
    for (final AylaPickedMedia p in picked) {
      if (p.kind == kind) return p;
    }
    return null;
  }

  static AylaLocalMediaPreview _previewOf(AylaPickedMedia picked) =>
      AylaLocalMediaPreview(
        id: picked.id,
        kind: picked.kind,
        mimeType: picked.file.mimeType,
        url: picked.file.path ?? '',
        fileName: picked.file.name,
        fileSize: picked.file.size,
      );

  static AylaSegmentType _segmentTypeOf(AylaMediaKind kind) =>
      kind == AylaMediaKind.video
          ? AylaSegmentType.video
          : AylaSegmentType.image;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _typingStop?.cancel();
    _frameOff?.call();
    for (final CancelToken token in _uploadCancels.values) {
      if (!token.isCancelled) token.cancel('离开会话');
    }
    _uploadCancels.clear();
    // 离开私聊（切换会话/返回）时清 activeId，避免其他会话的 message.new 被误判为「正在看」。
    if (_chat.activeConversationId == conversationId) _chat.closeConversation();
    super.dispose();
  }
}

/// 上传成功的最小载荷（web `UploadCompleteResult` 只用到 `media_id`）。
class AylaUploadOutcome {
  const AylaUploadOutcome({required this.mediaId});

  final String mediaId;
}

// ======================= 私聊面板宿主 =======================

/// 私聊面板宿主 —— `/messages` 宽屏右列、`/chat/:id` 窄屏与宽屏**三处共用**的装配层。
///
/// 负责把 [AylaConversationRuntime] 的投影与回调灌进 [AylaPrivateChatPane]
/// （web 侧这些都在 `PrivateChatPane.tsx` 内部直连 store；Flutter 侧按纪律把数据流留在页面层）。
class AylaChatPaneHost extends ConsumerStatefulWidget {
  const AylaChatPaneHost({
    super.key,
    required this.conversationId,
    this.narrow = false,
    this.panelMotion = false,
    this.onBack,
    this.externalJump,
  });

  final String conversationId;

  /// 窄屏档（头部通栏 + 工具键下移 + 返回键由调用方给）。
  final bool narrow;

  /// 三区进出场编排（web `PrivateChatPane.tsx:43` 的 `panelMotion`）—— 原样透传给
  /// [AylaPrivateChatPane]；须与 `AylaConversationTransition(childOwnsPanels: true)` 同传。
  final bool panelMotion;

  /// 返回键（窄屏私聊窗口 → `/messages`；宽屏两列不传）。
  final VoidCallback? onBack;

  /// 收藏消息跳转定位（`/chat/:id?msg=&seq=`）。
  final ({String messageId, int seq})? externalJump;

  @override
  ConsumerState<AylaChatPaneHost> createState() => _AylaChatPaneHostState();
}

class _AylaChatPaneHostState extends ConsumerState<AylaChatPaneHost> {
  late final AylaConversationRuntime _runtime;
  AylaChatMessage? _quote;

  @override
  void initState() {
    super.initState();
    _runtime = AylaConversationRuntime(
      conversationId: widget.conversationId,
      chatState: ref.read(chatStateProvider),
      messageState: ref.read(messageStateProvider),
      drafts: ref.read(chatDraftsProvider),
      badges: ref.read(badgesProvider),
      ws: ref.read(chatWsProvider),
      currentUserId: () => ref.read(authNotifierProvider).user?.id,
      elysiaUserId: () => ref.read(elysiaProfileProvider).valueOrNull?.userId,
    );
    _runtime.addListener(_onRuntimeChanged);
    unawaited(_runtime.open());
  }

  @override
  void dispose() {
    _runtime.removeListener(_onRuntimeChanged);
    _runtime.dispose();
    super.dispose();
  }

  void _onRuntimeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 消息分桶与会话摘要都在 store 里 ⇒ 两类变化都要重绘。
    ref.watch(messageStateProvider);
    ref.watch(chatStateProvider);
    final AylaConversationSummary? conv = _runtime.conversation;
    final AylaUserPublic? peer = conv?.peer;
    final bool online = peer?.online ?? false;
    final AylaChatDraftsController drafts = ref.read(chatDraftsProvider);
    final String? me = ref.watch(authNotifierProvider).user?.id;
    final String? elysiaId =
        ref.watch(elysiaProfileProvider).valueOrNull?.userId;

    return AylaPrivateChatPane(
      conversation: conv,
      messages: _runtime.messages,
      currentUserId: me,
      elysiaUserId: elysiaId,
      onBack: widget.onBack,
      narrow: widget.narrow,
      panelMotion: widget.panelMotion,
      hasMore: _runtime.hasMore,
      loading: _runtime.loading,
      onLoadMore: _runtime.loadMore,
      onQuote: (AylaChatMessage m) => setState(() => _quote = m),
      onRecall: (AylaChatMessage m) => unawaited(_runtime.recall(m)),
      onRetry: _runtime.retry,
      onRemove: _runtime.remove,
      onCancel: _runtime.cancel,
      onMarkRead: (AylaChatMessage m, bool exact) async {
        if (exact) await _runtime.markReadExact(m);
      },
      onMarkConversationRead: (int throughSeq, List<String> excludeIds) =>
          _runtime.markReadThrough(throughSeq, excludeIds),
      onLoadUntilSeq: (int seq) => _runtime.loadUntilSeq(seq),
      onPoke: (String userId) => unawaited(_runtime.poke(userId)),
      onAvatarTap: peer == null
          ? null
          : () => context.go('/user/${Uri.encodeComponent(peer.id)}'),
      unreadSeqs: conv?.unreadSeqs ?? const <int>[],
      mentionUnreadSeqs: conv?.mentionUnreadSeqs ?? const <int>[],
      replyUnreadSeqs: conv?.replyUnreadSeqs ?? const <int>[],
      peerOnline: online,
      peerStatus: aylaDisplayStatusOf(peer?.status, online),
      peerTyping: _runtime.typingActive,
      blocked: _runtime.blocked,
      externalJump: widget.externalJump,
      onExternalJumpHandled: widget.externalJump == null ? null : () {},
      onAtBottomChanged: _runtime.setViewerAtBottom,
      composer: AylaMessageInput(
        onSubmit: (AylaMessageInputSubmission submission) {
          _runtime.send(submission);
          if (_quote != null) setState(() => _quote = null);
        },
        quote: _quote,
        onQuoteClear: () => setState(() => _quote = null),
        // 私聊无群成员 ⇒ @ 选择器为空（web 同：members 只在群聊传入）
        members: const <AylaConversationMember>[],
        draftKey: _runtime.draftKey,
        initialDraft: drafts.draftFor(_runtime.draftKey),
        onDraftChanged: (String key, String serialized) =>
            drafts.setDraft(key, serialized),
        onTyping: _runtime.onInput,
        narrow: widget.narrow,
        // 宽屏浮动输入卡的 12px 外边距（`auroraqua.css:347–359` 在 @media ≥769 内），
        // 左归零（`.wide-messages-pane .composer`，同块 361–368）。窄屏档忽略该参数。
        gutter: const EdgeInsets.fromLTRB(
          0,
          AylaSpacing.sidebarGutter,
          AylaSpacing.sidebarGutter,
          AylaSpacing.sidebarGutter,
        ),
      ),
    );
  }
}

// ======================= 宽屏消息左列宿主 =======================

/// 宽屏消息左列宿主 —— `/messages` 宽屏与 `/chat/:id` 宽屏共用。
///
/// web 的 `WideMessagesSidebar` **自己取数**（`useSocialPage` 五路 + WS 帧刷新 + badges）；
/// Flutter 侧按纪律把取数留在页面层 ⇒ 本宿主承担那部分，装配出纯视觉件 [AylaWideMessagesSidebar]。
///
/// 事实源：`WideMessagesSidebar.tsx:35–334`（含 137–170 的三路动作与 120–133 的帧刷新）。
class AylaWideMessagesSidebarHost extends ConsumerStatefulWidget {
  const AylaWideMessagesSidebarHost({
    super.key,
    required this.activeId,
    required this.onSelect,
  });

  final String? activeId;
  final void Function(String id) onSelect;

  @override
  ConsumerState<AylaWideMessagesSidebarHost> createState() =>
      _AylaWideMessagesSidebarHostState();
}

class _AylaWideMessagesSidebarHostState
    extends ConsumerState<AylaWideMessagesSidebarHost> {
  AylaPagedList<AylaConversationSummary>? _conversations;
  AylaPagedList<AylaUserPublic>? _friends;
  AylaPagedList<AylaFriendRequest>? _friendRequests;
  AylaPagedList<AylaGroupInvite>? _invites;
  AylaPagedList<AylaGroupJoinRequest>? _joinRequests;
  AylaPagedList<AylaGroupMemberLeaveNotice>? _leaveNotices;
  String? _removingFriendId;
  String? _busyId;
  void Function()? _frameOff;

  @override
  void initState() {
    super.initState();
    _conversations = _pager<AylaConversationSummary>(
      (String? cursor) => AylaChatApi.listConversationsPage(
        limit: 30,
        cursor: cursor,
        type: 'private',
      ),
      (AylaConversationSummary c) => c.id,
    );
    // ⚠️ 好友/认证四路**懒加载**：web `WideMessagesSidebar.tsx:55–64` 的 `useSocialPage(kind, {}, tab === ...)`
    // 只在对应 tab 打开时取数（切 tab 触发 `onTabChanged` ⇒ 这里即时建分页器）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _frameOff = ref.read(chatWsProvider).onFrame((Map<String, dynamic> frame) {
        final Object? type = frame['type'];
        if (type is String && aylaIsAuthRefreshFrame(type)) {
          unawaited(_friendRequests?.refresh());
          unawaited(_invites?.refresh());
          unawaited(_joinRequests?.refresh());
          unawaited(_leaveNotices?.refresh());
        }
      });
    });
  }

  @override
  void dispose() {
    _frameOff?.call();
    _conversations?.dispose();
    _friends?.dispose();
    _friendRequests?.dispose();
    _invites?.dispose();
    _joinRequests?.dispose();
    _leaveNotices?.dispose();
    super.dispose();
  }

  AylaPagedList<T> _pager<T>(
    Future<AylaDirectoryPage<T>> Function(String? cursor) request,
    String Function(T item) keyOf,
  ) {
    final AylaPagedList<T> pager = AylaPagedList<T>(
      request: request,
      keyOf: keyOf,
    );
    pager.addListener(_onChanged);
    unawaited(pager.load());
    return pager;
  }

  void _onChanged() {
    if (!mounted) return;
    final AylaChatState chat = ref.read(chatStateProvider);
    for (final AylaConversationSummary c
        in _conversations?.items ?? const <AylaConversationSummary>[]) {
      chat.upsertConversation(c);
    }
    setState(() {});
  }

  void _ensureTab(String tab) {
    if (tab == 'friends') {
      _friends ??= _pager<AylaUserPublic>(
        (String? cursor) => AylaUsersApi.listFriendsPageOf(cursor: cursor),
        (AylaUserPublic u) => u.id,
      );
    }
    if (tab == 'requests') {
      _friendRequests ??= _pager<AylaFriendRequest>(
        (String? cursor) => AylaUsersApi.listFriendRequestsPage(cursor: cursor),
        (AylaFriendRequest r) => r.id,
      );
      _invites ??= _pager<AylaGroupInvite>(
        (String? cursor) => AylaChatApi.listMyInvitesPage(cursor: cursor),
        (AylaGroupInvite i) => i.id,
      );
      _joinRequests ??= _pager<AylaGroupJoinRequest>(
        (String? cursor) => AylaChatApi.listManagedJoinRequestsPage(cursor: cursor),
        (AylaGroupJoinRequest r) => r.id,
      );
      _leaveNotices ??= _pager<AylaGroupMemberLeaveNotice>(
        (String? cursor) => AylaChatApi.listLeaveNoticesPage(cursor: cursor),
        (AylaGroupMemberLeaveNotice n) => n.id,
      );
    }
  }

  AylaSocialPage<T>? _pageOf<T>(AylaPagedList<T>? pager) {
    if (pager == null) return null;
    return AylaSocialPage<T>(
      items: pager.items,
      loading: pager.loading,
      error: pager.error,
      hasMore: pager.hasMore,
      loadMore: pager.loadMore,
      refresh: pager.refresh,
    );
  }

  Future<void> _act(
    String id,
    Future<void> Function() action,
    void Function() onDone,
  ) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      await action();
      onDone();
      unawaited(ref.read(badgesProvider).fetch());
    } catch (_) {
      // 处理失败静默（web 同）
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _openUserChat(String userId) async {
    if (userId.isEmpty) return;
    try {
      final String convId = await AylaUsersApi.openPrivateConversation(userId);
      if (!mounted || convId.isEmpty) return;
      widget.onSelect(convId);
    } catch (_) {
      // 打开私聊失败静默（web 同）
    }
  }

  Future<void> _removeFriend(AylaUserPublic user) async {
    if (_removingFriendId != null) return;
    setState(() => _removingFriendId = user.id);
    try {
      await AylaUsersApi.deleteFriend(user.id);
      _friends?.removeWhere((AylaUserPublic f) => f.id == user.id);
      unawaited(ref.read(badgesProvider).fetch());
    } catch (_) {
      // 解除好友失败静默（web 同）
    } finally {
      if (mounted) setState(() => _removingFriendId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaElysiaProfile? profile =
        ref.watch(elysiaProfileProvider).valueOrNull;
    final AylaElysiaProfile? entryProfile =
        (profile != null && profile.enabled) ? profile : null;
    final String? me = ref.read(authNotifierProvider).user?.id;
    final List<AylaRealtimeNotice> leaveNotices = ref
        .watch(noticesProvider)
        .ofKind(AylaRealtimeNoticeKind.groupMemberLeft);

    final AylaPagedList<AylaFriendRequest>? friendPager = _friendRequests;
    final AylaSocialPage<AylaFriendRequest>? friendPage =
        friendPager == null
            ? null
            : AylaSocialPage<AylaFriendRequest>(
                items: <AylaFriendRequest>[
                  for (final AylaFriendRequest r in friendPager.items)
                    if (me != null && r.toUser?.id == me && r.status == 'pending') r,
                ],
                loading: friendPager.loading,
                error: friendPager.error,
                hasMore: friendPager.hasMore,
                loadMore: friendPager.loadMore,
                refresh: friendPager.refresh,
              );

    return AylaWideMessagesSidebar(
      activeId: widget.activeId,
      onSelect: widget.onSelect,
      onTabChanged: _ensureTab,
      conversations: aylaSortPrivateByActivity<AylaConversationSummary>(
        _conversations?.items ?? const <AylaConversationSummary>[],
        ref.watch(chatStateProvider).conversationActivityAt,
        idOf: (AylaConversationSummary c) => c.id,
        pinnedOf: (AylaConversationSummary c) => c.isPinned ?? false,
      ),
      conversationsPage: _pageOf(_conversations),
      elysiaEntry: entryProfile == null
          ? null
          : AylaElysiaEntry(
              profile: entryProfile,
              onEnter: () => _openUserChat(entryProfile.userId ?? ''),
            ),
      elysiaUserId: profile?.userId,
      friendList: _friends?.items ?? const <AylaUserPublic>[],
      friendsPage: _pageOf(_friends),
      friendsLoading: _friends?.loading ?? false,
      onOpenUserChat: _openUserChat,
      onAvatarTap: (AylaUserPublic user) =>
          context.go('/user/${Uri.encodeComponent(user.id)}'),
      onRemoveFriend: _removeFriend,
      removingFriendId: _removingFriendId,
      requestBadge: ref.watch(badgesProvider).requestBadge,
      requestsPanel: AylaRequestsPanel(
        leaveNotices: _pageOf(_leaveNotices) ??
            const AylaSocialPage<AylaGroupMemberLeaveNotice>(),
        realtimeLeaveNotices: <AylaNoticeRow>[
          for (final AylaRealtimeNotice n in leaveNotices)
            AylaNoticeRow(
              title: n.title,
              detail: n.detail,
              onDismiss: () => ref.read(noticesProvider).dismiss(n.id),
            ),
        ],
        friendRequests:
            friendPage ?? const AylaSocialPage<AylaFriendRequest>(),
        invites: _pageOf(_invites) ?? const AylaSocialPage<AylaGroupInvite>(),
        joinRequests: _pageOf(_joinRequests) ??
            const AylaSocialPage<AylaGroupJoinRequest>(),
        // 宽屏侧栏的提示（`WideMessagesSidebar.tsx:267`；无句号）
        sectionHint: '好友申请、群邀请和入群申请',
        busyId: _busyId,
        isOnline: (AylaUserPublic u) => u.online,
        onDismissLeaveNotice: (String id) {
          unawaited(() async {
            try {
              await AylaChatApi.readLeaveNotice(id);
              _leaveNotices?.removeWhere(
                (AylaGroupMemberLeaveNotice n) => n.id == id,
              );
            } catch (_) {}
          }());
        },
        onFriendAction: (AylaFriendRequest r, bool accept) => _act(
          r.id,
          () => AylaUsersApi.actionFriendRequest(r.id, accept),
          () => _friendRequests?.removeWhere(
            (AylaFriendRequest item) => item.id == r.id,
          ),
        ),
        onInviteAction: (AylaGroupInvite inv, bool accept) => _act(
          inv.id,
          () => AylaChatApi.actionGroupInvite(inv.id, accept),
          () => _invites?.removeWhere(
            (AylaGroupInvite item) => item.id == inv.id,
          ),
        ),
        onJoinAction: (AylaGroupJoinRequest r, bool accept) => _act(
          r.id,
          () => AylaChatApi.actionJoinRequest(r.id, accept),
          () => _joinRequests?.removeWhere(
            (AylaGroupJoinRequest item) => item.id == r.id,
          ),
        ),
      ),
    );
  }
}

/// 认证消息相关的接收帧 → 认证列表需重新取页（web `MessagesPage.tsx:98–108`）。
bool aylaIsAuthRefreshFrame(String type) =>
    type == 'friend.request.new' ||
    type == 'friend.request.resolved' ||
    type == 'group.invite.new' ||
    type == 'group.request.new' ||
    type == 'group.request.resolved';
