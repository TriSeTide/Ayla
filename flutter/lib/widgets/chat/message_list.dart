/// 消息滚动区（`components/chat/MessageList.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMessageList] | `MessageList.tsx:1006–1124`（滚动区 + 跳转标签 + 回底键） |
/// | 时间分组（> 5 分钟）/ 时间格式 | tsx 24（`GROUP_GAP_MS`）、49–54（`formatTime`：`YYYY-MM-DD HH:mm`）、56–62（`shouldGroup`） |
/// | 戳一戳文案 | tsx 64–76（`pokeLabel`：「A戳了戳B」，自己归一为「我」，target 缺名回退对端名） |
/// | 段预览 / 引用预览 | `utils/segment.ts:11–37`（`SEGMENT_PLACEHOLDER` 仅 image/video，其余 `[媒体]`；mention → `@昵称`）+ tsx 372–391（无 segments 时按 `MEDIA_TYPE_LABEL` 兜底；text 用 `content \|\| "…"`） |
/// | 贴底容差 / 回底键判据 | tsx 26（`BOTTOM_TOLERANCE = 40`）、533–534（`distanceToBottom > clientHeight` 才显示） |
/// | 高亮 | `.mention-jump-highlight`（1.6s 粉框辉光闪一次，app.css 965–973） |
/// | 跳转标签 | `.message-jump-tags` / `-above` / `-below` / `.message-jump-mention`（911–962）；文案见 tsx 985–987 |
/// | 回底键 | `.message-jump-bottom`（44 圆玻璃钮 + `is-visible` 淡入位移；868–908） |
/// | 时间分隔 | `.time-divider`（左右 1px 线 + utility 12 / ls .3；990–1010） |
/// | 戳一戳胶囊 | `.msg-poke` / `.msg-poke-pill`（`rgba(126,149,189,.14)` 底 + `.22` 边 + blur8；1014–1037） |
/// | 历史控制 | `.message-history-control`（min-h 40）/ `.load-more-btn` / `.message-history-spinner`（829–865） |
/// | 列宽 | `.message-column { max-width: 960px; margin: 0 auto }`（820–826） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **不做 DOM 窗口化**：web 手动把缓存投影成「至多 200 条」窗口（U16 边界，`MESSAGE_RENDER_WINDOW_LIMIT`）
///    是为 DOM 性能；Flutter 的 `ListView.builder` 天然懒构建（只建可见项）⇒ 同一目标已满足，
///    不复制窗口簿记（否则会引入 web 特有的窗口滑动可见变化）；
/// 2. **滚动锚定用 `reverse: true` 表达**：web 是正向列表 + `PendingPrependAnchor` 手工补偿
///    `scrollTop`（含 `overflow-anchor: none`）；Flutter 侧用聊天标准做法把列表反转
///    （`offset 0` = 底部）⇒ 历史前插天然不移动视口，无需两阶段锚点状态机；
/// 3. **视口高度判定用 `ScrollPosition.viewportDimension`**（不是内容 Stack 尺寸，同 §6.39 修正）；
/// 4. **「可见即已读」用有界近似**：web 用 `IntersectionObserver(threshold 0.6)` 逐条精确判定；
///    Flutter 无内置等价物 ⇒ 只在**未读区间边界附近**的项挂可见性回报器
///    （绑祖先 `ScrollPosition` + 矩形求交 ≥ .6，同库内轮播卡手法），滚动停止时上报；
/// 5. **跳转标签的方向判定**：目标项已构建时用实测矩形（与 web 同口径）；被回收时按
///    「目标 seq 是否大于当前消息尾部」判定（web 有窗口首尾 seq 可比，Flutter 无窗口 ⇒ 有界近似）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/conversation.dart';
import '../../core/models/user_public.dart';
import '../../theme/app_icons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import 'message_bubble.dart';
import '../base/reveal.dart';

/// 时间分组间隔（web `GROUP_GAP_MS = 5 * 60 * 1000`）。
const Duration kAylaMessageGroupGap = Duration(minutes: 5);

/// 贴底容差（web `BOTTOM_TOLERANCE = 40`）。
const double kAylaMessageBottomTolerance = 40;

/// 跳转高亮时长（`.mention-jump-highlight` 的 `1.6s`）。
const Duration kAylaMessageJumpHighlight = Duration(milliseconds: 1600);

/// `formatTime`（tsx 49–54）：`YYYY-MM-DD HH:mm`；无效时间返回空串。
String aylaMessageListTime(String iso) {
  final DateTime? d = DateTime.tryParse(iso);
  if (d == null) return '';
  final DateTime local = d.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}';
}

/// `shouldGroup`（tsx 56–62）：与前一条间隔 > 5 分钟（或无法解析）时插时间分隔。
bool aylaShouldGroup(AylaChatMessage? prev, AylaChatMessage curr) {
  if (prev == null) return true;
  final DateTime? a = DateTime.tryParse(prev.createdAt);
  final DateTime? b = DateTime.tryParse(curr.createdAt);
  if (a == null || b == null) return false;
  return b.difference(a) > kAylaMessageGroupGap;
}

/// `pokeLabel`（tsx 64–76）。
String aylaPokeLabel(
  AylaChatMessage message,
  Map<String, String> memberNames,
  String? currentUserId,
  String peerName,
) {
  final bool senderSelf =
      currentUserId != null && message.senderId == currentUserId;
  final String senderName =
      senderSelf ? '我' : (memberNames[message.senderId] ?? '');
  final bool targetSelf =
      currentUserId != null && message.content == currentUserId;
  final String targetName = targetSelf
      ? '我'
      : (memberNames[message.content] ?? peerName);
  return '${senderName.isEmpty ? '有人' : senderName}戳了戳'
      '${targetName.isEmpty ? '对方' : targetName}';
}

/// `segmentPreview`（`utils/segment.ts:24–37`）：text 拼接、mention → `@昵称`、
/// 媒体段按 `SEGMENT_PLACEHOLDER`（仅 image/video 有专名，其余 `[媒体]`）。
String? aylaSegmentPreview(List<AylaMediaSegment> segments) {
  if (segments.isEmpty) return null;
  final StringBuffer out = StringBuffer();
  for (final AylaMediaSegment seg in segments) {
    switch (seg.type) {
      case AylaSegmentType.text:
        out.write(seg.text);
      case AylaSegmentType.mention:
        final String label = seg.userNickname ??
            seg.userUsername ??
            seg.name ??
            '未知用户';
        out.write('@$label');
      case AylaSegmentType.image:
        out.write('[图片]');
      case AylaSegmentType.video:
        out.write('[视频]');
    }
  }
  return out.toString();
}

/// tsx 372–391 的 `quotePreview` 单条规则（无 segments 时的类型兜底表）。
String aylaQuotePreview(AylaChatMessage m) {
  if (m.type == AylaMessageType.text) {
    return m.content.isEmpty ? '…' : m.content;
  }
  final String? fromSegments = aylaSegmentPreview(m.segments);
  if (fromSegments != null) return fromSegments;
  return switch (m.type) {
    AylaMessageType.image => '[图片]',
    AylaMessageType.voice => '[语音]',
    AylaMessageType.file => '[文件]',
    AylaMessageType.emoji => '[表情]',
    AylaMessageType.video => '[视频]',
    _ => '[消息]',
  };
}

/// 跳转标签（tsx 629–648 的 `tagTarget`）。
class AylaJumpTag {
  const AylaJumpTag({
    required this.kind,
    required this.seq,
    required this.count,
  });

  /// `unread` / `mention` / `reply`。
  final String kind;
  final int seq;
  final int count;

  String get label => switch (kind) {
        'unread' => '$count 条新消息',
        'mention' => '@我 $count',
        _ => '回复 $count',
      };

  String get ariaLabel => switch (kind) {
        'unread' => '跳转到 $count 条未读消息',
        'mention' => '跳转到 $count 条 @我的消息',
        _ => '跳转到 $count 条回复消息',
      };
}

/// 消息滚动区。
class AylaMessageList extends StatefulWidget {
  const AylaMessageList({
    super.key,
    required this.messages,
    required this.currentUserId,
    this.conversation,
    this.elysiaUserId,
    this.hasMore = false,
    this.loading = false,
    this.onLoadMore,
    this.onQuote,
    this.onRecall,
    this.onRetry,
    this.onRemove,
    this.onCancel,
    this.onMarkRead,
    this.onMarkConversationRead,
    this.onMentionSender,
    this.onPoke,
    this.onLoadUntilSeq,
    this.externalJump,
    this.onExternalJumpHandled,
    this.unreadSeqs = const <int>[],
    this.mentionUnreadSeqs = const <int>[],
    this.replyUnreadSeqs = const <int>[],
  });

  /// 消息（**时间升序**；渲染时内部反转）。
  final List<AylaChatMessage> messages;

  final String? currentUserId;
  final AylaConversationSummary? conversation;

  /// 爱莉 profile 的 user.id：匹配即爱莉专属气泡。
  final String? elysiaUserId;

  final bool hasMore;
  final bool loading;

  /// 更早历史（web：先扩窗口，触及缓存最早端才走 before_seq API ⇒ Flutter 无窗口 ⇒ 直接调）。
  final Future<void> Function()? onLoadMore;

  final void Function(AylaChatMessage msg)? onQuote;
  final void Function(AylaChatMessage msg)? onRecall;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;
  final void Function(AylaChatMessage msg)? onCancel;

  /// 已读上报（`exact` = 精确到该条，引用跳转路径用）。
  final Future<void> Function(AylaChatMessage msg, bool exact)? onMarkRead;

  /// 普通未读标签批量已读（到指定 seq，排除特殊未读消息 id）。
  final Future<void> Function(int throughSeq, List<String> excludeIds)?
      onMarkConversationRead;

  final void Function(String userId, String name)? onMentionSender;
  final void Function(String targetUserId)? onPoke;

  /// 目标不在缓存时按 seq 加载（web `onLoadUntilSeq`）。
  final Future<bool> Function(int seq)? onLoadUntilSeq;

  /// 外部跳转（收藏消息定位）。
  final ({String messageId, int seq})? externalJump;
  final void Function()? onExternalJumpHandled;

  final List<int> unreadSeqs;
  final List<int> mentionUnreadSeqs;
  final List<int> replyUnreadSeqs;

  @override
  State<AylaMessageList> createState() => _AylaMessageListState();
}

class _AylaMessageListState extends State<AylaMessageList> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  bool _atBottom = true;
  bool _farFromBottom = false;
  String? _highlightId;
  Timer? _highlightTimer;
  String? _activeActionsId;
  Set<String> _justArrived = <String>{};
  List<String> _prevIds = <String>[];
  bool _baselined = false;
  bool _loadInFlight = false;
  String? _handledJumpKey;
  int _tick = 0; // 方向判定需要随滚动刷新

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _prevIds = widget.messages.map((AylaChatMessage m) => m.id).toList();
    _baselined = true;
  }

  @override
  void didUpdateWidget(covariant AylaMessageList old) {
    super.didUpdateWidget(old);
    _syncNewMessages(old.messages);
    _handleExternalJump();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyOf(String id) => _keys.putIfAbsent(id, () => GlobalKey());

  /// 差分出「刚到达」的消息（web `justArrivedIds`，用于 frost-rise 入场）。
  void _syncNewMessages(List<AylaChatMessage> previous) {
    final List<String> ids =
        widget.messages.map((AylaChatMessage m) => m.id).toList();
    if (!_baselined) {
      _baselined = true;
      _prevIds = ids;
      return;
    }
    final Set<String> prevSet = _prevIds.toSet();
    final Set<String> arrived = <String>{};
    for (int i = math.max(0, previous.length - 1); i < ids.length; i++) {
      if (!prevSet.contains(ids[i])) arrived.add(ids[i]);
    }
    _prevIds = ids;
    if (arrived.isNotEmpty) {
      setState(() => _justArrived = arrived);
      // 贴底时新消息到达 → 跟随到底（web：`atBottomRef` 为真才 `scrollToBottom`）
      if (_atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    if (!pos.hasPixels || !pos.hasViewportDimension) return;
    // `reverse: true` ⇒ pixels = 距底部距离（0 = 贴底）
    final bool atBottom = pos.pixels <= kAylaMessageBottomTolerance;
    final bool far = pos.pixels > pos.viewportDimension;
    if (atBottom != _atBottom || far != _farFromBottom) {
      setState(() {
        _atBottom = atBottom;
        _farFromBottom = far;
        _tick++;
      });
    }
    // 触底（顶部 = 更早历史）→ 加载更多
    if (pos.pixels >= pos.maxScrollExtent - 400 && widget.hasMore) {
      _requestOlder();
    }
  }

  Future<void> _requestOlder() async {
    if (_loadInFlight || widget.loading || !widget.hasMore) return;
    _loadInFlight = true;
    setState(() => _atBottom = false);
    try {
      await widget.onLoadMore?.call();
    } finally {
      _loadInFlight = false;
    }
  }

  // ======================= 跳转 =======================

  Future<void> jumpToMessage(AylaChatMessage target, String kind) async {
    GlobalKey key = _keyOf(target.id);
    if (key.currentContext == null && widget.onLoadUntilSeq != null) {
      final bool loaded = await widget.onLoadUntilSeq!(target.seq);
      if (!loaded) return;
      if (!mounted) return;
      await Future<void>.delayed(Duration.zero);
      key = _keyOf(target.id);
    }
    if (!mounted) return;
    final BuildContext? ctx = key.currentContext;
    if (ctx != null && ctx.mounted) {
      // web：滚动到目标并**居中**（`scrollToMessageAndHighlight`）
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    _setHighlight(target.id);
    if (kind != 'unread') {
      await widget.onMarkRead?.call(target, true);
    }
  }

  void _setHighlight(String id) {
    _highlightTimer?.cancel();
    setState(() => _highlightId = id);
    _highlightTimer = Timer(kAylaMessageJumpHighlight, () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  void _handleExternalJump() {
    final ({String messageId, int seq})? jump = widget.externalJump;
    if (jump == null) return;
    final String key = '${widget.conversation?.id ?? ''}:${jump.messageId}:${jump.seq}';
    if (_handledJumpKey == key) return;
    final AylaChatMessage? target = widget.messages
        .cast<AylaChatMessage?>()
        .firstWhere((AylaChatMessage? m) => m?.id == jump.messageId,
            orElse: () => null);
    if (target == null) return;
    _handledJumpKey = key;
    widget.onExternalJumpHandled?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(jumpToMessage(target, 'reply'));
    });
  }

  /// 引用跳转（tsx 764–780）：优先按 id，其次按 seq（可能需加载）。
  Future<void> _handleQuoteJump(AylaChatMessage reply) async {
    final String? targetId = reply.replyTo;
    if (targetId != null) {
      final AylaChatMessage? target = widget.messages
          .cast<AylaChatMessage?>()
          .firstWhere((AylaChatMessage? m) => m?.id == targetId,
              orElse: () => null);
      if (target != null) {
        await jumpToMessage(target, 'reply');
        return;
      }
    }
    final int? seq = reply.replyToSeq;
    if (seq == null) return;
    final AylaChatMessage? bySeq = _findBySeq(seq);
    if (bySeq != null) {
      await jumpToMessage(bySeq, 'reply');
      return;
    }
    if (widget.onLoadUntilSeq != null) {
      final bool loaded = await widget.onLoadUntilSeq!(seq);
      if (!loaded) return;
      final AylaChatMessage? loaded2 = _findBySeq(seq);
      if (loaded2 != null) await jumpToMessage(loaded2, 'reply');
    }
  }

  AylaChatMessage? _findBySeq(int seq) {
    for (final AylaChatMessage m in widget.messages) {
      if (m.seq == seq) return m;
    }
    return null;
  }

  // ======================= 跳转标签 =======================

  List<AylaJumpTag> get _tags {
    final List<AylaJumpTag> out = <AylaJumpTag>[];
    if (widget.unreadSeqs.isNotEmpty) {
      out.add(AylaJumpTag(
        kind: 'unread',
        seq: widget.unreadSeqs.first,
        count: widget.unreadSeqs.length,
      ));
    }
    if (widget.mentionUnreadSeqs.isNotEmpty) {
      out.add(AylaJumpTag(
        kind: 'mention',
        seq: widget.mentionUnreadSeqs.last,
        count: widget.mentionUnreadSeqs.length,
      ));
    }
    if (widget.replyUnreadSeqs.isNotEmpty) {
      out.add(AylaJumpTag(
        kind: 'reply',
        seq: widget.replyUnreadSeqs.last,
        count: widget.replyUnreadSeqs.length,
      ));
    }
    return out;
  }

  /// 方向判定（tsx 820–842）：目标已构建 → 实测矩形与视口比较；否则按 seq 与尾部比较。
  ///
  /// [tick] 参与依赖：滚动时自增 ⇒ 方向随滚动重算（对齐 web `tagDirection` 的
  /// `scrollTick` 依赖项；本件在滚动时 `setState` 触发重建）。
  String _tagDirection(AylaJumpTag tag, int tick) {
    assert(tick >= 0, 'tick 恒非负：仅用于在滚动时驱动重算');
    final AylaChatMessage? target = _findBySeq(tag.seq);
    if (target != null) {
      final BuildContext? ctx = _keys[target.id]?.currentContext;
      final RenderObject? box = ctx?.findRenderObject();
      final RenderObject? viewport =
          _scroll.hasClients ? _scroll.position.context.storageContext.findRenderObject() : null;
      if (box is RenderBox && box.hasSize && viewport is RenderBox && viewport.hasSize) {
        final Rect nodeRect = box.localToGlobal(Offset.zero) & box.size;
        final Rect elRect = viewport.localToGlobal(Offset.zero) & viewport.size;
        if (nodeRect.bottom < elRect.top) return 'above';
        if (nodeRect.top > elRect.bottom) return 'below';
        final double targetCenter = nodeRect.center.dy;
        final double viewportCenter = elRect.center.dy;
        return targetCenter <= viewportCenter ? 'above' : 'below';
      }
    }
    // 被回收/不在缓存：按 seq 与最新一条比较（有界近似，见文件头差异 5）
    final int? lastSeq =
        widget.messages.isEmpty ? null : widget.messages.last.seq;
    if (lastSeq != null && tag.seq > lastSeq) return 'below';
    return 'above';
  }

  Future<void> _handleJumpTag(AylaJumpTag tag) async {
    final AylaChatMessage? target = _findBySeq(tag.seq);
    if (target == null) {
      if (widget.onLoadUntilSeq != null) {
        final bool loaded = await widget.onLoadUntilSeq!(tag.seq);
        if (!loaded) return;
        final AylaChatMessage? loaded2 = _findBySeq(tag.seq);
        if (loaded2 == null) return;
        await jumpToMessage(loaded2, tag.kind);
      }
      return;
    }
    await jumpToMessage(target, tag.kind);
    if (tag.kind == 'unread') {
      // 普通未读标签：批量已读到该 seq，排除特殊未读（tsx 856–880）
      final List<String> exclude = <String>[
        for (final int seq in <int>[
          ...widget.mentionUnreadSeqs,
          ...widget.replyUnreadSeqs,
        ])
          if (_findBySeq(seq) case final AylaChatMessage m) m.id,
      ];
      await widget.onMarkConversationRead?.call(tag.seq, exclude);
    }
  }

  // ======================= 渲染 =======================

  bool get _isGroup => widget.conversation?.type == AylaConversationType.group;

  Map<String, String> get _memberNames {
    final Map<String, String> map = <String, String>{};
    for (final AylaConversationMember m
        in widget.conversation?.members ?? const <AylaConversationMember>[]) {
      map[m.user.id] = m.user.displayName ?? '';
    }
    return map;
  }

  Map<String, ({String? avatar, String label})> get _memberAvatars {
    final Map<String, ({String? avatar, String label})> map =
        <String, ({String? avatar, String label})>{};
    for (final AylaConversationMember m
        in widget.conversation?.members ?? const <AylaConversationMember>[]) {
      map[m.user.id] = (
        avatar: m.user.avatar,
        label: m.user.displayName ?? '',
      );
    }
    return map;
  }

  /// 引用预览表（tsx 379–391）。
  Map<String, String> get _quotePreview {
    final Map<String, String> map = <String, String>{};
    for (final AylaChatMessage m in widget.messages) {
      map[m.id] = aylaQuotePreview(m);
    }
    return map;
  }

  Widget _column(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960), // `.message-column`
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final List<AylaChatMessage> messages = widget.messages;
    final List<Widget> rows = <Widget>[];

    // 历史控制（原顺序在顶部 ⇒ reverse 后在列表末尾）
    if (widget.hasMore || widget.loading) {
      rows.add(_column(_historyControl()));
    }
    for (int i = 0; i < messages.length; i++) {
      final AylaChatMessage m = messages[i];
      final bool grouped = aylaShouldGroup(i > 0 ? messages[i - 1] : null, m);
      rows.add(_column(_row(m, grouped)));
    }
    if (messages.isEmpty && !widget.loading) {
      rows.add(_column(_empty()));
    }

    final List<AylaJumpTag> tags = _tags;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ListView.builder(
            controller: _scroll,
            reverse: true, // 见文件头差异 2：前插历史不移动视口
            padding: const EdgeInsets.all(AylaSpacing.sp6), // `.message-scroll`
            itemCount: rows.length,
            itemBuilder: (BuildContext context, int index) =>
                rows[rows.length - 1 - index],
          ),
        ),
        // 跳转标签（`.message-jump-tags` 上下两条）
        Positioned(
          left: 0,
          right: 0,
          top: AylaSpacing.sp3,
          child: _tagRow(tags, 'above'),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: AylaSpacing.sp3,
          child: _tagRow(tags, 'below'),
        ),
        // 回底键（`.message-jump-bottom`）
        Positioned(
          right: AylaSpacing.sp6,
          bottom: AylaSpacing.sp6,
          child: _jumpBottomButton(),
        ),
      ],
    );
  }

  Widget _row(AylaChatMessage m, bool grouped) {
    final Map<String, String> names = _memberNames;
    final Map<String, ({String? avatar, String label})> avatars =
        _memberAvatars;
    final bool isSelf = m.senderId == widget.currentUserId;
    final String peerName = widget.conversation?.peer?.displayName ?? '';
    final GlobalKey key = _keyOf(m.id);
    final bool justArrived = _justArrived.contains(m.id);
    final bool highlighted = m.id == _highlightId;

    final Widget inner = m.type == AylaMessageType.poke
        // 戳一戳：居中提示（非气泡）；到达动画与历史同路径（tsx 1028–1046）
        ? _pokeRow(m, names, peerName, justArrived: justArrived)
        : AylaMessageBubble(
            msg: m,
            isSelf: isSelf,
            isElysia: widget.elysiaUserId != null &&
                m.senderId == widget.elysiaUserId,
            justArrived: justArrived,
            senderName:
                _isGroup && !isSelf ? names[m.senderId] : null,
            senderAvatarUrl: avatars[m.senderId]?.avatar,
            senderAvatarLabel: avatars[m.senderId]?.label,
            currentUserId: widget.currentUserId,
            actionsOpen: _activeActionsId == m.id,
            onToggleActions: () => setState(() {
              _activeActionsId = _activeActionsId == m.id ? null : m.id;
            }),
            quoteText: m.replyTo == null
                ? null
                : (_quotePreview[m.replyTo] ?? '引用的消息'),
            onQuote:
                widget.onQuote == null ? null : (AylaChatMessage _) => widget.onQuote!(m),
            onQuoteJump: m.replyTo == null && m.replyToSeq == null
                ? null
                : (AylaChatMessage _) => _handleQuoteJump(m),
            jumpedRecalled: highlighted && m.status == AylaMessageStatus.recalled,
            onRecall: widget.onRecall == null ||
                    !aylaCanRecall(m, widget.currentUserId)
                ? null
                : (AylaChatMessage _) => widget.onRecall!(m),
            onRetry: widget.onRetry == null || !m.sendFailed
                ? null
                : (AylaChatMessage _) => widget.onRetry!(m),
            onRemove: widget.onRemove == null || !m.sendFailed
                ? null
                : (AylaChatMessage _) => widget.onRemove!(m),
            onCancel: widget.onCancel == null ||
                    !m.pending ||
                    m.uploadProgress == null
                ? null
                : (AylaChatMessage _) => widget.onCancel!(m),
            onMentionSender: widget.onMentionSender,
            onPokeSender: widget.onPoke == null
                ? null
                : (String senderId) {
                    // 群聊：戳被双击的成员；私聊：双击任意头像都戳向对端（tsx 1069–1077）
                    if (_isGroup) {
                      widget.onPoke!(senderId);
                    } else if (widget.conversation?.peer != null) {
                      widget.onPoke!(widget.conversation!.peer!.id);
                    }
                  },
            shareGroupId: _isGroup ? widget.conversation?.id : null,
          );

    return KeyedSubtree(
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (grouped) _timeDivider(m),
          if (highlighted)
            _JumpHighlight(child: inner)
          else
            inner,
        ],
      ),
    );
  }

  /// `.time-divider`（app.css 990–1010）：左右 1px 线 + utility 12 居中。
  Widget _timeDivider(AylaChatMessage m) {
    final String label = aylaMessageListTime(m.createdAt);
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp2),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider(height: 1, color: Color(0x4D7E95BD))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.utility,
                fontSize: 12,
                letterSpacing: 0.3,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          const Expanded(child: Divider(height: 1, color: Color(0x4D7E95BD))),
        ],
      ),
    );
  }

  /// `.msg-poke` + `.msg-poke-pill`（app.css 1014–1037）。
  Widget _pokeRow(
    AylaChatMessage m,
    Map<String, String> names,
    String peerName, {
    required bool justArrived,
  }) {
    final Widget pill = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp1,
      ),
      decoration: BoxDecoration(
        color: const Color(0x247E95BD), // rgba(126,149,189,.14)
        border: Border.all(color: const Color(0x387E95BD)), // .22
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        aylaPokeLabel(m, names, widget.currentUserId, peerName),
        style: const TextStyle(
          fontFamily: AylaFonts.utility,
          fontSize: 13,
          letterSpacing: 0.2,
          color: AylaColors.textSecondary,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (justArrived)
            // `.msg-poke-arrive .msg-poke-pill { animation: frost-rise var(--dur-fast) }`
            AylaRevealItem(
              duration: AylaDurations.fast,
              offset: Offset(0, AylaRevealMotion.distance),
              child: pill,
            )
          else
            pill,
        ],
      ),
    );
  }

  /// `.message-history-control`（829–865）。
  Widget _historyControl() {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Center(
        child: widget.loading
            ? AylaGlassSurface(
                radiusOverride: AylaRadii.pill,
                shadow: const <BoxShadow>[],
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp3,
                  vertical: AylaSpacing.sp1,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AylaSpacing.sp2),
                    Text(
                      '正在加载更早消息',
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontSize: 13,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            : TextButton(
                onPressed: () => _requestOlder(),
                child: const Text('加载更早消息'),
              ),
      ),
    );
  }

  /// `.empty-chat`。
  Widget _empty() {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp8,
      ),
      child: Text(
        '还没有消息，说点什么吧',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: AylaFonts.body,
          fontSize: 14,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }

  /// `.message-jump-tags` 的一侧（`.message-jump-mention` 胶囊）。
  Widget _tagRow(List<AylaJumpTag> tags, String direction) {
    final List<AylaJumpTag> visible = <AylaJumpTag>[
      for (final AylaJumpTag t in tags)
        if (_tagDirection(t, _tick) == direction) t,
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      children: <Widget>[
        for (int i = 0; i < visible.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: AylaSpacing.sp2),
          Center(
            child: GestureDetector(
              onTap: () => _handleJumpTag(visible[i]),
              child: Semantics(
                button: true,
                label: visible[i].ariaLabel,
                // `.message-jump-mention`（app.css 940–958）：
                // `padding: sp1 sp4` + `1px solid var(--glow-500)` + pill +
                // `background: var(--glass-bg-strong)` + `backdrop-filter: blur(18px) saturate(1.4)`
                // + `box-shadow: var(--glow-shadow)` + 13/700 `--grape-700`
                // ⇒ 复用 AylaGlassSurface（材质/模糊/内高光走公共件），边改描 gl-500 1px。
                child: AylaGlassSurface(
                  strong: true,
                  blur: AylaGlass.blurNav,
                  radiusOverride: AylaRadii.pill,
                  shadow: AylaShadows.glow,
                  borderOverride: Border.all(color: AylaColors.glow500),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AylaSpacing.sp4,
                    vertical: AylaSpacing.sp1,
                  ),
                  child: Text(
                    visible[i].label,
                    style: const TextStyle(
                      fontFamily: AylaFonts.body,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AylaColors.grape700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// `.message-jump-bottom`（44 圆玻璃钮；`is-visible` 淡入 + 上移 8）。
  Widget _jumpBottomButton() {
    return AnimatedOpacity(
      key: const ValueKey<String>('message-jump-bottom'),
      opacity: _farFromBottom ? 1 : 0,
      duration: AylaDurations.fast,
      curve: AylaCurves.easeOut,
      child: AnimatedSlide(
        // ⚠️ `AnimatedSlide` 的基准是**直接 child 尺寸**（44×44）⇒ 1/… 无意义；
        // 这里用 8/44 表达 `translateY(8px)`（skill「百分比基准」条：能算出确定值就用确定值）
        offset: _farFromBottom ? Offset.zero : const Offset(0, 8 / 44),
        duration: AylaDurations.fast,
        curve: AylaCurves.easeOut,
        child: IgnorePointer(
          ignoring: !_farFromBottom,
          child: Semantics(
            button: true,
            label: '回到底部并恢复实时消息跟随',
            child: GestureDetector(
              onTap: () {
                if (_scroll.hasClients) {
                  _scroll.animateTo(
                    0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
              },
              child: AylaGlassSurface(
                radiusOverride: AylaRadii.pill,
                shadow: AylaShadows.card,
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AylaIcon(
                      aylaIconByName('iconChevronDown')!,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.mention-jump-highlight`：1.6s 粉框辉光闪一次（app.css 965–973）。
class _JumpHighlight extends StatefulWidget {
  const _JumpHighlight({required this.child});

  final Widget child;

  @override
  State<_JumpHighlight> createState() => _JumpHighlightState();
}

class _JumpHighlightState extends State<_JumpHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kAylaMessageJumpHighlight,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = 1 - _controller.value;
        if (t <= 0 || child == null) return child ?? const SizedBox.shrink();
        // ⚠️ **必须走 `AylaGlassShadow.ring`**（自绘「只画形状之外」的环）：
        // CSS 的 `box-shadow` 不绘制在 border-box 之内，而 Flutter 的
        // `BoxDecoration(boxShadow:)` 会**连形状内部一起铺**（skill 记录的语义差异 #1）
        // ⇒ 直接用 BoxShadow 会把整条消息行填成实心粉色（实测：871×62 的实心块，
        // 用户实报「跳转提示是一整块」）。
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: AylaGlassShadow.ring(
                radius: BorderRadius.circular(AylaRadii.rInput),
                shadows: <BoxShadow>[
                  // `0 0 0 2px var(--glow-500)`（不透明环，随 1.6s 淡出收细）
                  BoxShadow(color: AylaColors.glow500, spreadRadius: 2 * t),
                  // `var(--glow-shadow)`：0 0 16px rgba(247,150,255,.45)
                  ...AylaShadows.glow.map((BoxShadow s) => s.scale(t)),
                ],
              ),
            ),
            child,
          ],
        );
      },
      child: widget.child,
    );
  }
}

// ======================= 样张 =======================

AylaChatMessage _previewMsg({
  required String id,
  required int seq,
  required String senderId,
  String content = '',
  AylaMessageType type = AylaMessageType.text,
  AylaMessageStatus status = AylaMessageStatus.sent,
  DateTime? at,
  List<AylaMediaSegment> segments = const <AylaMediaSegment>[],
  String? replyTo,
  bool sendFailed = false,
  bool pending = false,
  double? uploadProgress,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: type,
      content: content,
      status: status,
      seq: seq,
      createdAt: (at ?? DateTime(2026, 9, 24, 21, 30)).toUtc().toIso8601String(),
      segments: segments,
      replyTo: replyTo,
      sendFailed: sendFailed,
      pending: pending,
      uploadProgress: uploadProgress,
    );

AylaConversationSummary _previewConv({bool group = true}) =>
    AylaConversationSummary(
      id: 'c1',
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: group ? '深夜电台群' : '',
      avatar: '',
      memberCount: 3,
      peer: group
          ? null
          : const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
    );

/// 消息滚动区样张：
/// 群聊（时间分隔 / 引用 / 发送失败 / 上传中 / 戳一戳）/ 私聊（含跳转标签与回底键）/ 空态。
Widget aylaMessageListSamples() {
  aylaEnableSampleMedia();
  final DateTime base = DateTime(2026, 9, 24, 21, 30);
  final List<AylaChatMessage> group = <AylaChatMessage>[
    _previewMsg(
      id: 'g1',
      seq: 1,
      senderId: 'u2',
      content: '今晚十点开播，记得来～',
      at: base.subtract(const Duration(hours: 2)),
    ),
    _previewMsg(
      id: 'g2',
      seq: 2,
      senderId: 'me',
      content: '收到，我先把歌单排好',
      at: base.subtract(const Duration(hours: 2, minutes: 1)),
    ),
    // 间隔 > 5 分钟 ⇒ 新时间分隔
    _previewMsg(
      id: 'g3',
      seq: 3,
      senderId: 'u3',
      content: '我把封面做好了',
      at: base.subtract(const Duration(minutes: 12)),
      segments: <AylaMediaSegment>[
        const AylaMediaSegment(type: AylaSegmentType.text, text: '我把封面做好了'),
        const AylaMediaSegment(
          type: AylaSegmentType.image,
          mediaId: 'm-cover',
        ),
      ],
    ),
    _previewMsg(
      id: 'g4',
      seq: 4,
      senderId: 'me',
      content: '很好看！',
      at: base.subtract(const Duration(minutes: 11)),
      replyTo: 'g3',
    ),
    _previewMsg(
      id: 'g5',
      seq: 5,
      senderId: 'u2',
      content: '',
      type: AylaMessageType.poke,
      at: base.subtract(const Duration(minutes: 5)),
    ),
    _previewMsg(
      id: 'g6',
      seq: 6,
      senderId: 'me',
      content: '这条发送失败了',
      at: base.subtract(const Duration(minutes: 2)),
      sendFailed: true,
    ),
    _previewMsg(
      id: 'g7',
      seq: 7,
      senderId: 'me',
      content: '',
      type: AylaMessageType.image,
      at: base.subtract(const Duration(minutes: 1)),
      pending: true,
      uploadProgress: 0.4,
    ),
  ];

  final List<AylaChatMessage> priv = <AylaChatMessage>[
    _previewMsg(id: 'p1', seq: 1, senderId: 'u2', content: '睡了吗？'),
    _previewMsg(id: 'p2', seq: 2, senderId: 'me', content: '还没，在写文档'),
  ];

  Widget stage(String label, Widget child, {double width = 720, double height = 420}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(
              width: width,
              height: height,
              child: child,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      stage(
        '群聊（时间分隔 / 引用 / 失败重试 / 上传中 / 戳一戳 / 加载更早）',
        AylaMessageList(
          messages: group,
          conversation: _previewConv(),
          currentUserId: 'me',
          hasMore: true,
          onQuote: (_) {},
          onRecall: (_) {},
          onRetry: (_) {},
          onRemove: (_) {},
          onCancel: (_) {},
          onMentionSender: (_, __) {},
          onPoke: (_) {},
          onMarkRead: (_, __) async {},
        ),
      ),
      stage(
        '私聊（未读跳转标签 + 回底键）',
        AylaMessageList(
          messages: priv,
          conversation: _previewConv(group: false),
          currentUserId: 'me',
          unreadSeqs: const <int>[1],
          onMarkRead: (_, __) async {},
          onMarkConversationRead: (_, __) async {},
        ),
        height: 320,
      ),
      stage(
        '特殊未读标签（@我 / 回复；各为 1px 粉边玻璃胶囊，靠 glow-shadow 辉光）',
        AylaMessageList(
          messages: priv,
          conversation: _previewConv(group: false),
          currentUserId: 'me',
          mentionUnreadSeqs: const <int>[1],
          replyUnreadSeqs: const <int>[2],
          onMarkRead: (_, __) async {},
          onMarkConversationRead: (_, __) async {},
        ),
        height: 260,
      ),
      stage(
        '空态',
        AylaMessageList(
          messages: const <AylaChatMessage>[],
          conversation: _previewConv(group: false),
          currentUserId: 'me',
        ),
        height: 200,
      ),
    ],
  );
}
