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
/// 0. **群表情包键与面板已接**（2026-10-02）：web `MessageInput.tsx:88-89` 的
///    `isGroup`（群聊才有 members）同时门控 @ 与**群表情包按钮**；面板本身是
///    `EmojiPackPanel.tsx` 的既有件 [AylaEmojiPackPanel]，数据来自
///    `api/emoji.ts:33-35 / 37-39`（Flutter 侧 = [AylaEmojiApi]）。
///    ⚠️ **仅群聊**：私聊输入框（`private_chat_pane.dart` / `chat_support.dart`）
///    一律不传这两件，对齐 tsx:88-89「私信不显示表情包按钮」。
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
import '../core/api/emoji_api.dart';
import '../core/models/chat_message.dart';
import '../core/models/conversation.dart';
import '../core/models/emoji_item.dart' show AylaEmojiItem;
import '../core/models/subgroup.dart' show AylaSubGroup;
import '../state/auth_state.dart' show authNotifierProvider;
import '../state/chat_providers.dart';
import '../state/group_providers.dart';
import '../state/message_state.dart';
import '../state/paged_list.dart';
import '../state/subgroup_state.dart';
import '../theme/tokens.dart' show AylaCurves, AylaDurations, AylaSpacing;
import '../widgets/base/reveal.dart' show AylaRevealItem, AylaRevealMotion;
import '../widgets/chat/emoji_pack_panel.dart';
import '../widgets/chat/message_input.dart';
import '../widgets/chat/message_list.dart' show AylaMessageList;
import '../widgets/motion/panel_swap.dart'
    show AylaPanelSwap, AylaPanelSwapMode;
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

  /// 子群选择的「基线已确立」标志（web `GroupChat.tsx:103–110` 的 `selectionInitialized`）——
  /// 首次选中默认组那一帧**不算换场**，之后才随子群变化播动画。
  bool _subgroupSelectionInitialized = false;
  /// 已按某个「群:子群」组合取过历史（避免重复首屏请求）。
  String? _historyOwner;

  // ===================== 群表情包（web EmojiPackPanel + api/emoji.ts）=====================

  /// 包摘要加载中（web EmojiPackPanel.tsx:48-54 的 metadata.loaded 取反）。
  bool _emojiMetaLoading = false;

  /// 包摘要（null = 未建包 / 加载失败；web metadata.payload）。
  AylaGroupEmojiPackPayload? _emojiPack;

  /// 摘要错误（null = 无错；web metaError）。404「包未创建」**不进这里**。
  String? _emojiMetaError;

  /// 摘要作用域（群 + 子群）—— 换子群即重置（web tsx:44/86-93 的 scope 同义）。
  String? _emojiScope;

  /// 表情项分页（web usePagedMediaList）。
  AylaPagedList<AylaEmojiItem>? _emojiItems;

  /// 面板数据面。⚠️ **必须是可监听对象**：宽屏档的面板由 [AylaMessageInput] 插在
  /// **root Overlay** 里（message_input.dart:575-585），本页的 setState **不会**传到那份
  /// 子树（实测：数据到达后面板仍停在 summaryLoaded=false / items=0；
  /// 上传后 onReload 刷新也看不见）。用 [ValueNotifier] + [ValueListenableBuilder]
  /// 让 Overlay 内的那份自己订阅变化 —— 与 web 的 React state 直连 store 同效。
  final ValueNotifier<AylaEmojiPackData> _emojiData =
      ValueNotifier<AylaEmojiPackData>(const AylaEmojiPackData());

  /// 表情面板的宿主键。面板的开合状态（web MessageInput.tsx:84 的 `emojiOpen`）由
  /// [AylaMessageInput] 内部持有；本页只在「换子群」（tsx:143 的 `setEmojiOpen(false)`）
  /// 与「面板关闭钮」两处换掉这个键，把开合状态归零。
  Key _composerKey = UniqueKey();

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
    _emojiItems?.removeListener(_onChanged);
    _emojiItems?.dispose();
    _emojiItems = null;
    _emojiData.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // 表情列表（分页/加载态/错误）也挂在面板上 ⇒ 数据面每次变化都同步推送
    // （宽屏那份在 root Overlay 里，只靠本页 setState 传不到）。
    _publishEmojiData();
    setState(() {});
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

  // ===================== 群表情包（web EmojiPackPanel.tsx / api/emoji.ts）=====================

  /// 表情面板的**作用域**：群 + 子群 —— web `EmojiPackPanel.tsx:44` 的
  /// `scope = group-emoji:${userId}:${convId}`，Flutter 侧无跨实例缓存，
  /// 同一用户同一群下**再按子群**分（换子群要重新取，见 tsx:88-93 的重置分支）。
  String _emojiScopeKey(String? subgroupId) => '$groupId:${subgroupId ?? ''}';

  /// 摘要有无错误（web `metaError`）⇒ 上传权限兜底判据之一。
  bool get _emojiMetaLoaded => !_emojiMetaLoading && _emojiMetaError == null;

  /// 当前用户在群中的角色 —— web `MessageInput.tsx:117-120` 的 `myRole`
  /// （`groupRole ?? members.find(me).role`）：群聊路由传的是 `activeConv.my_role`。
  String? get _emojiMyRole {
    final AylaConversationSummary? conv =
        ref.read(chatStateProvider).byId(groupId);
    final AylaConversationMemberRole? role = conv?.myRole;
    if (role != null) return role.wire;
    final String? me = ref.read(authNotifierProvider).user?.id;
    if (me == null) return null;
    for (final AylaConversationMember m
        in conv?.members ?? const <AylaConversationMember>[]) {
      if (m.user.id == me) return m.role?.wire;
    }
    return null;
  }

  /// 换子群 / 首次进入 → 重置面板状态并拉摘要（web tsx:86-93 的 scope 分支）。
  ///
  /// 摘要是**子群无关**的（后端 `/emoji/groups/<conv_id>/pack/` 只认群），但仍按
  /// 「群:子群」重建分页列表 —— 与 web 的 `${scope}:${pack.id}` 分页身份同口径。
  void _syncEmojiScope(String? subgroupId) {
    final String scope = _emojiScopeKey(subgroupId);
    if (_emojiScope == scope) return;
    _emojiScope = scope;
    _emojiPack = null;
    _emojiMetaError = null;
    _emojiMetaLoading = true;
    _emojiItems?.removeListener(_onChanged);
    _emojiItems?.dispose();
    _emojiItems = AylaPagedList<AylaEmojiItem>(
      request: (String? cursor) => AylaEmojiApi.listGroupEmojiItemsPage(
        groupId,
        cursor: cursor,
        limit: 30, // web tsx:63 的 `limit: 30`
      ),
      keyOf: (AylaEmojiItem item) => item.id,
    )..addListener(_onChanged);
    _publishEmojiData(); // 先落空态（换子群立刻反映，不等网络）
    unawaited(_loadEmojiMeta());
  }

  /// 把当前投影推给 [_emojiData]（宽屏那份面板靠它更新，见字段注释）。
  void _publishEmojiData() => _emojiData.value = _buildEmojiData();

  /// 摘要加载（web `EmojiPackPanel.tsx:67-81` / `GroupInfo.tsx:222-242` 的同一分支）：
  /// **404「包未创建」= 空态**，不是错误；其它错误落 `metaError`。
  Future<void> _loadEmojiMeta() async {
    final String? scope = _emojiScope;
    if (scope == null) return;
    final AylaGroupEmojiPackLoad load =
        await AylaEmojiApi.loadGroupEmojiPackSummary(groupId);
    if (!mounted || _emojiScope != scope) return;
    setState(() {
      _emojiMetaLoading = false;
      _emojiPack = load.payload; // 404 ⇒ null（未建包）
      _emojiMetaError = load.error;
    });
    _publishEmojiData();
    // web tsx:64：`Boolean(payload)` 才取 items（未建包不请求列表）。
    if (load.payload != null) {
      await _emojiItems?.load();
    }
  }

  /// 上传/删除后重取摘要 + 刷新列表（web tsx:83-86 的 `refresh`）。
  Future<void> _reloadEmoji() async {
    final AylaGroupEmojiPackPayload? before = _emojiPack;
    await _loadEmojiMeta();
    if (!mounted) return;
    // web tsx:85：仅当 pack.id 未变才刷新列表（换包等价于换数据源）。
    if (_emojiPack?.packId == before?.packId) {
      await _emojiItems?.load();
    }
    _publishEmojiData();
  }

  /// 「加入群包」（web tsx:115 的 `addGroupEmojiItem(convId, uploaded.media_id)`）。
  ///
  /// 媒体已由 [AylaEmojiPackPanel] 内部按 `kind=emoji` 上传完成
  /// （Flutter 侧 = `AylaMediaActions.pickImages`）。
  Future<void> _addEmoji(String mediaId) async {
    await AylaEmojiApi.addGroupEmojiItem(groupId, mediaId);
  }

  /// 删除群表情（web tsx:149 的 `deleteGroupEmojiItem(convId, item.id)`）。
  Future<void> _deleteEmoji(String itemId) async {
    await AylaEmojiApi.deleteGroupEmojiItem(groupId, itemId);
  }

  /// 「发送表情」（web tsx:135-143 的 `sendMessage(convId, "", {type: emoji, mediaId}, subgroupId)`）。
  ///
  /// 复用群聊既有发送链：单媒体 emoji **不进** [AylaConversationRuntime.send]
  /// （那是「块/待上传媒体」口径），但 POST 出口、幂等键与 `subgroup_id` 判据完全同源
  /// （[aylaSubgroupIdParam]，与 useChat.ts 其余三个出口同一函数）。
  /// **不新增消息类型**（tsx:12-13 注释：群表情本质仍是图片/动图消息）。
  Future<void> _sendEmoji(String mediaId) async {
    final AylaChatMessage msg = await AylaChatApi.sendMessage(
      groupId,
      AylaCreateMessagePayload(
        type: AylaMessageType.emoji,
        content: '',
        mediaId: mediaId,
        idempotencyKey: aylaNewIdempotencyKey(),
        subgroupId: aylaSubgroupIdParam(_activeSubgroup?.id),
      ),
    );
    if (!mounted) return;
    // web useChat.ts:258 的 `upsertMessage`（WS message.new 按 seq 去重，不会重复）。
    ref.read(messageStateProvider).upsertMessage(groupId, msg);
  }

  /// 面板数据面投影（[AylaEmojiPackData] 契约由既有件定义）。
  ///
  /// ⚠️ 本地动作错误（发送/删除/上传失败）**不进**这里 —— [AylaEmojiPackPanel] 自己
  /// `setState(_error)` 渲染 `.emoji-pack-error`（与 web tsx:58 同口径）；
  /// 这里只表达「摘要」与「列表」两条**取数**链路的错误。
  AylaEmojiPackData _buildEmojiData() => AylaEmojiPackData(
        packId: _emojiPack?.packId,
        canUploadFromPack: _emojiPack?.canUpload,
        canDeleteFromPack: _emojiPack?.canDelete,
        summaryLoaded: _emojiMetaLoaded,
        summaryError: _emojiMetaError,
        items: _emojiItems?.items ?? const <AylaEmojiItem>[],
        itemsLoading: _emojiItems?.loading ?? false,
        itemsError: _emojiItems?.error,
        hasMore: _emojiItems?.hasMore ?? false,
      );

  /// 输入框内正常流向下展开的**窄屏**面板（web tsx:588-590 在 `.composer` 内）。
  ///
  /// ⚠️ 宽屏**不在这里**：`AylaMessageInput` 自己把 [AylaMessageInput.emojiPanel] 插到
  /// **root Overlay** 的 `Positioned(left: sp3, width: composerWidth - 2*sp3, bottom: 100% + 8)`
  /// （`message_input.dart:563-586`，对应 app.css 2186-2204 的
  /// `position: absolute; left/right sp3; bottom: calc(100% + 8px)`）——
  /// 同一个 [AylaEmojiPackPanel] 装配方式按 [AylaMessageInput.narrow] 切换，与 web 同构。
  /// 面板（[ValueListenableBuilder] 订阅 [_emojiData] —— 宽屏那份在 root Overlay 里，
  /// 靠这个通道拿到最新数据；窄屏那份在正常流里，两者行为一致）。
  Widget _emojiPanel({required bool narrow}) =>
      ValueListenableBuilder<AylaEmojiPackData>(
        valueListenable: _emojiData,
        builder: (BuildContext context, AylaEmojiPackData data, Widget? _) =>
            AylaEmojiPackPanel(
          narrow: narrow,
          myRole: _emojiMyRole,
          data: data,
          onClose: _closeEmojiPanel,
          onReload: _reloadEmoji,
          onLoadMore: () =>
              _emojiItems?.load(append: true) ?? Future<void>.value(),
          onAddEmoji: _addEmoji,
          onDeleteEmoji: _deleteEmoji,
          onSendEmoji: _sendEmoji,
        ),
      );

  /// 收起面板 —— 面板只负责「关」，开合状态在 [AylaMessageInput] 内部。
  ///
  /// 本页通过**换 composer 键**表达 web 的 `setEmojiOpen(false)`
  /// （tsx:589 面板的 `onClose`）：重建输入框 = 开合状态归零。
  void _closeEmojiPanel() => setState(() {
        _composerKey = UniqueKey();
      });

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

    // ---- 子群换场身份与门控（web `GroupChat.tsx:102–126`）----
    final String? activeSubgroupId = active?.id;
    // web `subgroupSelection = `${groupId}:${activeSubgroupId ?? "all"}``（tsx:102）。
    final String subgroupSelection = '$groupId:${activeSubgroupId ?? "all"}';
    // web `establishingSelection`（tsx:103–110）：**首次**选中默认组那一帧不算「变化」
    // ⇒ 只记基线、不播（否则每次进群都会白抖一次）。
    final bool establishingSelection =
        activeSubgroupId != null && !_subgroupSelectionInitialized;
    if (activeSubgroupId != null) _subgroupSelectionInitialized = true;
    // web `useTabPanelMotion` 的 `ready`（tsx:120–123）：缓存命中立即播；未命中等该子群的
    // 历史真正落入缓存后再播（`hasSelectedMessages || settledHistoryRevision === revision`）。
    final bool messagesReady = activeSubgroupId != null &&
        (visible.isNotEmpty || !(bucket?.loading ?? false));
    // 输入框换场（`usePanelSwapMotion`，tsx:126）：`active && !establishingSelection`。
    final bool composerReady = activeSubgroupId != null && !establishingSelection;

    // ---- 群表情包：作用域同步（面板的开合不在这里）----
    // ⚠️ 换子群时**由输入框自己收起面板**：[AylaMessageInput.didUpdateWidget] 在 draftKey
    // 变化时调 `_closeEmoji()`（message_input.dart:264-280，对应 web
    // `MessageInput.tsx:134-146` 的 `setEmojiOpen(false)`）；本页的 draftKey 含子群
    // （`aylaSubgroupDraftKey`）⇒ 换子群即收起 —— 本页**不需要**、也不应该在这里重建输入框
    // （在 build 期换 key 会让整棵 composer 子树重挂，属额外副作用）。
    // 本页只负责换作用域后拉该子群的摘要 / 列表。
    _syncEmojiScope(activeSubgroupId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          // 消息区入场（web `GroupChat.tsx:288–294`：`motion.div.chat-messages-motion`
          // + `variants={panelMotion ? panelVariants(reducedMotion, "right", "left") : undefined}`，
          // `GroupPage.tsx:332` 的 `<GroupChat … panelMotion />` 常开）
          // ⇒ **进场 x +20 → 0 + 淡入**，300ms `--auroraqua-ease-in-out`；离场 0 → x −20 + 淡出。
          // 离场在宽屏由「旧件立即卸载 + 新件入场」表达（与 web 的宿主 exit 为空一致），
          // 窄屏旧场景的淡出由 `group_page.dart` 的 `_AylaSceneFade` 承担。
          // ⚠️ 切场景（聊天 ⇄ 语音 / 直播 / 帖子 / 桌游）时本页会重挂 ⇒ 动画**重播**，
          // 这正是 web 的 `initial="enter"` 语义（`GroupPage.tsx:327–350` 的 renderScene 换件）。
          child: AylaRevealItem(
            fadeGlass: false,
            offset: const Offset(AylaRevealMotion.distance, 0), // +20 → 0（right 档）
            duration: AylaDurations.auroraqua, // 300ms
            curve: AylaCurves.auroraquaEaseInOut, // [0.42, 0, 0.58, 1]
            child: AylaPanelSwap(
              // 子群换场（web GroupChat.tsx:120-125 的 useTabPanelMotion
              // (subgroupSelection, ":scope > .message-list", ready, establishBaseline)）：
              // **就地重播** 300ms opacity 0 / x +20 到 1 / 0（easeInOut），
              // **不重挂**子树：草稿 / 滚动 owner / 消息窗口都不重建。
              identity: subgroupSelection,
              mode: AylaPanelSwapMode.tab,
              enabled: messagesReady,
              establishBaseline: establishingSelection,
              // 玻璃安全档：`AylaMessageList` 子树含玻璃（他人气泡 `.bubble-other`
              // 的 blur12 / 跳转标签 / 历史加载控件；空列表时反而无玻璃可谈 ——
              // 空态是纯文本、回底键被 `AnimatedOpacity(0)` 挡住不 paint）——
              // 整层 opacity 恒 1.0、只位移不淡入 ——
              // 否则切子群重播时 Impeller 拒绝「Opacity 祖先 + BackdropFilter」并刷屏
              //（处置与依据见 `widgets/base/reveal.dart` 文件头 + `panel_swap.dart` 的文件头）。
              fadeGlass: false,
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
          ),
        ),
        Stack(
          children: <Widget>[
            // 输入区入场（web `GroupChat.tsx:326–332`：`motion.div.group-chat-compose-area`
            // + `chat-composer-motion` + `variants={panelVariants(reducedMotion, "bottom")}`）
            // ⇒ **从下方 20px 上滑 + 淡入**，300ms `--auroraqua-ease-in-out`，宽窄屏同档，
            // reduced-motion 由 [AylaRevealItem] 内部直切。
            AylaRevealItem(
              fadeGlass: false,
              offset: const Offset(0, AylaRevealMotion.distance), // +20 → 0
              duration: AylaDurations.auroraqua, // 300ms
              curve: AylaCurves.auroraquaEaseInOut, // [0.42, 0, 0.58, 1]
              child: Padding(
                // ≥769：`margin: var(--sidebar-gutter)` + `.group-content .group-chat >
                // .group-chat-compose-area > .composer { margin-left: 0 }`
                // （auroraqua.css:346–359 的 `margin` / 361–368 的 `margin-left: 0`）
                // ⇒ 上/右/下各 12、左 0。
                // 效果：输入框**底沿与左列侧栏卡片底沿齐平**、右沿离视口 12（不贴底、不贴右），
                // 左沿与内容列左沿对齐（左列侧栏已自带同一 12 的 gutter）。
                // ≤768：`.composer` 没有任何 margin（app.css:3206 只改内距）⇒ 保持原内距补偿。
                //
                // ⚠️ 并发轮（私聊域）给 `AylaMessageInput` 加了 `gutter` 档（同为这 12px，
                // 由调用方传）。**本页不使用该档**：它属并发对话的未提交改动，此处保持本页
                // 自持外边距以免跨任务编译耦合；两处口径已核对为同一组数值
                // （`fromLTRB(0, 12, 12, 12)`），收口点见 19 号 §16.4 第 3 条。
                padding: narrow
                    ? const EdgeInsets.only(top: AylaSpacing.sp2)
                    : const EdgeInsets.only(
                        top: AylaSpacing.sidebarGutter,
                        right: AylaSpacing.sidebarGutter,
                        bottom: AylaSpacing.sidebarGutter,
                      ),
                  child: AylaPanelSwap(
                    // 输入框子群换场（web `GroupChat.tsx:126` 的
                    // `usePanelSwapMotion(subgroupSelection, ":scope > .composer",
                    // `active && !establishingSelection)`）：**同一 DOM 不重挂**
                    // （保住草稿 / 焦点），就地播 600ms 双段「下移淡出（y +20）→ 回位淡入」，
                    // 每段 easeOut —— 与消息区的 300ms 单段有意不同。
                    identity: subgroupSelection,
                    mode: AylaPanelSwapMode.swap,
                    enabled: composerReady,
                    // 玻璃安全档：`.composer` 顶层恒为 `AylaGlassSurface`
                    //（`message_input.dart:559/575` 窄宽两分支）⇒ 同上，只位移不淡入。
                    fadeGlass: false,
                    child: AylaMessageInput(
                      // 面板开合状态（`emojiOpen`）在输入框内部持有；换子群需收起时
                      // 本页换掉这个键（等价 web 的 `setEmojiOpen(false)`）。
                      key: _composerKey,
                      // ★ 群表情包键（web `MessageInput.tsx:464-476` 宽屏 /
                      // `:559-571` 窄屏，两处都是 `{isGroup && (<button
                      // aria-label="群表情包" onClick={() => setEmojiOpen(v => !v)}>)}`）。
                      // 群聊必开（本页只服务群聊 ⇒ isGroup 恒 true，tsx:88-89）；
                      // **私聊输入框一律不传这两件**（tsx:89 注释「私信不显示表情包按钮」）。
                      showEmojiButton: true,
                      // 同一个面板实例按 narrow 换装配：窄屏在 composer 内正常流向下展开
                      // （`message_input.dart:660-663`），宽屏由 AylaMessageInput 插 root
                      // Overlay 向上弹（`message_input.dart:563-586`）。
                      emojiPanel: _emojiPanel(narrow: narrow),
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
                      // 草稿按**会话 + 子群**隔离 —— web `MessageInput.tsx:90–91`：
                      // `const draftKey = isGroup ? `${convId}:${subgroupId ?? ""}` : convId`
                      // （群聊每个子群保留独立草稿）。此前恒传 `groupId` ⇒ 各子群共用一个
                      // 草稿槽，切子群时草稿串场（同源缺口，本轮一并修）。
                      draftKey: aylaSubgroupDraftKey(groupId, active?.id),
                      initialDraft: ref
                          .read(chatDraftsProvider)
                          .draftFor(aylaSubgroupDraftKey(groupId, active?.id)),
                      onDraftChanged: (String key, String serialized) =>
                          ref.read(chatDraftsProvider).setDraft(key, serialized),
                    ),
                  ),
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
