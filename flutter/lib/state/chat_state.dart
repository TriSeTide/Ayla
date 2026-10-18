/// chat 全局状态 —— web `stores/chat.ts`（295 行）的 Flutter 等价物。
///
/// ## 逐条对应
/// | 本类 | web |
/// |---|---|
/// | [conversations] / [setConversations] | `chat.ts:101–123`（置顶优先 + 同数据不重渲染） |
/// | [upsertConversation] | `chat.ts:124–151`（详情无 peer ⇒ 从 members 推导；不用 null 覆盖已有对端） |
/// | [bumpGroupActivity] / [bumpConversationActivity] | `chat.ts:85–99`（**单调**，只前进不回退） |
/// | [bumpUnread] | `chat.ts:182–216`（seq 驱动的可追踪未读序号投影） |
/// | [markReadSeqs] / [clearUnread] / [decrementUnread] | `chat.ts:218–258` |
/// | [setLastMessage] / [setPin] / [removeConversation] | `chat.ts:160–180` |
/// | [aylaToggleConversationPin] / [aylaHideConversation] | `ConversationMoreMenu.tsx:91–120` + `ServerRail.tsx:75–85` |
/// | [adjustPostUnread] | `chat.ts:260–267`（群未读帖子数增减；非群会话不动，下限 0） |
/// | [aylaSortPrivateByActivity] | `chat.ts:275–288`（置顶 → 活跃时间 → 稳定原序） |
///
/// ## 未实现（登记）
/// - `loading` / `error` / `lastFetched`：web 由 `useSocialPage` 写入；Flutter 的列表加载态归
///   `AylaPagedList`（`state/paged_list.dart`）⇒ 本类不做第二份加载态；
/// - `isChatStale(60s)` 的跨页缓存短路：Flutter 无跨页缓存（同 `paged_list.dart` 的登记）。
///
/// ## `adjustPostUnread` 的消费者（2026-10-11 补齐）
/// web 里它**只**被帖子域的两条 WS 分支调用：`post.created`（非作者 +1，`chat.ts:779–788`）
/// 与 `post.viewed`（本人 + 去重后 −1，`chat.ts:826–835`）；
/// Flutter 侧同源消费方 = `core/ws/posts_frames.dart` 的 [AylaPostsFramesBridge]。
/// 浏览上报（REST）**不减红点** —— 与 web 同：红点递减只走 WS 一条路径，
/// 否则同一条浏览会被 REST 响应与群组/本人两条 WS 广播重复递减（web 已修 Bug #3，
/// 见 `docs/post_views_read_state.md`）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/chat_api.dart';
import '../core/models/conversation.dart';

/// 会话列表状态（会话摘要缓存 + 未读投影 + 活跃排序）。
class AylaChatState extends ChangeNotifier {
  List<AylaConversationSummary> _conversations =
      const <AylaConversationSummary>[];
  String? _activeConversationId;
  final Map<String, int> _groupActivityAt = <String, int>{};
  final Map<String, int> _conversationActivityAt = <String, int>{};

  /// 已加载目录页与单项详情的描述符缓存（**不代表完整会话目录**，web 同）。
  List<AylaConversationSummary> get conversations =>
      List<AylaConversationSummary>.unmodifiable(_conversations);

  /// 当前打开的会话（null = 无）。
  String? get activeConversationId => _activeConversationId;

  /// 群「最近收到新内容」的单调时间戳（ms）。
  Map<String, int> get groupActivityAt =>
      Map<String, int>.unmodifiable(_groupActivityAt);

  /// 私信「最近收到新内容」的单调时间戳（ms）。
  Map<String, int> get conversationActivityAt =>
      Map<String, int>.unmodifiable(_conversationActivityAt);

  /// 按 id 取会话（null = 未加载）。
  AylaConversationSummary? byId(String id) {
    for (final AylaConversationSummary c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 整表替换（列表页取页后）。置顶优先；同数据（9 个可见字段全等）不触发重渲染。
  void setConversations(List<AylaConversationSummary> list) {
    final List<AylaConversationSummary> sorted = _sorted(list);
    final bool same = _conversations.length == sorted.length &&
        _sameVisible(_conversations, sorted);
    if (same && _conversations.isNotEmpty) return;
    _conversations = sorted;
    notifyListeners();
  }

  /// 收到新内容 → 单调 bump（取 max，避免事件乱序/时钟回退把卡片往回排）。
  void bumpGroupActivity(String groupId, [int? at]) {
    final int next = at ?? DateTime.now().millisecondsSinceEpoch;
    if (next <= (_groupActivityAt[groupId] ?? 0)) return;
    _groupActivityAt[groupId] = next;
    notifyListeners();
  }

  /// 私信活跃 bump（语义同 [bumpGroupActivity]）。
  void bumpConversationActivity(String convId, [int? at]) {
    final int next = at ?? DateTime.now().millisecondsSinceEpoch;
    if (next <= (_conversationActivityAt[convId] ?? 0)) return;
    _conversationActivityAt[convId] = next;
    notifyListeners();
  }

  /// 插入 / 合并一条会话摘要（web `upsertConversation`）。
  void upsertConversation(AylaConversationSummary conv) {
    final AylaConversationSummary normalized = _normalize(conv);
    final int index =
        _conversations.indexWhere((AylaConversationSummary c) => c.id == normalized.id);
    if (index < 0) {
      _conversations = _sorted(<AylaConversationSummary>[normalized, ..._conversations]);
    } else {
      final AylaConversationSummary prev = _conversations[index];
      final AylaConversationSummary merged = normalized.copyWith(
        // 详情接口（ConversationDetail）无 peer：不得用 null 覆盖已有对端
        peer: prev.peer,
        // 分页元数据 members_complete=false ⇒ 不得覆盖已加载的完整成员
        members: normalized.membersComplete == false &&
                prev.membersComplete != false &&
                prev.members.isNotEmpty
            ? prev.members
            : null,
        membersComplete: normalized.membersComplete == false &&
                prev.membersComplete != false &&
                prev.members.isNotEmpty
            ? prev.membersComplete
            : null,
      );
      _conversations = _sorted(<AylaConversationSummary>[
        for (int i = 0; i < _conversations.length; i++)
          i == index ? merged : _conversations[i],
      ]);
    }
    // `directory_activity_at` → 单调活跃时间（`chat.ts:145–150`）。
    final int at = DateTime.tryParse(normalized.directoryActivityAt ?? '')
            ?.millisecondsSinceEpoch ??
        0;
    if (normalized.type == AylaConversationType.group) {
      if (at > (_groupActivityAt[normalized.id] ?? 0)) {
        _groupActivityAt[normalized.id] = at;
      }
    } else if (normalized.type == AylaConversationType.private) {
      if (at > (_conversationActivityAt[normalized.id] ?? 0)) {
        _conversationActivityAt[normalized.id] = at;
      }
    }
    notifyListeners();
  }

  /// 从列表移除（退出群 / 被移除 / 群状态为空）。
  void removeConversation(String id) {
    final List<AylaConversationSummary> next = <AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        if (c.id != id) c,
    ];
    if (next.length == _conversations.length) return;
    _conversations = next;
    if (_activeConversationId == id) _activeConversationId = null;
    notifyListeners();
  }

  /// 置顶 / 取消置顶（本人视图）。
  void setPin(String convId, bool pinned) {
    _conversations = _sorted(<AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        c.id == convId ? c.copyWith(isPinned: pinned) : c,
    ]);
    notifyListeners();
  }

  /// 更新最新一条消息预览（WS `message.new` / `message.poke` / `elysia.reply`）。
  void setLastMessage(String convId, AylaLastMessagePreview preview) {
    _conversations = <AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        c.id == convId ? c.copyWith(lastMessage: preview) : c,
    ];
    notifyListeners();
  }

  /// 收到 `message.new` → 追加未读序号（web `bumpUnread`）。
  ///
  /// - [seq] 为 null = 旧事件只带会话 id（保留「当前会话不累加」的历史兼容语义）；
  /// - `unread_seqs_complete == false` 且 seq 不晚于已见 last_message.seq ⇒ **不累加**
  ///   （摘要只含计数、省略序号数组的旧后端，不能凭它推断未读）。
  void bumpUnread(
    String convId, {
    int? seq,
    bool mention = false,
    bool reply = false,
  }) {
    if (seq == null && _activeConversationId == convId) return;
    bool changed = false;
    final List<AylaConversationSummary> next = <AylaConversationSummary>[];
    for (final AylaConversationSummary c in _conversations) {
      if (c.id != convId) {
        next.add(c);
        continue;
      }
      final List<int> unread = c.unreadSeqs;
      final bool complete = c.unreadSeqsComplete ?? true;
      if (seq != null &&
          !complete &&
          seq <= (c.lastMessage?.seq ?? 0) &&
          !unread.contains(seq)) {
        next.add(c);
        continue;
      }
      final List<int> nextUnread =
          seq != null && !unread.contains(seq) ? _sortedSeqs(<int>[...unread, seq]) : unread;
      final List<int> mentionSeqs = c.mentionUnreadSeqs;
      final List<int> nextMention = mention && seq != null && !mentionSeqs.contains(seq)
          ? _sortedSeqs(<int>[...mentionSeqs, seq])
          : mentionSeqs;
      final List<int> replySeqs = c.replyUnreadSeqs;
      final List<int> nextReply = reply && seq != null && !replySeqs.contains(seq)
          ? _sortedSeqs(<int>[...replySeqs, seq])
          : replySeqs;
      next.add(c.copyWith(
        unreadCount: seq != null && complete
            ? nextUnread.length
            : c.unreadCount +
                (seq == null || !unread.contains(seq) ? 1 : 0),
        unreadSeqs: seq != null ? nextUnread : c.unreadSeqs,
        mentionUnreadSeqs: seq != null ? nextMention : c.mentionUnreadSeqs,
        mentionUnreadCount: seq != null && complete
            ? nextMention.length
            : (c.mentionUnreadCount ?? 0) +
                (mention && seq != null && !mentionSeqs.contains(seq) ? 1 : 0),
        replyUnreadSeqs: seq != null ? nextReply : c.replyUnreadSeqs,
      ));
      changed = true;
    }
    if (!changed) return;
    _conversations = next;
    notifyListeners();
  }

  /// 清空未读计数（**服务端已读确认后**才调用）。
  void clearUnread(String convId) {
    _conversations = <AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        c.id == convId ? c.copyWith(unreadCount: 0) : c,
    ];
    notifyListeners();
  }

  /// 子群标已读后：未读按已读条数递减（下限 0）并移除明确确认的序号。
  void decrementUnread(String convId, int marked, {List<int>? seqs}) {
    _conversations = <AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        c.id == convId
            ? c.copyWith(
                unreadCount:
                    (c.unreadCount - marked) < 0 ? 0 : c.unreadCount - marked,
                unreadSeqs: seqs == null
                    ? c.unreadSeqs
                    : <int>[
                        for (final int seq in c.unreadSeqs)
                          if (!seqs.contains(seq)) seq,
                      ],
              )
            : c,
    ];
    notifyListeners();
  }

  /// 从会话未读投影中移除已确认阅读的消息（保留其他特殊未读）。
  ///
  /// web `chat.ts:239–258`：`unread_seqs_complete === false`（摘要只含计数）时**按命中的
  /// 已读条数递减**（下限 0），完整时直接用序号数组长度 —— 两档不可互换。
  void markReadSeqs(String convId, List<int> seqs) {
    final Set<int> read = seqs.toSet();
    _conversations = <AylaConversationSummary>[
      for (final AylaConversationSummary c in _conversations)
        c.id == convId
            ? c.copyWith(
                unreadCount: (c.unreadSeqsComplete ?? true)
                    ? _removeSeqs(c.unreadSeqs, read).length
                    : _minusFloor0(
                        c.unreadCount,
                        _countIn(c.unreadSeqs, read),
                      ),
                unreadSeqs: _removeSeqs(c.unreadSeqs, read),
                mentionUnreadCount: (c.unreadSeqsComplete ?? true)
                    ? _removeSeqs(c.mentionUnreadSeqs, read).length
                    : _minusFloor0(
                        c.mentionUnreadCount ?? 0,
                        _countIn(c.mentionUnreadSeqs, read),
                      ),
                mentionUnreadSeqs: _removeSeqs(c.mentionUnreadSeqs, read),
                replyUnreadSeqs: _removeSeqs(c.replyUnreadSeqs, read),
              )
            : c,
    ];
    notifyListeners();
  }

  /// 群未读帖子数增减 —— web `adjustPostUnread`（`chat.ts:260–267`）。
  ///
  /// ```ts
  /// adjustPostUnread: (convId, delta) => set((state) => ({
  ///   conversations: state.conversations.map((c) => {
  ///     if (c.id !== convId || c.type !== "group") return c;
  ///     const next = Math.max(0, (c.post_unread_count ?? 0) + delta);
  ///     return { ...c, post_unread_count: next };
  ///   }),
  /// }))
  /// ```
  ///
  /// 逐条对应：① **非群会话不动**（`type !== "group"`）；② 下限 0（`Math.max(0, …)`）；
  /// ③ 未加载的会话静默不改（map 命中不到就是 no-op —— Flutter 侧同：找不到即早退，
  /// **不凭空造一条摘要**）。
  ///
  /// 消费者是帖子域的 WS 帧桥（见文件头说明）。浏览上报（REST）**不走这里**。
  void adjustPostUnread(String convId, int delta) {
    bool changed = false;
    final List<AylaConversationSummary> next = <AylaConversationSummary>[];
    for (final AylaConversationSummary c in _conversations) {
      if (c.id != convId || c.type != AylaConversationType.group) {
        next.add(c);
        continue;
      }
      // web 用 `?? 0` 兜旧后端缺失字段的情形；Flutter 模型同口径。
      final int current = c.postUnreadCount ?? 0;
      final int adjusted = current + delta;
      final int value = adjusted < 0 ? 0 : adjusted;
      if (value == current) {
        next.add(c);
        continue;
      }
      next.add(c.copyWith(postUnreadCount: value));
      changed = true;
    }
    if (!changed) return;
    _conversations = next;
    notifyListeners();
  }

  /// 打开会话（**只登记视图**；未读必须由服务端已读确认后的 [clearUnread] 清除）。
  void openConversation(String id) {
    if (_activeConversationId == id) return;
    _activeConversationId = id;
    notifyListeners();
  }

  /// 关闭当前会话（离开私聊窗口）。
  void closeConversation() {
    if (_activeConversationId == null) return;
    _activeConversationId = null;
    notifyListeners();
  }

  /// 登出 / 切用户。
  void reset() {
    _conversations = const <AylaConversationSummary>[];
    _activeConversationId = null;
    _groupActivityAt.clear();
    _conversationActivityAt.clear();
    notifyListeners();
  }

  // ---- 内部 ----

  /// 归一（web `toSummary`）：`peer` 缺失时按 members 推导对端。
  AylaConversationSummary _normalize(AylaConversationSummary conv) {
    if (conv.peer != null || !conv.isPrivate || conv.members.isEmpty) return conv;
    return conv.copyWith(peer: conv.members.first.user);
  }

  static List<AylaConversationSummary> _sorted(List<AylaConversationSummary> list) {
    final List<AylaConversationSummary> pinned = <AylaConversationSummary>[
      for (final AylaConversationSummary c in list)
        if (c.isPinned == true) c,
    ];
    final List<AylaConversationSummary> rest = <AylaConversationSummary>[
      for (final AylaConversationSummary c in list)
        if (c.isPinned != true) c,
    ];
    return <AylaConversationSummary>[...pinned, ...rest];
  }

  static bool _sameVisible(
    List<AylaConversationSummary> a,
    List<AylaConversationSummary> b,
  ) {
    for (int i = 0; i < a.length; i++) {
      final AylaConversationSummary x = a[i];
      final AylaConversationSummary y = b[i];
      final bool same = x.id == y.id &&
          x.title == y.title &&
          x.avatar == y.avatar &&
          x.unreadCount == y.unreadCount &&
          (x.postUnreadCount ?? 0) == (y.postUnreadCount ?? 0) &&
          x.memberCount == y.memberCount &&
          x.isPinned == y.isPinned &&
          (x.lastMessage?.seq ?? -1) == (y.lastMessage?.seq ?? -1) &&
          (x.lastMessage?.content ?? '') == (y.lastMessage?.content ?? '');
      if (!same) return false;
    }
    return true;
  }

  static List<int> _sortedSeqs(List<int> seqs) {
    final List<int> copy = List<int>.of(seqs);
    copy.sort();
    return List<int>.unmodifiable(copy);
  }

  static List<int> _removeSeqs(List<int> seqs, Set<int> read) =>
      List<int>.unmodifiable(<int>[
        for (final int seq in seqs)
          if (!read.contains(seq)) seq,
      ]);

  /// `seqs` 中命中 [read] 的条数。
  static int _countIn(List<int> seqs, Set<int> read) {
    int n = 0;
    for (final int seq in seqs) {
      if (read.contains(seq)) n++;
    }
    return n;
  }

  /// `Math.max(0, value - delta)`。
  static int _minusFloor0(int value, int delta) {
    final int next = value - delta;
    return next < 0 ? 0 : next;
  }
}

/// 私信列表按「最近活跃」排序（web `chat.ts:275–288`）：置顶优先 → 活跃时间新→旧 → 稳定原序。
List<T> aylaSortPrivateByActivity<T extends Object>(
  List<T> list,
  Map<String, int> activityAt, {
  required String Function(T item) idOf,
  required bool Function(T item) pinnedOf,
}) {
  final List<T> copy = List<T>.of(list);
  // Dart 的 `List.sort` **不保证稳定** ⇒ 用索引做末位比较键，等价 JS 的稳定排序。
  final Map<T, int> order = <T, int>{
    for (int i = 0; i < copy.length; i++) copy[i]: i,
  };
  copy.sort((T a, T b) {
    final bool pa = pinnedOf(a);
    final bool pb = pinnedOf(b);
    if (pa != pb) return pa ? -1 : 1;
    final int ta = activityAt[idOf(a)] ?? 0;
    final int tb = activityAt[idOf(b)] ?? 0;
    if (ta != tb) return tb - ta;
    return (order[a] ?? 0) - (order[b] ?? 0);
  });
  return copy;
}

// ======================= 会话置顶 / 删除的两步式动作 =======================

/// 置顶 / 取消置顶（web `ConversationMoreMenu.tsx:91–103` 与 `ServerRail.tsx:75–85`）。
///
/// ## 为什么放在这里（而不是各页面各写一遍）
/// web 的两处调用点是**同一段代码复制两次**：
/// ```ts
/// chatApi.togglePinConversation(id, next)
///   .then(() => useChatStore.getState().setPin(id, next))
///   .catch(() => { /* 置顶失败静默 */ });
/// ```
/// 语义三条，必须逐条照抄：
/// 1. **成功才更新**（`.then` 里才 setPin）—— 不能先乐观改；
/// 2. **失败静默**：不弹错、不回滚、不重抛（调用方不该再包一层 try/catch）；
/// 3. 置顶态由 WS 的会话摘要与会话详情各自再来一次（`upsertConversation`），
///    本方法只负责本人视图的即时反映。
///
/// 返回 `bool`：是否成功更新了本地状态。**仅**给定向测试与可观测性用，
/// 生产调用点不必消费（web 的 Promise 也没有被消费）。
///
/// [chatState] 传 null 时退化为「不更新任何本地状态」——但生产路径**恒传**
/// 当前 provider 实例；null 分支只为让本函数在无 store 的纯函数测试里可用。
Future<bool> aylaToggleConversationPin(
  AylaChatState? chatState,
  String convId,
  bool pinned,
) async {
  try {
    await AylaChatApi.togglePinConversation(convId, pinned: pinned);
  } catch (_) {
    // ConversationMoreMenu.tsx:99–101 / ServerRail.tsx:80–84：置顶失败**静默**。
    return false;
  }
  chatState?.setPin(convId, pinned);
  return true;
}

/// 从本人列表删除（隐藏）会话（web `ConversationMoreMenu.tsx:110–120`）。
///
/// ## 语义（逐条照 web `doDelete`）
/// ```ts
/// chatApi.hideConversation(id)
///   .then(() => useChatStore.getState().removeConversation(id))
///   .catch(() => { /* 删除会话失败静默 */ });
/// ```
/// 1. **成功才移除**（不能先本地移除）；
/// 2. **失败静默**（web 原文注释「删除会话失败静默」）；
/// 3. 只动 `chatState`；列表投影（social record / 分页器）由
///    `AylaSocialTracking` 的 `reconcileCached` 自动跟随（web 同一条链：
///    `useChatStore.subscribe → reconcileCached`，见 `stores/social.ts:114–116`）。
///
/// 注意：本方法**不做二次确认**——确认是 UI 层的事（[AylaConversationMoreMenu]
/// 内部按 `ConversationMoreMenu.tsx:105–120` 弹 [AylaConfirmDialog]）。
Future<bool> aylaHideConversation(
  AylaChatState? chatState,
  String convId,
) async {
  try {
    await AylaChatApi.hideConversation(convId);
  } catch (_) {
    // ConversationMoreMenu.tsx:117–119：删除会话失败**静默**。
    return false;
  }
  chatState?.removeConversation(convId);
  return true;
}

/// 把置顶态写回**页面本地的分页投影**（Flutter 侧特有的一步，web 不需要）。
///
/// ## 为什么 Flutter 要多这一步
/// web 的会话列表读的就是**被对账的那份 social record**：
/// `setPin` 改 `useChatStore.conversations` ⇒ `ensureSocialTracking` 的
/// `useChatStore.subscribe`（`stores/social.ts:114–116`）⇒ `reconcileCached`
/// 用新实例替换同 id 条目 ⇒ 列表跟着变。
/// Flutter 侧 `/messages` 页（含宽屏左列宿主）持有的是**页面私有**
/// [AylaPagedList]（见 `messages_page.dart:104` 的登记），不在那条对账链上
/// ⇒ 只调 [aylaToggleConversationPin] 会让「置顶态在 store 里改了、屏幕上的行没变」。
/// 本函数就是这一页的 `reconcileCached` 等价物：按 id 就地替换成带新 isPinned 的实例。
///
/// 主页 / 群页**不需要**它：那两处读的是共享 social record，自动跟随。
List<AylaConversationSummary> aylaApplyPinToProjection(
  List<AylaConversationSummary> items,
  String convId,
  bool pinned,
) =>
    <AylaConversationSummary>[
      for (final AylaConversationSummary c in items)
        c.id == convId ? c.copyWith(isPinned: pinned) : c,
    ];

/// 从页面本地分页投影里移除一条（[aylaApplyPinToProjection] 的删除版）。
List<AylaConversationSummary> aylaRemoveFromProjection(
  List<AylaConversationSummary> items,
  String convId,
) =>
    <AylaConversationSummary>[
      for (final AylaConversationSummary c in items)
        if (c.id != convId) c,
    ];
