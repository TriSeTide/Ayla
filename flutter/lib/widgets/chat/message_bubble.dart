/// 单条消息气泡（`components/chat/MessageBubble.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMessageBubble] | `MessageBubble.tsx:324–376`（单行布局 + 内容分支） |
/// | [aylaCanRecall] | tsx 34–44 `canRecall`（自己 + 未撤回 + **120s** 内） |
/// | [aylaMessageTimeAgo] | tsx 24–32 `timeAgo` |
/// | 行/主体布局 | app.css 1041–1102（`.msg-row` / `.msg-body` / `.msg-bubble-wrap`） |
/// | 气泡三态 | app.css 1104–1136（`.bubble-self` / `-elysia` / `-other`）+ 1514–1518（`.bubble-media`） |
/// | 撤回态 | app.css 1225–1228（opacity .6 + italic；**同时 class 退化为 `bubble-other`**，tsx 210–216） |
/// | 引用条 | app.css 1261–1285（`.quote-strip`） |
/// | 操作栏 | app.css 1287–1322（`.msg-actions` 三种显示条件）+ 1324–1333 / 1362–1365 |
/// | 操作键 | auroraqua.css 55–94（transition 200ms / hover 1.02 / active .98）+ 124–166（材质 + 扫光） |
/// | 发送态 | app.css 1335–1360 + tsx 276–322 |
/// | 到达动画 | base.css 426–434 `frost-rise`（+8px 淡入 180ms）+ app.css 1089–1093（reduced-motion 关） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **触屏判定**：web 用 `@media (hover: none)` 决定「点行展开工具栏」；Flutter 无该媒体
///    查询 ⇒ 按平台判定（Android / iOS / fuchsia = 触屏，与 `live_player` 的平台分派同一
///    先例），并留 [AylaMessageBubble.touchMode] 供页面层覆盖；
/// 2. **发送态定位**：web 用 `position:absolute; right:calc(100% + 8px)`；Flutter 用
///    `FractionalTranslation(-1, 0)` + 8px 位移表达同一条 CSS（相对**自身**宽度的 100%），
///    因此不占布局位、不会压缩气泡；
/// 3. **收藏键状态**：web `MessageBubble.tsx:246` **恒渲染**
///    `<FavoriteButton targetType="message" targetId={message.id} compact />`
///    —— 状态由收藏键自己持有（`FavoriteButton.tsx:22` 调 `useFavoriteStatuses`，
///    `hooks/useFavoriteStatuses.ts:12–16` 挂载即 retain+load、卸载 release），
///    **调用方不传任何收藏参数**。2026-10-09 前 Flutter 侧走「页面注入档」，
///    而 `message_list.dart` 从未传 `favoriteState` ⇒ 每个气泡都停在 `unknown`
///    （禁用 +「正在加载收藏状态」，用户实报）⇒ 本次改为**默认自给自足**：
///    不传 [AylaMessageBubble.favoriteState] / [AylaMessageBubble.onToggleFavorite]
///    时收藏键自己按 `message:<msg.id>` 起状态；画布样张显式传 `favoriteState`
///    仍走注入档（零改动）。
///
/// ## 公开面
/// `AylaMessageBubble` · 样张 `aylaMessageBubbleSamples()`

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../core/media/audio_playback.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/media_kind.dart';
import '../../core/models/post.dart' show AylaMediaDescriptor;
import '../../core/models/share_payload.dart';
import '../../player/vod_player.dart';
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/directory_controls.dart' show AylaFavoriteButton, AylaFavoriteState;
import '../base/loading.dart';
import '../../state/favorite_status.dart' show AylaFavoriteStatusController;
import 'media_content.dart';
import 'share_bubble.dart';
import '../base/tooltip.dart';

/// 撤回时限（秒）—— `hooks/useChat.ts:26` `RECALL_SECONDS = 120`，
/// 与后端 `MESSAGE_RECALL_SECONDS` 对齐。
const int kAylaMessageRecallSeconds = 120;

/// 双击头像判定窗口（ms）—— `MessageBubble.tsx:49` `DOUBLE_CLICK_MS`。
const int kAylaMessageDoubleClickMs = 250;

/// 撤回窗口判断（tsx 34–44）：仅自己、未撤回、`created_at` 在 [kAylaMessageRecallSeconds] 内。
bool aylaCanRecall(
  AylaChatMessage message,
  String? currentUserId, {
  DateTime? now,
}) {
  if (currentUserId == null || message.senderId != currentUserId) return false;
  if (message.recalled) return false;
  final DateTime? created = DateTime.tryParse(message.createdAt);
  if (created == null) return false;
  final DateTime reference = now ?? DateTime.now();
  return reference.difference(created).inSeconds <= kAylaMessageRecallSeconds;
}

/// 相对时间文案（tsx 24–32）：<60s「刚刚」/ <3600s「N 分钟前」/ 否则 `HH:mm`（本地时区）。
String aylaMessageTimeAgo(String iso, {DateTime? now}) {
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final DateTime local = parsed.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final int diff = reference.difference(local).inSeconds;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return '${diff ~/ 60} 分钟前';
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(local.hour)}:${pad(local.minute)}';
}

/// 单条消息气泡。
class AylaMessageBubble extends StatefulWidget {
  const AylaMessageBubble({
    super.key,
    required this.msg,
    required this.isSelf,
    this.isElysia = false,
    this.justArrived = false,
    this.senderName,
    this.senderAvatarUrl,
    this.senderAvatarLabel,
    this.senderOnline = false,
    this.onSenderClick,
    this.onMentionSender,
    this.onPokeSender,
    this.actionsOpen = false,
    this.onToggleActions,
    this.quoteText,
    this.onQuote,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.onRecall,
    this.onRetry,
    this.onRemove,
    this.onCancel,
    this.shareGroupId,
    this.currentUserId,
    this.touchMode,
    this.favoriteState,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.favoriteTargetType,
    this.favoriteTargetId,
    this.favoriteController,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;

  /// 是否自己发送（行方向与气泡样式的判定；爱莉消息由父级判 [isElysia]）。
  final bool isSelf;

  /// 爱莉消息（**爱莉专属气泡，不可复用于其他用户**，design.md §4）。
  final bool isElysia;

  /// 新到达消息（乐观发送 / WS 实时）挂到达动画；初始历史加载为 false。
  final bool justArrived;

  /// 群聊显示发送者名。
  final String? senderName;

  final String? senderAvatarUrl;
  final String? senderAvatarLabel;

  /// 发送者实时在线（光环）。
  final bool senderOnline;

  /// 头像单击（延迟双击窗口后触发）→ 个人主页。
  final VoidCallback? onSenderClick;

  /// 长按头像 500ms → 在输入框内插入 @该用户（仅群聊非自己、非撤回、非 system）。
  final void Function(String userId, String name)? onMentionSender;

  /// 双击头像 → 戳一戳。
  final void Function(String senderUserId)? onPokeSender;

  /// 触屏下该行工具栏是否展开（由父级单选管理）。
  final bool actionsOpen;

  /// 触屏下点击行切换工具栏展开。
  final VoidCallback? onToggleActions;

  /// 被引用消息的预览文本（父级解析）。
  final String? quoteText;

  final void Function(AylaChatMessage msg)? onQuote;

  /// 点击引用块 → 定位被引用的原消息。
  final void Function(AylaChatMessage msg)? onQuoteJump;

  /// 定位到已撤回原消息时的明确文案。
  final bool jumpedRecalled;

  final void Function(AylaChatMessage msg)? onRecall;

  /// 乐观发送失败：重试（重新上传 + 发送，幂等键复用）。
  final void Function(AylaChatMessage msg)? onRetry;

  /// 乐观消息删除（本地丢弃）。
  final void Function(AylaChatMessage msg)? onRemove;

  /// 乐观发送中：取消上传（abort + 删除气泡）。
  final void Function(AylaChatMessage msg)? onCancel;

  /// 当前会话为群聊时的群 id（分享卡片分流跳转用）。
  final String? shareGroupId;

  /// 当前登录用户 id（撤回窗口与混排「@我」判定）。
  final String? currentUserId;

  /// 触屏模式（null = 按平台判定：Android / iOS / fuchsia 视为触屏）。
  final bool? touchMode;

  /// 收藏状态（**注入档**：非 null ⇒ 由调用方驱动，与 2026-10-09 前逐像素一致）。
  ///
  /// null 且 [onToggleFavorite] 也为 null ⇒ **自给自足档**（web 语义，
  /// `MessageBubble.tsx:246`）：收藏键按 `message:<msg.id>` 自己 retain + load + toggle。
  final AylaFavoriteState? favoriteState;

  final bool favoriteBusy;
  final String? favoriteError;
  final void Function(bool favorited)? onToggleFavorite;
  final VoidCallback? onRetryFavoriteStatus;

  /// 收藏目标类型/id（web `MessageBubble.tsx:246` 恒为 `"message"` + `message.id`）。
  ///
  /// 留出覆写口：消息卡在别的上下文（如收藏页的消息卡）可能有自己的目标身份。
  final String? favoriteTargetType;
  final String? favoriteTargetId;

  /// 自给自足档的控制器（不传 ⇒ 用库内共享单例）。
  final AylaFavoriteStatusController? favoriteController;

  // ---- 媒体内容注入点（透传给 [AylaMediaContent]，语义见该组件文档）----
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;

  // ---- 分享卡注入点（透传给 [AylaShareBubble]）----
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  State<AylaMessageBubble> createState() => _AylaMessageBubbleState();
}

class _AylaMessageBubbleState extends State<AylaMessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: AylaDurations.fast, // frost-rise 180ms（base.css 426–434）
  );

  bool _hovered = false;
  bool _focused = false;

  /// 长按已触发（抑制紧随的 click，避免又跳个人主页 —— tsx 147–149）。
  bool _longPressTriggered = false;
  Timer? _singleClickTimer;
  Timer? _longPressTimer;

  bool get _touchMode => widget.touchMode ?? _platformIsTouch(context);

  static bool _platformIsTouch(BuildContext context) {
    // web `@media (hover: none)`（`hooks/useMediaQuery.ts:16` HOVER_NONE_QUERY）：
    // 判「无 hover 能力的设备」。Flutter 无该媒体查询 ⇒ 按平台判定
    // （Touch 平台 = 触摸为主；桌面平台的鼠标/触控板都有 hover）。
    return switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
      _ => false,
    };
  }

  /// 到达动画是否已启动（`didChangeDependencies` 只处理一次；**不能在 initState 读
  /// MediaQuery**，见 13 号 §五）。
  bool _arriveStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arriveStarted) return;
    _arriveStarted = true;
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // web `@media (prefers-reduced-motion: reduce) { .msg-row.msg-arrive { animation: none } }`
    if (widget.justArrived && !reduceMotion) {
      _arrive.forward();
    } else {
      _arrive.value = 1;
    }
  }

  @override
  void dispose() {
    _singleClickTimer?.cancel();
    _longPressTimer?.cancel();
    _arrive.dispose();
    super.dispose();
  }

  // ---- 头像手势（tsx 146–208）----

  bool get _canMention =>
      !widget.isSelf &&
      !widget.msg.recalled &&
      !widget.msg.isSystem &&
      widget.senderName != null &&
      widget.onMentionSender != null;

  bool get _canPoke =>
      !widget.msg.recalled && !widget.msg.isSystem && widget.onPokeSender != null;

  void _clearLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _onSenderTap() {
    if (_longPressTriggered) {
      _longPressTriggered = false;
      return;
    }
    final Timer? pending = _singleClickTimer;
    if (_canPoke && pending != null) {
      // 双击窗口内第二次：取消挂起的单击，触发戳一戳
      pending.cancel();
      _singleClickTimer = null;
      widget.onPokeSender?.call(widget.msg.senderId);
      return;
    }
    _singleClickTimer = Timer(
      const Duration(milliseconds: kAylaMessageDoubleClickMs),
      () {
        _singleClickTimer = null;
        widget.onSenderClick?.call();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage msg = widget.msg;
    final bool recalled = msg.recalled;
    final bool showSenderHalo = !recalled &&
        !msg.isSystem &&
        (widget.senderAvatarLabel != null || widget.senderAvatarUrl != null);

    final Widget? halo = showSenderHalo
        ? GestureDetector(
            // 长按 500ms（Flutter onLongPress 默认即 kLongPressTimeout = 500ms）
            onLongPress: _canMention
                ? () {
                    _longPressTriggered = true;
                    widget.onMentionSender!(
                      msg.senderId,
                      widget.senderName!,
                    );
                  }
                : null,
            onLongPressCancel: _clearLongPress,
            onLongPressUp: _clearLongPress,
            child: AylaAvatarHalo(
              label: widget.senderAvatarLabel ?? widget.senderName ?? '发送者',
              size: 32,
              online: widget.senderOnline,
              resourceUrl: widget.senderAvatarUrl,
              onTap: _onSenderTap,
              semanticLabel: widget.senderName ?? '发送者个人主页',
            ),
          )
        : null;

    // 撤回键的显示条件（明确：**只有自己 2 分钟内的消息**才显示）。
    // web 由父级过滤（`MessageList.tsx:1084`：`onRecall={onRecall && canRecall(m, currentUserId)
    // ? onRecall : undefined}`）⇒ 组件内**再判一次**，父级漏传时对方消息也不会冒出撤回键。
    final bool showRecall =
        widget.onRecall != null && aylaCanRecall(msg, widget.currentUserId);

    final Widget? actions = (!recalled && !msg.isSystem)
        ? _MsgActions(
            msg: msg,
            visible: _hovered || _focused || widget.actionsOpen,
            showRecall: showRecall,
            favoriteState: widget.favoriteState,
            favoriteBusy: widget.favoriteBusy,
            favoriteError: widget.favoriteError,
            onToggleFavorite: widget.onToggleFavorite,
            onRetryFavoriteStatus: widget.onRetryFavoriteStatus,
            favoriteTargetType: widget.favoriteTargetType,
            favoriteTargetId: widget.favoriteTargetId,
            favoriteController: widget.favoriteController,
            onQuote: widget.onQuote,
            onRecall: widget.onRecall,
          )
        : null;

    final Widget body = Column(
      crossAxisAlignment:
          widget.isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!widget.isSelf && widget.senderName != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
            child: Text(
              widget.senderName!,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
        _BubbleWrap(
          msg: msg,
          isSelf: widget.isSelf,
          isElysia: widget.isElysia,
          onCancel: widget.onCancel,
          onRetry: widget.onRetry,
          onRemove: widget.onRemove,
          quoteText: widget.quoteText,
          onQuoteJump: widget.onQuoteJump,
          jumpedRecalled: widget.jumpedRecalled,
          shareGroupId: widget.shareGroupId,
          currentUserId: widget.currentUserId,
          descriptorFetcher: widget.descriptorFetcher,
          onDescriptorFetched: widget.onDescriptorFetched,
          audioEngineFactory: widget.audioEngineFactory,
          vodPlayerFactory: widget.vodPlayerFactory,
          onMentionTap: widget.onMentionTap,
          onDownloaded: widget.onDownloaded,
          onSaveError: widget.onSaveError,
          onNavigate: widget.onNavigate,
          isGroupJoined: widget.isGroupJoined,
          onRequestJoin: widget.onRequestJoin,
          onResolveShareTarget: widget.onResolveShareTarget,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
          child: Text(
            aylaMessageTimeAgo(msg.createdAt),
            style: const TextStyle(
              fontFamily: AylaFonts.utility,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              letterSpacing: 0.3,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool narrow = MediaQuery.sizeOf(context).width <= 768;
        // `.msg-body { max-width: 75% }`（app.css:1074）/ 窄屏 84%（app.css:3217–3219）
        // 的百分比基数是 **`.msg-row` 的 content box** —— `.msg-row` 自身有
        // `padding: 0 var(--sp-1)`（app.css:1045，= 8px）⇒ 可分配宽 = 行宽 − 8。
        // 本件 `c` 是 LayoutBuilder 拿到的**整行**约束、`Padding(horizontal: sp1)`
        // 在它内层 ⇒ 不减这 8px 会让气泡最大宽多出 0.84×8 ≈ 6.7px。
        final double rowInnerWidth = math.max(
          0,
          c.maxWidth - 2 * AylaSpacing.sp1,
        );
        final double bodyMaxWidth = rowInnerWidth * (narrow ? 0.84 : 0.75);
        final List<Widget> children = <Widget>[
          if (halo != null) halo,
          if (halo != null) const SizedBox(width: AylaSpacing.sp2),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: bodyMaxWidth),
              child: body,
            ),
          ),
          if (actions != null) const SizedBox(width: AylaSpacing.sp2),
          if (actions != null) actions,
        ];
        final Widget row = Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          // web `.msg-row { display:flex }` + `.msg-row.self { flex-direction: row-reverse }`
          // （app.css 1041–1071）——注意 `row-reverse` **同时把主轴起点移到右侧**
          // ⇒ 只反转子级顺序不够，self 行必须 `MainAxisAlignment.end` 才真的靠右
          // （实测「好呀我这就来这条没有置右」）。
          mainAxisAlignment: widget.isSelf
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: widget.isSelf ? children.reversed.toList() : children,
        );

        final Widget content = widget.onToggleActions != null && _touchMode
            ? GestureDetector(
                // 触屏无 hover：点行（非交互区）切换工具栏展开（tsx 139–144）。
                // 子级按钮各自的手势识别器在竞技场中胜出 ⇒ 点按钮不会误触发本回调。
                onTap: widget.onToggleActions,
                child: row,
              )
            : row;

        // `:focus-within`（app.css:1301–1304 `.msg-row:focus-within .msg-actions`）
        // 命中**行内任何**可聚焦元素 —— 含气泡内 `.quote-strip` 的 button 分支
        // （`MessageBubble.tsx:339–347`）。`Focus.onFocusChange` 只在该节点自身
        // 获得/失去焦点时触发；子节点取得焦点而父节点仍在链上不触发 —— 对布尔
        // 语义**恰好等价**：子树里任何可聚焦件拿到焦点 ⇒ `_focused = true`，
        // 焦点离开整行 ⇒ false（`FocusNode.hasFocus` 的「链上任意位置」语义）。
        // 此前 Focus 只包住操作栏自身 ⇒ 聚焦气泡里的引用键时工具栏不显示。
        return Focus(
          onFocusChange: (bool v) => setState(() => _focused = v),
          child: MouseRegion(
            // 触屏档整行可点（展开工具栏，见上方 `onToggleActions` 分支）⇒ 手型；
            // 桌面档行本体不可点，鼠标落在气泡上仍是 arrow（web 同：行无 pointer 声明）。
            cursor: _touchMode
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: AnimatedBuilder(
              animation: _arrive,
              builder: (BuildContext context, Widget? child) {
                if (_arrive.value >= 1.0) return child!;
                final double t = AylaCurves.easeOut.transform(_arrive.value);
                // `frost-rise`：opacity 0→1 + translateY 8→0（180ms）
                // 依据（2026-09-27 收口；13 号 §8.19）：web `@keyframes frost-rise`
                // （base.css:426–435）作用在**整行** `.msg-row` 上 ⇒ 整层 opacity，
                // 含气泡自身的 `.bubble-other` blur(12px) 层 ⇒ 保持整层 Opacity。
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, 8 * (1 - t)),
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 气泡外层（`.msg-bubble-wrap`）：承载发送态与气泡本体（tsx 334–368）。
class _BubbleWrap extends StatelessWidget {
  const _BubbleWrap({
    required this.msg,
    required this.isSelf,
    required this.isElysia,
    this.onCancel,
    this.onRetry,
    this.onRemove,
    this.quoteText,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.shareGroupId,
    this.currentUserId,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;
  final bool isSelf;
  final bool isElysia;
  final void Function(AylaChatMessage msg)? onCancel;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;
  final String? quoteText;
  final void Function(AylaChatMessage msg)? onQuoteJump;
  final bool jumpedRecalled;
  final String? shareGroupId;
  final String? currentUserId;
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage message = msg;
    final bool recalled = message.recalled;

    Widget? sendState;
    if (isSelf && !recalled && (message.pending || message.sendFailed)) {
      sendState = _SendState(
        msg: message,
        onCancel: onCancel,
        onRetry: onRetry,
        onRemove: onRemove,
      );
    }

    final Widget bubble = _BubbleFace(
      msg: message,
      isSelf: isSelf,
      isElysia: isElysia,
      quoteText: quoteText,
      onQuoteJump: onQuoteJump,
      jumpedRecalled: jumpedRecalled,
      shareGroupId: shareGroupId,
      currentUserId: currentUserId,
      descriptorFetcher: descriptorFetcher,
      onDescriptorFetched: onDescriptorFetched,
      audioEngineFactory: audioEngineFactory,
      vodPlayerFactory: vodPlayerFactory,
      onMentionTap: onMentionTap,
      onDownloaded: onDownloaded,
      onSaveError: onSaveError,
      onNavigate: onNavigate,
      isGroupJoined: isGroupJoined,
      onRequestJoin: onRequestJoin,
      onResolveShareTarget: onResolveShareTarget,
    );

    if (sendState == null) return bubble;

    // 发送态：web `.msg-send-state { position:absolute; right:calc(100% + 8px); top:50% }`
    // （app.css 1336–1345）——即**贴在气泡左缘外 8px、垂直居中**。
    //
    // ⚠️ Flutter 侧**不能**用「`Stack` + `Positioned.fill` + `FractionalTranslation(-1)`」
    // 表达这条 CSS：溢出父边界的部分会被祖先的命中测试丢弃（`RenderBox.hitTest` 只在
    // 自身 size 内接受）⇒ 取消/重试/删除三个键**点不到**（13 号 §6.4 同类现象）。
    // 改为在气泡左侧**占位**：self 行的 `msg-body` 交叉轴是 `end`（app.css 1085–1087），
    // body 变宽只向左扩展 ⇒ 右对齐的气泡**位置不变**，而状态整体落在 body 尺寸内、可点。
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center, // = CSS 的 top:50% + translateY(-50%)
      children: <Widget>[
        sendState,
        const SizedBox(width: AylaSpacing.sp2), // CSS `calc(100% + 8px)` 的 8px
        Flexible(child: bubble),
      ],
    );
  }
}

/// 气泡本体（三态材质 + 内容分支）。
class _BubbleFace extends StatelessWidget {
  const _BubbleFace({
    required this.msg,
    required this.isSelf,
    required this.isElysia,
    this.quoteText,
    this.onQuoteJump,
    this.jumpedRecalled = false,
    this.shareGroupId,
    this.currentUserId,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.onNavigate,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onResolveShareTarget,
  });

  final AylaChatMessage msg;
  final bool isSelf;
  final bool isElysia;
  final String? quoteText;
  final void Function(AylaChatMessage msg)? onQuoteJump;
  final bool jumpedRecalled;
  final String? shareGroupId;
  final String? currentUserId;
  final AylaMediaDescriptorFetcher? descriptorFetcher;
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;
  final AylaAudioEngine Function()? audioEngineFactory;
  final VodPlayerFactory? vodPlayerFactory;
  final void Function(String userId)? onMentionTap;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;
  final void Function(String route)? onNavigate;
  final bool Function(String groupId)? isGroupJoined;
  final void Function(AylaSharePayload payload)? onRequestJoin;
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveShareTarget;

  @override
  Widget build(BuildContext context) {
    final AylaChatMessage message = msg;
    final bool recalled = message.recalled;
    // 撤回态 class 退化为 `bubble-other`（tsx 210–216）
    final bool self = isSelf && !recalled;
    final bool elysia = isElysia && !recalled && !isSelf;
    final bool isMedia = message.isMedia && !recalled;

    // 圆角：self → `18 18 6 18`（右下小角）；elysia/other → `18 18 18 6`（左下小角）
    final BorderRadius radius = BorderRadius.only(
      topLeft: const Radius.circular(AylaRadii.rBubble),
      topRight: const Radius.circular(AylaRadii.rBubble),
      bottomRight: Radius.circular(self ? 6 : AylaRadii.rBubble),
      bottomLeft: Radius.circular(self ? AylaRadii.rBubble : 6),
    );

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (quoteText != null && !recalled)
          _QuoteStrip(
            text: quoteText!,
            onJump: onQuoteJump == null ? null : () => onQuoteJump!(message),
          ),
        _content(message, recalled, isMedia),
      ],
    );

    return Opacity(
      // `.bubble.recalled { opacity: .6; font-style: italic }`（app.css:1225–1228）
      // ⇒ web 是**整层 opacity**：它连同 `.bubble-other { background: var(--bubble-other);
      //   backdrop-filter: blur(12px) }`（app.css:1129–1136）一起被压暗
      //   ⇒ 保持整层（不以颜色 alpha 替代，否则模糊层不再被压暗；13 号 §8.19）。
      opacity: recalled ? 0.6 : 1.0,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            // ① 模糊层（仅 `.bubble-other` 有 `backdrop-filter: blur(12px)`，
            //    注意：**无 saturate**（app.css 1131）⇒ 用 blurOnly）
            if (!self && !elysia)
              Positioned.fill(
                // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
                child: AylaGlassBackdrop(
                  radius: radius,
                  filter: AylaGlassConfig.blurOnly(sigma: 12),
                ),
              ),
            // ② 底色层（渐变必须在**独立层**：同层 BoxDecoration 的渐变会盖住 1px 边框）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 别人气泡的降级值 = `rgba(255,250,251,.92)`：web 的
                  // `.bubble-other { background: var(--bubble-other); backdrop-filter:
                  // blur(12px) }`（app.css:1129–1136）**只命中** app.css:252–270 的
                  // `@supports` 降级段（不在 auroraqua.css:527–551 的清单里）
                  // ⇒ 实底档换软值 `.92` 而不是 `--surface`。
                  color: self || elysia
                      ? null
                      : (AylaGlassConfig.useOpaqueFallback
                            ? AylaColors.glassOpaqueFallbackSoft
                            : AylaColors.bubbleOther),
                  gradient: self
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AylaGradients.bubbleSelf,
                        )
                      : (elysia
                          ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: AylaGradients.bubbleElysia,
                            )
                          : null),
                ),
              ),
            ),
            // ③ 边框层（elysia：1px `rgba(247,150,255,.5)`；other：1px `--glass-border`）
            if (elysia || (!self && !elysia))
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: elysia
                            ? AylaColors.elysiaBubbleBorder
                            : AylaColors.glassBorder,
                      ),
                    ),
                  ),
                ),
              ),
            // ④ 内容（`.bubble { padding: 10px 14px }`；媒体气泡 `padding: sp1`）
            Padding(
              padding: isMedia
                  ? const EdgeInsets.all(AylaSpacing.sp1)
                  : const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 15,
                  height: 1.55,
                  // ⚠️ **有意偏离 web**（实测「对方撤回了一条消息字体过于斜了」）：
                  // web 是 `.bubble.recalled { opacity: .6; font-style: italic }`（app.css 1225–1228），
                  // 但中文没有真斜体变体 ⇒ 浏览器/Flutter 都在合成斜体，而 Flutter（Skia）在
                  // 预览宿主的中文回退字体上倾角明显更大。撤回态保留 `opacity: .6` 弱化，
                  // **不再叠斜体**。改回 italic 前请先与用户确认。
                  fontStyle: FontStyle.normal,
                  color: elysia ? AylaColors.grape700 : AylaColors.indigo700,
                ),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(AylaChatMessage message, bool recalled, bool isMedia) {
    if (recalled) {
      return Text(
        jumpedRecalled
            ? '该消息已撤回'
            : (isSelf ? '你撤回了一条消息' : '对方撤回了一条消息'),
      );
    }
    if (message.isSystem) return Text(message.content);
    if (message.isShare) {
      return AylaShareBubble(
        msg: message,
        groupId: shareGroupId,
        isGroupJoined: isGroupJoined,
        onRequestJoin: onRequestJoin,
        onNavigate: onNavigate,
        onResolveTarget: onResolveShareTarget,
      );
    }
    if (isMedia) {
      return AylaMediaContent(
        msg: message,
        descriptorFetcher: descriptorFetcher,
        onDescriptorFetched: onDescriptorFetched,
        audioEngineFactory: audioEngineFactory,
        vodPlayerFactory: vodPlayerFactory,
        onMentionTap: onMentionTap,
        onDownloaded: onDownloaded,
        onSaveError: onSaveError,
        currentUserId: currentUserId,
      );
    }
    // 媒体消息气泡只渲染媒体本体（tsx 365–366）；其余显示正文（空则空格占位）
    return Text(message.content.isEmpty ? ' ' : message.content);
  }
}

/// 引用竖条（`.quote-strip`，app.css 1261–1285）。
class _QuoteStrip extends StatefulWidget {
  const _QuoteStrip({required this.text, this.onJump});

  final String text;
  final VoidCallback? onJump;

  @override
  State<_QuoteStrip> createState() => _QuoteStripState();
}

class _QuoteStripState extends State<_QuoteStrip> {
  bool _hovered = false;
  bool _focused = false;

  bool get _clickable => widget.onJump != null;

  @override
  Widget build(BuildContext context) {
    // web `MessageBubble.tsx:339–347` 的可点分支是**原生 `<button>`** ⇒ 天然进
    // tab 序列、可聚焦；不可点分支是 `<div>`（`tsx:349–351`）⇒ 不可聚焦。
    // Flutter 的 `GestureDetector` 不可聚焦 ⇒ 补一层 `Focus`（Enter/Space 触发同
    // `onJump`），并让 `:hover, :focus-visible → background .65`
    // （`app.css:1282–1285`）的焦点档也生效。
    // 焦点也因此被**行级** Focus 捕获（`app.css:1301` 的 `:focus-within`）。
    final Widget body = Focus(
      canRequestFocus: _clickable,
      onFocusChange: (bool has) => setState(() => _focused = has),
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool activate = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space;
        if (!activate || !_clickable) return KeyEventResult.ignored;
        widget.onJump!();
        return KeyEventResult.handled;
      },
      child: MouseRegion(
      cursor: widget.onJump == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: '跳转到被引用消息：${widget.text}',
        button: widget.onJump != null,
        child: GestureDetector(
          onTap: widget.onJump,
          child: Opacity(
            opacity: 0.85,
            child: AnimatedContainer(
              duration: AylaDurations.fast,
              curve: AylaCurves.easeOut,
              margin: const EdgeInsets.only(bottom: AylaSpacing.sp1),
              decoration: BoxDecoration(
                // `background: rgba(255,250,251,.45)`；hover/focus → `.65`（app.css:1261–1285）
                color: (_hovered || _focused)
                    ? const Color(0xA6FFFAFB)
                    : const Color(0x73FFFAFB),
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
              ),
              child: ClipRRect(
                // `border-left: 3px solid --ice-500` + 圆角：Flutter 的 BoxDecoration
                // 不允许「非均匀 border + borderRadius」⇒ 用 Stack + Positioned 色条。
                // ⚠️ **不能用 `Row(crossAxisAlignment: stretch)`** —— Row 在 Column 的
                // 竖直无界约束下会抛 `BoxConstraints forces an infinite height`
                // （13 号 §五「StackFit.expand / Center 在无界高度下的陷阱」）。
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
                child: Stack(
                  children: <Widget>[
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 3,
                      child: ColoredBox(color: AylaColors.ice500),
                    ),
                    Padding(
                      // 左 padding = sp2 + 3px 色条（等价 CSS 的 border-box padding）
                      padding: const EdgeInsets.only(
                        left: AylaSpacing.sp2 + 3,
                        right: AylaSpacing.sp2,
                        top: AylaSpacing.sp1,
                        bottom: AylaSpacing.sp1,
                      ),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                          fontFamily: AylaFonts.body,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontSize: 13,
                          color: AylaColors.indigo700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
    // web «MessageBubble.tsx:341–352»：可点分支 «title="跳转到被引用消息"»、
    // 不可点分支 «title={quoteText}» —— 两分支同用 .quote-strip 类名。
    return AylaTooltip(
      message: widget.onJump != null ? '跳转到被引用消息' : widget.text,
      child: body,
    );
  }
}

/// 乐观发送状态（`.msg-send-state`，app.css 1336–1360 + tsx 276–322）。
class _SendState extends StatelessWidget {
  const _SendState({
    required this.msg,
    this.onCancel,
    this.onRetry,
    this.onRemove,
  });

  final AylaChatMessage msg;
  final void Function(AylaChatMessage msg)? onCancel;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;

  @override
  Widget build(BuildContext context) {
    final double? progress = msg.pending ? msg.uploadProgress : null;
    if (msg.pending) {
      if (progress != null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              label: '上传中 ${progress.round()}%',
              child: Text(
                '上传中 ${progress.round()}%',
                style: const TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
            if (onCancel != null) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp1),
              AylaMsgActionButton(
                label: '取消',
                semanticLabel: '取消发送',
                onPressed: () => onCancel!(msg),
              ),
            ],
          ],
        );
      }
      // 纯文本发送中：spinner sm 14 + 轨道 rgba(70,91,146,.25)（app.css 1353–1355）
      return Semantics(
        label: '发送中',
        child: AylaLoadingSpinner(
          size: 14,
          track: const Color(0x40465B92),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text(
          '发送失败',
          style: TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12,
            color: AylaColors.destructive,
          ),
        ),
        if (onRetry != null) ...<Widget>[
          const SizedBox(width: AylaSpacing.sp1),
          AylaMsgActionButton(
            label: '重试',
            semanticLabel: '重试发送',
            onPressed: () => onRetry!(msg),
          ),
        ],
        if (onRemove != null) ...<Widget>[
          const SizedBox(width: AylaSpacing.sp1),
          AylaMsgActionButton(
            label: '删除',
            semanticLabel: '删除消息',
            onPressed: () => onRemove!(msg),
          ),
        ],
      ],
    );
  }
}

/// 气泡操作栏（`.msg-actions`，app.css 1287–1322）。
class _MsgActions extends StatelessWidget {
  const _MsgActions({
    required this.msg,
    required this.visible,
    required this.showRecall,
    this.favoriteState,
    required this.favoriteBusy,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.favoriteTargetType,
    this.favoriteTargetId,
    this.favoriteController,
    this.onQuote,
    this.onRecall,
  });

  final AylaChatMessage msg;
  final bool visible;

  /// 是否显示「撤回」键（= 自己的消息且在 120s 窗口内，见 [AylaMessageBubble.build]）。
  final bool showRecall;

  /// 注入档收藏状态；null 且 [onToggleFavorite] 也为 null ⇒ 自给自足档（web 语义）。
  final AylaFavoriteState? favoriteState;
  final bool favoriteBusy;
  final String? favoriteError;
  final void Function(bool favorited)? onToggleFavorite;
  final VoidCallback? onRetryFavoriteStatus;
  final String? favoriteTargetType;
  final String? favoriteTargetId;
  final AylaFavoriteStatusController? favoriteController;
  final void Function(AylaChatMessage msg)? onQuote;
  final void Function(AylaChatMessage msg)? onRecall;

  /// 收藏键（web `MessageBubble.tsx:246` 的**条件恒真**分支）。
  ///
  /// - 调用方给了状态/回调 ⇒ 注入档（画布样张与既有测试逐像素不变）；
  /// - 都没给 ⇒ **自给自足档**：`targetType="message"`、`targetId=msg.id`
  ///   （web 写死的两个值），收藏键挂载即 retain + load ⇒ `message_list.dart`
  ///   **无需任何改动**就得到 web 的行为。
  Widget get _favorite {
    final bool injected =
        favoriteState != null || onToggleFavorite != null;
    if (injected) {
      return AylaFavoriteButton(
        state: favoriteState ?? AylaFavoriteState.unknown,
        compact: true,
        busy: favoriteBusy,
        actionError: favoriteError,
        onToggle: onToggleFavorite,
        onRetryStatus: onRetryFavoriteStatus,
      );
    }
    return AylaFavoriteButton(
      targetType: favoriteTargetType ?? 'message',
      targetId: favoriteTargetId ?? msg.id,
      controller: favoriteController,
      compact: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 包装器**恒在**（只翻转可见标志位），否则 Element 重建会让隐式动画直接跳到终值
    // （13 号 §五：A5 会话球「瞬间消失」事故同一根因）。
    // ⚠️ 焦点不在本件：`:focus-within` 的判定已提到**整行**层级
    // （见 `AylaMessageBubble.build` 的 `Focus`）—— `app.css:1301` 覆盖行内任何可聚焦元素。
    return IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          // `.msg-actions { opacity: 0; pointer-events: none; transition: opacity var(--dur-fast)
          //   var(--ease-out) }`（app.css:1290–1298）；显示态 → `opacity: 1`：
          //   `.msg-row:focus-within`（app.css:1301–1304）/ `@media (hover:hover) .msg-row:hover`
          //   （app.css:1307–1312）/ `@media (hover:none) .msg-row.is-actions-open`（app.css:1317–1322）
          // ⇒ web 是**整层 opacity** ⇒ 保持 AnimatedOpacity。子树里的 AylaMsgActionButton 带
          //   blur(8px)（web 同款：auroraqua.css:122–129 的按钮材质组含 `.msg-action-btn`）
          //   ⇒ 不以颜色 alpha 替代（13 号 §8.19）。
          opacity: visible ? 1.0 : 0.0,
          duration: AylaDurations.fast,
          curve: AylaCurves.easeOut,
          child: Padding(
            // `.msg-actions { padding-bottom: 2px }`
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _favorite,
                // 引用键：web `MessageBubble.tsx:247` `{onQuote && (…)}` ——
                // **未接线时根本不渲染**（不是渲染一个无副作用的假按钮），
                // 与 `tsx:258` 的 `{onRecall && (…)}` 同一写法；
                // 同时 gap 也不出现（`.msg-actions { gap: var(--sp-1) }` 只在有子项时生效）。
                if (onQuote != null) ...<Widget>[
                  const SizedBox(width: AylaSpacing.sp1),
                  AylaMsgActionButton(
                    label: '引用',
                    semanticLabel: '引用回复',
                    icon: _actionIcon('iconQuote', 12),
                    onPressed: () => onQuote!.call(msg),
                  ),
                ],
                if (showRecall) ...<Widget>[
                  const SizedBox(width: AylaSpacing.sp1),
                  AylaMsgActionButton(
                    label: '撤回',
                    semanticLabel: '撤回消息',
                    icon: _actionIcon('iconUndo', 12),
                    onPressed: () => onRecall?.call(msg),
                  ),
                ],
              ],
            ),
          ),
        ),
    );
  }

  static Widget? _actionIcon(String name, double size) {
    final AylaIconData? data = aylaIconByName(name);
    return data == null ? null : AylaIcon(data, size: size);
  }
}

// ======================= 样张 =======================

AylaChatMessage _previewBubbleMessage({
  required String id,
  required AylaMessageType type,
  String content = '',
  bool self = false,
  AylaMessageStatus status = AylaMessageStatus.sent,
  bool pending = false,
  bool sendFailed = false,
  double? uploadProgress,
  AylaMediaDescriptor? media,
  AylaSharePayload? share,
  /// 距当前时间多久（默认 3 分钟；撤回窗口 120s 内的用例传 30 秒）。
  Duration ago = const Duration(minutes: 3),
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderId: self ? 'me' : 'user-2',
      type: type,
      content: content,
      mediaId: media?.mediaId,
      media: media,
      sharePayload: share,
      status: status,
      seq: 1,
      createdAt: DateTime.now().subtract(ago).toUtc().toIso8601String(),
      pending: pending,
      sendFailed: sendFailed,
      uploadProgress: uploadProgress,
    );

/// 气泡族样张。
///
/// 覆盖：他人（含发送者名 + 引用 + 操作栏）/ 自己 / 爱莉 / 撤回 / 系统 / 上传中 /
/// 发送失败 / 分享 / 媒体（图片）。操作栏在画布上以 `actionsOpen: true` 呈现
/// （等价触屏 `.is-actions-open` 展开态；桌面 hover 态由用户实测）。
Widget aylaMessageBubbleSamples() {
  aylaEnableSampleMedia();
  final AylaChatMessage other = _previewBubbleMessage(
    id: 'b1',
    type: AylaMessageType.text,
    content: '晚上一起看直播吗？我这边刚开播。',
  );
  return SingleChildScrollView(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AylaMessageBubble(
          msg: other,
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          senderOnline: true,
          quoteText: '那我先去占个位置',
          onQuoteJump: (_) {},
          onQuote: (_) {},
          // 对方消息：即使父级传了 onRecall，组件内 `canRecall` 判定也不会渲染撤回键
          onRecall: (_) {},
          actionsOpen: true,
          onToggleFavorite: (_) {},
          favoriteState: AylaFavoriteState.notFavorited,
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b2',
            type: AylaMessageType.text,
            content: '好呀，我这就来 ✨',
            self: true,
            ago: const Duration(seconds: 30), // 撤回窗口（120s）内 ⇒ 显示撤回键
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          actionsOpen: true,
          onRecall: (_) {},
          favoriteState: AylaFavoriteState.favorited,
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b3',
            type: AylaMessageType.text,
            content: '我在的～需要我帮你准备点什么吗？',
          ),
          isSelf: false,
          isElysia: true,
          senderName: '爱莉',
          senderAvatarLabel: '爱莉',
          senderOnline: true,
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b4',
            type: AylaMessageType.text,
            content: '这条已经被撤回了',
            status: AylaMessageStatus.recalled,
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b5',
            type: AylaMessageType.system,
            content: '小樱 加入了群聊',
          ),
          isSelf: false,
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b6',
            type: AylaMessageType.text,
            content: '大图上传中，稍等…',
            self: true,
            pending: true,
            uploadProgress: 42,
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          onCancel: (_) {},
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b7',
            type: AylaMessageType.text,
            content: '这条发送失败了',
            self: true,
            sendFailed: true,
          ),
          isSelf: true,
          currentUserId: 'me',
          senderAvatarLabel: '汐',
          senderOnline: true,
          onRetry: (_) {},
          onRemove: (_) {},
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b8',
            type: AylaMessageType.share,
            share: AylaSharePayload.live(
              id: '9',
              title: '今晚一起看星星',
              ownerName: '爱莉',
            ),
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
        const SizedBox(height: AylaSpacing.sp4),
        AylaMessageBubble(
          msg: _previewBubbleMessage(
            id: 'b9',
            type: AylaMessageType.image,
            media: AylaMediaDescriptor(
              mediaId: 'm-image',
              kind: AylaMediaKind.image,
              mimeType: 'image/png',
              size: 240000,
              width: 640,
              height: 480,
              thumbnail: '/api/v1/media/m-image/thumbnail',
              status: 'ready',
            ),
          ),
          isSelf: false,
          senderName: '小樱',
          senderAvatarLabel: '樱',
          onToggleFavorite: (_) {},
        ),
      ],
    ),
  );
}
