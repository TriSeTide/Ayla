/// 群内聊天子界面 —— web `pages/group/GroupChat.tsx`（424 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 打开会话 + 订阅 + 按**当前子群**拉历史（首屏 20） | 202–226（`loadHistory(..., sgId, isDefault)`） |
/// | 会话 metadata（未读序号完整） | 149–158 |
/// | 成员全量分页合并（`members_complete` 后不重复拉） | 163–194 |
/// | 爱莉身份（群内爱莉气泡判定） | 129–141 |
/// | 切子群只拉历史；未读由 MessageList 可视区**精确确认** | 262–266 + 309 |
/// | 子群切换条（仅窄屏且 >1 个子群；默认收起） | 334–407 |
/// | 子群禁言 ⇒ 输入框禁用 + 文案 | 271–275 + 417–419 |
/// | 长按头像 @ / 双击头像戳一戳 | 248–260 |
/// | 历史 403/404 ⇒ 清会话 + 回 `/group` | 228–237 |
///
/// ## 机制差异（登记）
/// 1. **群聊发送复用 [AylaConversationRuntime]**（`pages/chat_support.dart`）：web 的
///    `useChat.ts` 是全局面函数，Flutter 侧把「乐观插入 → 上传 → 发送 → 原地替换」
///    收在运行时类里；群聊**不调它的 `open()`**（那是私聊口径的历史/typing 路径），
///    历史与已读由本页按子群自管（`markReadExact` 换成带子群回执的版本）。
/// 2. **「对方正在输入」不订阅**（产品要求，tsx 注释 7 行）：与 web 一致，无偏离。
/// 3. **收藏消息的外部跳转**（`?msg=&seq=&subgroup=`，tsx 72–101）未接：群内跳转需要
///    路由 query 透传到本页，属收藏域批次；当前进入群聊不自动定位（不伪造定位成功）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/models/chat_message.dart';
import '../core/models/conversation.dart';
import '../core/models/subgroup.dart' show AylaSubGroup;
import '../state/auth_state.dart' show authNotifierProvider;
import '../state/chat_providers.dart';
import '../state/group_providers.dart';
import '../state/message_state.dart';
import '../state/subgroup_state.dart';
import '../theme/tokens.dart' show AylaSpacing;
import '../widgets/chat/message_input.dart';
import '../widgets/chat/message_list.dart' show AylaMessageList;
import '../widgets/group/group_chat_subgroup_bar.dart';
import 'chat_support.dart';

/// 消息是否属于某子群视图（web `useChat.ts:69–78` 的 `messageInSubgroup`）——
/// 默认组视图**含 `subgroup_id` 为 null 的旧消息**。
bool aylaMessageInSubgroup(
  AylaChatMessage msg,
  String? subgroupId, {
  bool isDefault = false,
}) {
  if (subgroupId == null) return true;
  if (isDefault) return msg.subgroupId == null || msg.subgroupId == subgroupId;
  return msg.subgroupId == subgroupId;
}

class GroupChatPage extends ConsumerStatefulWidget {
  const GroupChatPage({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends ConsumerState<GroupChatPage> {
  AylaConversationRuntime? _runtime;
  AylaChatMessage? _quote;
  bool _collapsed = true;
  /// 已按某个「群:子群」组合取过历史（避免重复首屏请求）。
  String? _historyOwner;

  String get groupId => widget.groupId;

  AylaSubGroupState get _subgroups => ref.read(subgroupStateProvider);

  @override
  void initState() {
    super.initState();
    _runtime = AylaConversationRuntime(
      conversationId: groupId,
      chatState: ref.read(chatStateProvider),
      messageState: ref.read(messageStateProvider),
      drafts: ref.read(chatDraftsProvider),
      badges: ref.read(badgesProvider),
      ws: ref.read(chatWsProvider),
      currentUserId: () => ref.read(authNotifierProvider).user?.id,
    )..addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    _runtime?.removeListener(_onChanged);
    final AylaConversationRuntime? runtime = _runtime;
    _runtime = null;
    scheduleMicrotask(() => runtime?.dispose());
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  AylaSubGroup? get _activeSubgroup {
    final String? id = _subgroups.activeSubgroupOf(groupId);
    if (id == null) return null;
    for (final AylaSubGroup sg in _subgroups.subgroupsOf(groupId)) {
      if (sg.id == id) return sg;
    }
    return null;
  }

  /// 进入群聊的取数（web tsx 149–199 的三个 effect）。
  Future<void> _bootstrap() async {
    ref.read(chatStateProvider).openConversation(groupId);
    ref.read(messageStateProvider).openBucket(groupId);
    ref.read(chatWsProvider).subscribe(<String>[groupId]);
    final AylaConversationSummary? conv =
        ref.read(chatStateProvider).byId(groupId);
    if (conv == null || conv.membersComplete != true) {
      unawaited(_loadMembers());
    }
    unawaited(() async {
      try {
        final AylaConversationSummary fresh =
            await AylaChatApi.getConversationMetadata(groupId);
        if (mounted) ref.read(chatStateProvider).upsertConversation(fresh);
      } catch (_) {
        // 拉不到：沿用目录摘要（不阻断聊天）。
      }
    }());
    await _loadHistory(subgroup: _activeSubgroup);
  }

  Future<void> _loadMembers() async {
    final List<AylaConversationMember> members = <AylaConversationMember>[];
    String? cursor;
    try {
      do {
        final AylaDirectoryPage<AylaConversationMember> page =
            await AylaChatApi.listConversationMembersPage(
          groupId,
          limit: 100,
          cursor: cursor,
        );
        members.addAll(page.results);
        cursor = page.nextCursor;
      } while (cursor != null);
    } catch (_) {
      // 成员拉取失败只缺头像/昵称，不阻断聊天（web 同）。
      return;
    }
    if (!mounted) return;
    final AylaConversationSummary? current =
        ref.read(chatStateProvider).byId(groupId);
    if (current == null) return;
    ref.read(chatStateProvider).upsertConversation(
          current.copyWith(members: members, membersComplete: true),
        );
  }

  /// 首屏/切子群历史（web `loadHistory`，首屏 20 条）。
  Future<void> _loadHistory({AylaSubGroup? subgroup, bool first = true}) async {
    final String? sgId = subgroup?.id;
    final String owner = '$groupId:${sgId ?? 'all'}';
    if (first && _historyOwner == owner) return;
    _historyOwner = owner;
    ref.read(messageStateProvider).setLoading(groupId, true);
    try {
      final List<AylaChatMessage> list = await AylaChatApi.listMessages(
        groupId,
        limit: kAylaInitialHistoryLimit,
        subgroupId: sgId,
      );
      if (!mounted) return;
      ref.read(messageStateProvider).prependHistory(
            groupId,
            list,
            hasMore: list.length >= kAylaInitialHistoryLimit,
          );
    } catch (error) {
      if (!mounted) return;
      // 403 / 404：清会话并回主页（web tsx 228–237）。
      final String text = error.toString();
      if (text.contains('403') || text.contains('404')) {
        ref.read(chatStateProvider).removeConversation(groupId);
        ref.read(messageStateProvider).reset();
        context.go('/group');
      }
    } finally {
      if (mounted) ref.read(messageStateProvider).setLoading(groupId, false);
    }
  }

  Future<void> _loadMore() async {
    final AylaMessageBucket? bucket =
        ref.read(messageStateProvider).bucketOf(groupId);
    final AylaSubGroup? subgroup = _activeSubgroup;
    if (bucket == null || bucket.loading || !bucket.hasMore) return;
    int? minSeq;
    for (final AylaChatMessage m in bucket.messages) {
      if (m.seq > 0 &&
          aylaMessageInSubgroup(
            m,
            subgroup?.id,
            isDefault: subgroup?.isDefault ?? false,
          )) {
        minSeq = m.seq;
        break;
      }
    }
    if (minSeq == null) return;
    ref.read(messageStateProvider).setLoading(groupId, true);
    try {
      final List<AylaChatMessage> list = await AylaChatApi.listMessages(
        groupId,
        beforeSeq: minSeq,
        limit: kAylaHistoryPageLimit,
        subgroupId: subgroup?.id,
      );
      if (!mounted) return;
      ref.read(messageStateProvider).prependHistory(
            groupId,
            list,
            hasMore: list.length >= kAylaHistoryPageLimit,
          );
    } catch (_) {
      // 失败保留已加载内容（下次上拉重试）。
    } finally {
      if (mounted) ref.read(messageStateProvider).setLoading(groupId, false);
    }
  }

  /// 精确已读（web `markMessageReadExact` = `useChat.ts:684–700`）：带**子群回执**。
  Future<void> _markReadExact(AylaChatMessage msg) async {
    final String? actor = ref.read(authNotifierProvider).user?.id;
    final AylaMessageReadReceipt receipt =
        await AylaChatApi.markMessageRead(groupId, msg.id, exact: true);
    if (!mounted || actor != ref.read(authNotifierProvider).user?.id) return;
    ref.read(messageStateProvider).markReadByMe(groupId, msg.id);
    final String? sgId = receipt.subgroupId ??
        msg.subgroupId ??
        _defaultSubgroupId();
    if (sgId != null) {
      aylaApplySubgroupReadReceipt(
        subgroupState: ref.read(subgroupStateProvider),
        chatState: ref.read(chatStateProvider),
        messageState: ref.read(messageStateProvider),
        convId: groupId,
        subgroupId: sgId,
        markedSeqs: receipt.markedSeqs ?? <int>[msg.seq],
      );
    } else {
      ref.read(chatStateProvider).markReadSeqs(groupId, <int>[msg.seq]);
    }
    unawaited(ref.read(badgesProvider).fetch());
  }

  String? _defaultSubgroupId() {
    for (final AylaSubGroup sg in _subgroups.subgroupsOf(groupId)) {
      if (sg.isDefault) return sg.id;
    }
    return null;
  }

  Future<void> _recall(AylaChatMessage msg) async {
    if (msg.status == AylaMessageStatus.recalled) return;
    try {
      await AylaChatApi.recallMessage(groupId, msg.id);
      if (mounted) ref.read(messageStateProvider).setRecalled(groupId, msg.id);
    } catch (_) {
      // 撤回失败静默（web tsx 239–246）。
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(messageStateProvider);
    ref.watch(chatStateProvider);
    final AylaSubGroupState subgroupState = ref.watch(subgroupStateProvider);
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    final AylaConversationSummary? conv =
        ref.watch(chatStateProvider).byId(groupId);
    final AylaSubGroup? active = _activeSubgroup;
    final List<AylaChatMessage> all =
        ref.watch(messageStateProvider).messagesOf(groupId);
    final List<AylaChatMessage> visible = <AylaChatMessage>[
      for (final AylaChatMessage m in all)
        if (aylaMessageInSubgroup(
          m,
          active?.id,
          isDefault: active?.isDefault ?? false,
        ))
          m,
    ];
    final List<AylaSubGroup> subgroups = subgroupState.subgroupsOf(groupId);
    final AylaMessageBucket? bucket =
        ref.watch(messageStateProvider).bucketOf(groupId);
    final String? elysiaId =
        ref.watch(elysiaProfileProvider).valueOrNull?.userId;
    final String? me = ref.watch(authNotifierProvider).user?.id;
    final AylaConversationMemberRole? myRole = conv?.myRole;
    final bool isSubgroupMuted = active?.muted == true &&
        myRole != AylaConversationMemberRole.owner &&
        myRole != AylaConversationMemberRole.admin;
    final bool myMuted = conv?.myMuted == true;
    final List<int> unreadSeqs =
        subgroupState.unreadSeqsOf(groupId, active?.id);
    final Set<int> unreadSet = unreadSeqs.toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AylaMessageList(
            messages: visible,
            currentUserId: me,
            conversation: conv,
            elysiaUserId: elysiaId,
            hasMore: bucket?.hasMore ?? false,
            loading: bucket?.loading ?? false,
            onLoadMore: _loadMore,
            onQuote: (AylaChatMessage m) => setState(() => _quote = m),
            onMarkRead: (AylaChatMessage m, bool exact) async {
              if (exact) await _markReadExact(m);
            },
            onRecall: (AylaChatMessage m) => unawaited(_recall(m)),
            onRetry: (AylaChatMessage m) => _runtime?.retry(m),
            onRemove: (AylaChatMessage m) => _runtime?.remove(m),
            onCancel: (AylaChatMessage m) => _runtime?.cancel(m),
            onPoke: (String userId) async {
              try {
                await AylaChatApi.sendPoke(groupId, userId);
              } catch (_) {
                // 戳一戳失败静默（web tsx 254–260）。
              }
            },
            onLoadUntilSeq: (int seq) async =>
                await _runtime?.loadUntilSeq(seq) ?? false,
            unreadSeqs: unreadSeqs,
            mentionUnreadSeqs: <int>[
              for (final int seq in conv?.mentionUnreadSeqs ?? const <int>[])
                if (unreadSet.contains(seq)) seq,
            ],
            replyUnreadSeqs: <int>[
              for (final int seq in conv?.replyUnreadSeqs ?? const <int>[])
                if (unreadSet.contains(seq)) seq,
            ],
            onAtBottomChanged: (bool atBottom) =>
                ref.read(messageStateProvider).setViewerAtBottom(groupId, atBottom),
          ),
        ),
        Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp2),
              child: AylaMessageInput(
                onSubmit: (AylaMessageInputSubmission submission) {
                  _runtime?.send(submission);
                  if (_quote != null) setState(() => _quote = null);
                },
                quote: _quote,
                onQuoteClear: () => setState(() => _quote = null),
                members: conv?.members ?? const <AylaConversationMember>[],
                groupId: groupId,
                subgroupId: active?.id,
                disabled: isSubgroupMuted || active == null || myMuted,
                disabledHint: myMuted
                    ? '你已被禁言'
                    : isSubgroupMuted
                        ? '该子群已禁言，仅群主/管理员可发言'
                        : null,
                narrow: narrow,
                draftKey: groupId,
                initialDraft: ref.read(chatDraftsProvider).draftFor(groupId),
                onDraftChanged: (String key, String serialized) =>
                    ref.read(chatDraftsProvider).setDraft(key, serialized),
              ),
            ),
            // 子群切换条：窄屏且 >1 个子群（web tsx 334）。
            if (narrow && subgroups.length > 1)
              Positioned(
                left: 0,
                right: 0,
                top: -32,
                child: AylaGroupChatSubgroupBar(
                  subgroups: <AylaGroupChatSubgroupTab>[
                    for (final AylaSubGroup sg in subgroups)
                      AylaGroupChatSubgroupTab(
                        id: sg.id,
                        name: sg.name,
                        muted: sg.muted == true,
                        unread: subgroupState.unreadOf(groupId, sg.id),
                      ),
                  ],
                  activeId: active?.id,
                  collapsed: _collapsed,
                  onCollapsedChanged: (bool next) =>
                      setState(() => _collapsed = next),
                  onSelect: (AylaGroupChatSubgroupTab tab) {
                    ref
                        .read(subgroupStateProvider)
                        .setActiveSubgroup(groupId, tab.id);
                    AylaSubGroup? picked;
                    for (final AylaSubGroup sg in subgroups) {
                      if (sg.id == tab.id) picked = sg;
                    }
                    unawaited(_loadHistory(subgroup: picked));
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}
