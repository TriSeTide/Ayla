/// voice 域第六批（B1-6，voice 域收尾）：语音房整页（进房态）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// VoiceRoomBody.tsx 268–326    .voice-room-body.is-panel-motion = head + layout(两张卡)
/// VoiceRoomBody.tsx 270–293    head：返回钮 .icon-btn-40（IconBack 20）· ScrollingText
///                              （Fredoka 18）· ScrollingTags（max-width 16ch）· 收藏(compact) ·
///                              分享 · 「删除房间」（房主 + onDeleteChannel）
/// VoiceRoomBody.tsx 147–184    发送：乐观 append（双向按 id 去重）+ 成功才清空（草稿 revision 守卫）；
///                              图片 = 先上传再 sendMessage(media_id)；错误文案见 165/180
/// VoiceRoomBody.tsx 113–135    房内聊天 WS 帧 `voice.chat.message`：按 id 幂等 append；
///                              **未读只在聊天栏收起且非自己发送时 +1**（tsx 130）
/// VoiceRoomBody.tsx 137–145    展开即清未读 + 列表滚到底
/// VoiceRoomBody.tsx 90–95      seenIds 上限 1000（LRU 截断）
/// VoiceRoomBody.tsx 186–205    聊天列表：HistoryControls + 每行（sender 名 + 可选图片 + 文本）
/// VoiceRoomBody.tsx 207–266    composer：图片工具钮 + textarea + 发送 + 聊天栏开关（窄屏）
/// VoiceRoomBody.tsx 291        ⚠️ `className="btn btn-danger"` —— **`.btn-danger` 全 CSS 无定义**
///                              ⇒ 实渲染是**无材质的裸 `.btn`**（用户 2026-09-21 拍板：按实渲染）
/// voice.css 12–15              .voice-room-body：height 100% · flex column · overflow hidden
/// voice.css 16–21              .voice-room-layout：flex 1 · min-height 0 · flex column
/// voice.css 23–29              .voice-room-voice-card：flex 1 · min-height 0 · column ·
///                              overflow hidden · margin sp4
/// voice.css 32–56              .voice-room-body .voice-panel：flex 1 · min-height 0 · margin 0 ·
///                              width 100% · max-width none；成员列表自滚、其余子项不收缩
/// voice.css 55–66              .voice-room-chat-card：flex none · column · relative ·
///                              border-top 1px · --glass-bg · blur(18) sat(1.4)
/// voice.css 78–124             窄屏聊天列表 = 从输入卡**上方**展开的浮层：绝对定位 bottom 100% ·
///                              h300 · --glass-bg-strong + blur18 · 只有上两角 radius 16 ·
///                              `0 -4px 16px rgba(70,91,146,.12)` · opacity/translateY(12px)/visibility
///                              `--dur-panel` 240ms --ease-out；`.is-expanded` 才显示
/// voice.css 127–136 / 325–328  .voice-room-head：flex none · center · gap sp3 · padding sp3 ·
///                              --glass-bg + blur18 · border-bottom 1px；
///                              **≥769 再加 1px 全边 + radius 16**
/// voice.css 138–143            .voice-room-title：flex 1 · min-width 0 · **font-display 18** ·
///                              --text-primary
/// voice.css 146–157            .voice-room-tags：flex 0 0 auto · **max-width 16ch**；
///                              内部 `.post-card-tag` **max-width 12ch** + 省略号
/// voice.css 202–215/…/295–313  聊天卡 head（title 13/600 secondary · count-label 12）·
///                              消息行（flex wrap · gap sp1 · 13px/1.4 · sender 700 secondary ·
///                              图片 120×80 radius-sm）
/// voice.css 233–251            .voice-room-chat-toggle-btn：flex none · gap sp1 · padding sp1/sp2 ·
///                              radius-sm · 1px 亮边 · --glass-bg · 12px secondary；
///                              :hover → `--glass-bg-hover`（**未定义 ⇒ 透明**，同 A5 裁决）+ --text-primary
/// voice.css 271–282            .voice-room-chat-count：min-width 18 · h18 · padding 0 4 · pill ·
///                              **--pink-500 底 + 白字** · 11/600
/// voice.css 318–322 / 355–360  ≥769：body padding sp4 + gap sp4 + `container-type: inline-size`；
///                              layout = **grid** `minmax(320px,1fr) minmax(320px, min(380px,45%))`
///                              + gap sp4 + overflow hidden
/// voice.css 325–346            ≥769：三分区各自动画 panel-from-top / -right / -bottom
///                              （300ms --auroraqua-ease-out）
/// voice.css 361–381            ≥769：两张卡自带材质（1px 边 + radius 16 + --glass-bg +
///                              --glass-shadow + blur24）；.voice-room-voice-card padding sp4 · margin 0
/// voice.css 382–470            ≥769：chat head 常驻、列表常驻（重置窄屏浮层定位与动画）、
///                              **chat-toggle-btn display none**、composer-row 加 border-top；
///                              `@container voice-room (max-width: 655px)` → 单列两行
/// voice.css 126–133            .voice-room-chat-card > .voice-room-composer > .composer-row：
///                              padding sp3 · align-items center · gap sp2 · width 100%
/// app.css 2131–2138            .composer-input：flex 1 · resize none · min-height 40 ·
///                              max-height 140 · padding 8 12 · line-height 22
/// app.css 2105–2123            .composer-tool-btn：40×40 pill · 1px --ice-300 边 ·
///                              hover/focus-within → --glow-500 边 + --glow-shadow
/// app.css 3473–3477            .live-form-error：--destructive 13px + margin-top sp2
/// base.css 463–472             窄屏 `.reveal`（浮入）：opacity 0 + translateY(20px) → is-in（300ms）
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 自管：`voiceWS` 帧订阅、`useCursorHistory` 分页、`uploadMediaFile` 上传、
/// `useAuthStore`、`useMediaQuery`、`usePanelReplayMotion`。Flutter 侧按既有「展示型 + 注入」：
/// - 房内聊天消息与历史分页由页面层装进 [AylaVoiceChatMessage] / [AylaVoiceChatHistory]；
/// - 发送/上传走 [AylaVoiceRoomBody.onSendText] / [onSendImage]（面板等 Future 完成，
///   成功才清空草稿、失败显示 web 同款兜底文案）；
/// - **未读计数留在面板内**：web 的规则是纯 UI 逻辑（`!chatExpanded && 非自己` ⇒ +1，
///   展开清零，seenIds 上限 1000），输入是「消息列表」本身 ⇒ 这里按 id 差集实现同一规则；
/// - 语音成员卡用 [AylaVoiceRoomBody.voicePanelBuilder] 注入：房间体只决定**材质归属档**
///   （宽屏：材质在 `.voice-room-voice-card`、`.voice-panel` 透明；窄屏：外层透明、材质归
///   `.voice-panel`——`auroraqua.css:584–610` + `voice.css:361–381`）。web 是把 11 个 props
///   直接透传给面板，而 Flutter 侧面板参数更多（成员/分页/音量回调…），故改用 builder 槽，
///   避免本组件重复声明两套注入面。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'directory_controls.dart';
import 'primitives.dart';
import 'resource_image.dart';
import 'reveal.dart';

/// 房内聊天消息投影（web `voice.chat.message` 帧 / `listVoiceChatMessagesPage` 的 item）。
class AylaVoiceChatMessage {
  const AylaVoiceChatMessage({
    required this.id,
    required this.senderNickname,
    this.senderUserId,
    this.content = '',
    this.mediaId,
    this.thumbnailUrl,
  });

  final String id;

  /// 发送者昵称（tsx 191：`{sender.nickname}：`）。
  final String senderNickname;

  /// 发送者 user id —— **未读判定用它**（web tsx 129：`String(msg.sender.user_id) === String(selfId)`）。
  final String? senderUserId;

  /// 文本内容；web 用 `content !== "图片"` 决定是否渲染文本（发图时后端写的占位文案）。
  final String content;

  /// 媒体 id（非空 = 这条带图）。
  final String? mediaId;

  /// 缩略图 URL（web `resolveMediaPath(media.thumbnail) ?? mediaContentUrl(media_id)`）。
  final String? thumbnailUrl;
}

/// 房内聊天历史（web `useCursorHistory` 投影，逐字段对应 [AylaHistoryControls]）。
class AylaVoiceChatHistory {
  const AylaVoiceChatHistory({
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.hasNewer = false,
    this.loadOlder,
    this.returnLatest,
    this.retry,
  });

  final bool loading;
  final String? error;
  final bool hasMore;
  final bool hasNewer;
  final Future<void> Function()? loadOlder;
  final Future<void> Function()? returnLatest;
  final Future<void> Function()? retry;
}

/// `.voice-room-body` —— 语音房整页（进房态）。
class AylaVoiceRoomBody extends StatefulWidget {
  const AylaVoiceRoomBody({
    super.key,
    required this.channelName,
    required this.voicePanelBuilder,
    this.channelId,
    this.selfUserId,
    this.isOwner = false,
    this.visibilityLabels = const <String>[],
    this.messages = const <AylaVoiceChatMessage>[],
    this.history = const AylaVoiceChatHistory(),
    this.favorite,
    this.share,
    this.onBack,
    this.onDeleteChannel,
    this.onSendText,
    this.onSendImage,
  });

  /// 频道名（head 中央标题）。
  final String channelName;

  /// 语音成员卡内容；参数 = **面板是否自带材质**（房间体按断点决定，见文件头）。
  final Widget Function(bool ownMaterial) voicePanelBuilder;

  /// 频道 id（null ⇒ 不渲染房内聊天卡，tsx 312）。
  final String? channelId;

  /// 当前用户 id（判未读是否是自己发的）。
  final String? selfUserId;

  /// 是否房主（决定「删除房间」）。
  final bool isOwner;

  /// 可见性标签（head 右侧 ScrollingTags；空则不渲染）。
  final List<String> visibilityLabels;

  /// 房内聊天消息（页面层按 id 幂等装配）。
  final List<AylaVoiceChatMessage> messages;

  /// 历史分页状态。
  final AylaVoiceChatHistory history;

  /// 收藏键槽（页面层给 `AylaFavoriteButton(compact: true, …)`）。
  final Widget? favorite;

  /// 分享键槽（页面层给分享按钮；null = 不渲染）。
  final Widget? share;

  /// 返回（head 左侧）。
  final VoidCallback? onBack;

  /// 删除房间（房主 + 非空才渲染；**无材质的裸 `.btn`** —— web 的 `.btn-danger` 未定义）。
  final VoidCallback? onDeleteChannel;

  /// 发送文本（页面层调用 `sendVoiceChatMessage`）；抛异常 ⇒ 显示其 message 或
  /// 「发送失败，请重试」（tsx 165）。
  final Future<void> Function(String content)? onSendText;

  /// 发送图片（页面层：选图 → 上传 → sendMessage(media_id)）；抛异常 ⇒
  /// 「图片发送失败，请重试」（tsx 180）。
  final Future<void> Function()? onSendImage;

  /// `.live-form-error`（tsx 319）。
  static const String sendErrorFallback = '发送失败，请重试';

  /// 图片发送失败的兜底文案（tsx 180）。
  static const String imageErrorFallback = '图片发送失败，请重试';

  /// tsx 110：seenIds 上限 1000。
  static const int seenIdsCap = 1000;

  /// `.voice-room-chat-list` 浮层高度（窄屏，voice.css 88）。
  static const double narrowChatListHeight = 300;

  /// `.voice-room-chat-count` 的 `99+` 截断（tsx 261）。
  static const int unreadCap = 99;

  @override
  State<AylaVoiceRoomBody> createState() => _AylaVoiceRoomBodyState();
}

class _AylaVoiceRoomBodyState extends State<AylaVoiceRoomBody> {
  bool _chatExpanded = false;
  int _unreadCount = 0;

  /// tsx 95：已见消息 id（按 id 幂等；未读只在「真正新消息」时累加）。
  final Set<String> _seenIds = <String>{};

  final TextEditingController _draft = TextEditingController();
  final ScrollController _listScroll = ScrollController();

  /// tsx 80/153：草稿 revision（发送期间用户又改动 ⇒ 不清空）。
  int _draftRevision = 0;

  bool _sending = false;
  bool _uploading = false;
  String? _error;

  /// tsx 75：`voice-chat:{user}:{channel}` —— 换人/换房即重置全部聊天态。
  String get _chatOwner => 'voice-chat:${widget.selfUserId ?? ''}:${widget.channelId ?? ''}';
  String _ownerOfLastBuild = '';

  @override
  void initState() {
    super.initState();
    _ownerOfLastBuild = _chatOwner;
    // tsx 108–111：初次装配的消息视为「已见」（历史首屏不产生未读）
    for (final AylaVoiceChatMessage m in widget.messages) {
      _seenIds.add(m.id);
    }
  }

  @override
  void didUpdateWidget(AylaVoiceRoomBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tsx 101–107：chatOwner（换人/换房）变化 ⇒ 清空 seenIds / 未读 / 错误 / busy
    if (_chatOwner != _ownerOfLastBuild) {
      _ownerOfLastBuild = _chatOwner;
      _seenIds
        ..clear()
        ..addAll(widget.messages.map((AylaVoiceChatMessage m) => m.id));
      _unreadCount = 0;
      _error = null;
      _sending = false;
      _uploading = false;
      return;
    }
    // tsx 123–132：消息列表里出现**新 id** ⇒ 「聊天栏收起、且非自己发送」才累加未读；
    // 上限 1000（tsx 110）。didUpdateWidget 紧接 build ⇒ 直接改字段即可。
    for (final AylaVoiceChatMessage m in widget.messages) {
      if (_seenIds.add(m.id) == false) continue; // 已见
      if (!_chatExpanded && (widget.selfUserId == null || m.senderUserId != widget.selfUserId)) {
        _unreadCount++;
      }
    }
    while (_seenIds.length > AylaVoiceRoomBody.seenIdsCap) {
      _seenIds.remove(_seenIds.first);
    }
  }

  void _toggleChat() {
    setState(() {
      _chatExpanded = !_chatExpanded;
      if (_chatExpanded) _unreadCount = 0; // tsx 141
    });
    if (_chatExpanded) {
      // tsx 142–143：展开时滚到底
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_listScroll.hasClients) {
          _listScroll.jumpTo(_listScroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _sendText() async {
    final Future<void> Function(String)? send = widget.onSendText;
    final String content = _draft.text.trim();
    if (send == null || _sending || _uploading || content.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final int revision = _draftRevision;
    try {
      await send(content);
      // tsx 163：期间草稿没被改过才清空
      if (mounted && _draftRevision == revision) _draft.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AylaVoiceChatSendException ? e.message : AylaVoiceRoomBody.sendErrorFallback);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendImage() async {
    final Future<void> Function()? send = widget.onSendImage;
    if (send == null || _sending || _uploading) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      await send();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AylaVoiceChatSendException ? e.message : AylaVoiceRoomBody.imageErrorFallback);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  bool get _busy => _sending || _uploading;

  bool get _wide => MediaQuery.sizeOf(context).width > Breakpoint.sm;

  @override
  Widget build(BuildContext context) {
    final bool wide = _wide;
    final Widget head = _buildHead(context, wide);
    final Widget voiceCard = _buildVoiceCard(wide);
    final Widget? chatCard =
        widget.channelId == null ? null : _buildChatCard(context, wide);

    // ---- 入场（voice.css 325–346 宽屏三分区按边缘入；base.css 463 窄屏统一浮入 20px）----
    Widget reveal(Widget child, Offset offset) => AylaRevealItem(
          offset: wide ? offset : const Offset(0, 20),
          delay: Duration.zero, // web 无 stagger（三块同时）
          child: child,
        );

    final List<Widget> layoutChildren = <Widget>[
      reveal(voiceCard, const Offset(0, 20)), // panel-from-bottom
      if (chatCard != null) reveal(chatCard, const Offset(20, 0)), // panel-from-right
    ];

    return Container(
      // `.voice-room-body`：height 100% · flex column · overflow hidden；
      // ≥769 另加 padding sp4 + gap sp4（voice.css 318–322）
      padding: wide
          ? const EdgeInsets.all(AylaSpacing.sp4)
          : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: wide ? AylaSpacing.sp4 : 0,
        children: <Widget>[
          reveal(head, const Offset(0, -20)), // panel-from-top
          Expanded(child: _buildLayout(wide, layoutChildren)),
        ],
      ),
    );
  }

  /// `.voice-room-layout`：窄屏 flex column；宽屏 grid 两列（+ `@container` 655 单列两行）。
  Widget _buildLayout(bool wide, List<Widget> children) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: children.first),
          if (children.length > 1) children[1],
        ],
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // `@container voice-room (max-width: 655px)` → 单列两行（上下排列）
        if (c.maxWidth <= 655) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp4,
            children: <Widget>[
              for (final Widget child in children) Expanded(child: child),
            ],
          );
        }
        // grid：minmax(320px, 1fr) + minmax(320px, min(380px, 45%))
        // （`channelId == null` 时 web 的第二列是空的 ⇒ 语音卡独占第一列）
        final double chatWidth = (c.maxWidth * 0.45).clamp(320.0, 380.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AylaSpacing.sp4,
          children: <Widget>[
            Expanded(child: children.first),
            if (children.length > 1) SizedBox(width: chatWidth, child: children[1]),
          ],
        );
      },
    );
  }

  /// header.voice-room-head（窄屏只有下边框；宽屏另加 1px 全边 + radius 16）。
  Widget _buildHead(BuildContext context, bool wide) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<Widget> children = <Widget>[
      AylaIconButton(
        icon: AylaIcon(aylaIconByName('iconBack')!, size: 20),
        semanticLabel: '返回', // tsx 271 aria-label
        onPressed: widget.onBack,
      ),
      if (widget.visibilityLabels.isNotEmpty)
        ConstrainedBox(
          // `.voice-room-head .voice-room-tags { max-width: 16ch }`
          constraints: BoxConstraints(maxWidth: _ch16(context, t)),
          child: AylaScrollingTags(
            children: <Widget>[
              for (final String label in widget.visibilityLabels)
                ConstrainedBox(
                  // `.post-card-tag { max-width: 12ch }` + 省略号
                  constraints: BoxConstraints(maxWidth: _postTag12ch()),
                  child: AylaCapsuleTag(
                    // 与 `.post-card-tag` 同档（post_card.dart:341–352 逐参数一致）
                    label,
                    tone: CapsuleTone.ice,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    fontFamily: AylaFonts.utility,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0, // web 未声明 letter-spacing
                    textHeight: 1.55, // 继承 body 行高（post_card 同档）
                  ),
                ),
            ],
          ),
        ),
      if (widget.favorite != null) widget.favorite!,
      if (widget.share != null) widget.share!,
      if (widget.isOwner && widget.onDeleteChannel != null)
        _BareButton(
          // ⚠️ tsx 291 的 `.btn-danger` **全 CSS 无定义** ⇒ 实渲染为无材质的裸 `.btn`
          //（用户 2026-09-21 拍板按实渲染；与 A5 的 `--glass-bg-hover` 同类）
          label: '删除房间',
          onPressed: widget.onDeleteChannel,
        ),
    ];
    // 标题占满剩余（`.voice-room-title { flex: 1; min-width: 0 }`）⇒ 插到返回钮之后
    children.insert(
      1,
      Expanded(
        child: AylaScrollingText(
          text: widget.channelName,
          // `.voice-room-title { font-family: var(--font-display); font-size: 18px }`
          style: const TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 18,
            color: AylaColors.textPrimary,
          ),
        ),
      ),
    );

    return GlassSurface(
      radiusOverride: wide
          ? BorderRadius.all(Radius.circular(AylaRadii.rCard))
          : BorderRadius.zero,
      blur: AylaGlass.blurNav, // blur(18px) saturate(1.4)
      shadow: const <BoxShadow>[], // 阴影只随 --glass-shadow token 出现；此处未声明
      border: !wide, // 窄屏只有下边框
      borderOverride: wide
          ? Border.all(color: AylaColors.glassBorder)
          : const Border(bottom: BorderSide(color: AylaColors.glassBorder)),
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      child: Row(
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: children,
      ),
    );
  }

  /// section.voice-room-voice-card（宽屏自带材质 + padding sp4；窄屏透明、材质归面板）。
  Widget _buildVoiceCard(bool wide) {
    final Widget panel = widget.voicePanelBuilder(!wide);
    if (!wide) {
      // 窄屏：`.voice-room-voice-card` 透明（auroraqua.css 584–589），材质在 `.voice-panel`
      return ColoredBox(
        color: const Color(0x00000000),
        child: panel,
      );
    }
    return GlassSurface(
      // ≥769：1px 边 + radius 16 + --glass-bg + --glass-shadow + blur24（voice.css 361–375）
      radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.glass,
      padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
      child: panel,
    );
  }

  /// section.voice-room-chat-card（窄屏 = 底部输入卡 + 上方浮层；宽屏 = 卡内常驻列表）。
  Widget _buildChatCard(BuildContext context, bool wide) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    final Widget list = SingleChildScrollView(
      controller: _listScroll,
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AylaSpacing.sp1,
        children: <Widget>[
          AylaHistoryControls(
            loading: widget.history.loading,
            error: widget.history.error,
            hasMore: widget.history.hasMore,
            hasNewer: widget.history.hasNewer,
            loadOlder: widget.history.loadOlder ?? () async {},
            returnLatest: widget.history.returnLatest ?? () async {},
            retry: widget.history.retry ?? () async {},
          ),
          for (final AylaVoiceChatMessage m in widget.messages)
            _buildMessage(context, m),
        ],
      ),
    );

    final Widget composer = Container(
      // `.voice-room-composer { flex: none }`；其 `.composer-row` 见 voice.css 126–133
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      decoration: wide
          ? const BoxDecoration(
              // ≥769：composer-row 加 border-top（voice.css 419–422）
              border: Border(top: BorderSide(color: AylaColors.glassBorder)),
            )
          : null,
      child: Row(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          AylaToolButton(
            icon: AylaIcon(aylaIconByName('iconImage')!, size: 18), // tsx 217
            semanticLabel: '发送房内图片', // tsx 216
            onPressed: _busy ? null : () => unawaited(_sendImage()),
          ),
          Expanded(
            child: GlassInput(
              controller: _draft,
              hintText: '在语音房内聊天', // tsx 239
              minHeight: 40, // `.composer-input { min-height: 40px }`
              minLines: 1,
              maxLines: 6, // `max-height: 140px` / `line-height: 22px` ≈ 6 行
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: t.body.copyWith(fontSize: 14, height: 22 / 14),
              enabled: !_busy,
              semanticLabel: '在语音房内聊天',
              // 受控组件：文本变化即重建（发送钮 disabled 依赖 `text.trim()`，同 web）
              onChanged: (_) => setState(() => _draftRevision++),
              onSubmitted: (_) => unawaited(_sendText()),
            ),
          ),
          GlassButton(
            label: '',
            icon: AylaIcon(aylaIconByName('iconSend')!, size: 15), // tsx 250
            variant: GlassButtonVariant.primary,
            minHeight: 40,
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            semanticLabel: '发送语音房消息', // tsx 248
            onPressed: (_busy || _draft.text.trim().isEmpty)
                ? null
                : () => unawaited(_sendText()),
          ),
          if (!wide) _buildChatToggle(context, t),
        ],
      ),
    );

    final Widget card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        // 窄屏：浮层锚点在**卡片顶部**（`bottom: 100%`），故放在最前面（零高、不参与布局）
        if (!wide)
          _NarrowChatOverlay(
            expanded: _chatExpanded,
            height: AylaVoiceRoomBody.narrowChatListHeight,
            child: list,
          ),
        // `.voice-room-chat-card-head { display: none }`（窄屏）⇒ 只在宽屏渲染
        if (wide)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp3,
            ),
            decoration: const BoxDecoration(
              color: Color(0x8CFFFAFB), // --glass-bg（宽屏 head 自带该底）
              border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
            ),
            child: Row(
              children: <Widget>[
                Text(
                  '房内聊天', // tsx 315
                  style: t.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.messages.length} 条消息', // tsx 316
                  style: t.body.copyWith(
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        // 列表：宽屏 = 常驻并吃掉剩余高度；窄屏已作为浮层挂在顶部锚点
        if (wide) Expanded(child: list),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(
              left: AylaSpacing.sp3,
              right: AylaSpacing.sp3,
              top: AylaSpacing.sp2,
            ),
            child: Text(
              _error!, // `.live-form-error`（app.css 3473–3477）
              style: t.body.copyWith(
                fontSize: 13,
                color: AylaColors.destructive,
              ),
            ),
          ),
        composer,
      ],
    );

    if (!wide) {
      // 窄屏：`.voice-room-chat-card` = 只有上边框 + --glass-bg + blur(18) sat(1.4)（voice.css 55–66）
      // ⚠️ 必须走库内 GlassSurface（它内部已用 ClipRect 包住 BackdropFilter）；
      //    手搓裸 `BackdropFilter` 会把**整块画布**都糊掉（用户 2026-09-21 实报「遮罩把整个
      //    大画布都遮住了」）——Flutter 的 BackdropFilter 未裁剪时过滤的是整个 backdrop。
      return GlassSurface(
        radiusOverride: BorderRadius.zero,
        blur: AylaGlass.blurNav, // blur(18px) saturate(1.4)
        strong: false, // --glass-bg
        shadow: const <BoxShadow>[], // 该卡未声明 box-shadow
        borderOverride: const Border(
          top: BorderSide(color: AylaColors.glassBorder),
        ),
        padding: EdgeInsets.zero,
        child: card,
      );
    }
    return GlassSurface(
      // ≥769：1px 边 + radius 16 + --glass-bg + --glass-shadow + blur24
      radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.glass,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        child: card,
      ),
    );
  }

  /// 窄屏聊天栏开关（`.voice-room-chat-toggle-btn`；宽屏 `display: none`）。
  Widget _buildChatToggle(BuildContext context, AylaTextStyles t) {
    // `:hover { background: var(--glass-bg-hover) }` —— 该 token **全历史未定义**
    // ⇒ 实渲染为**透明**（同 A5 裁决）；零透明写同色相避免灰闪。
    return _HoverableChatToggle(
      expanded: _chatExpanded,
      unread: _unreadCount,
      semanticLabel: _chatExpanded ? '收起聊天' : '展开聊天', // tsx 256
      onPressed: _toggleChat,
      child: Row(
        spacing: AylaSpacing.sp1, // gap: var(--sp-1)
        children: <Widget>[
          Text(
            _chatExpanded ? '▼' : '▲', // tsx 259
            style: t.body.copyWith(
              fontSize: 12,
              color: AylaColors.textSecondary,
            ),
          ),
          if (_unreadCount > 0)
            // `.voice-room-chat-count`：18/11/600/--pink-500 白字（库内 TabBadge 各档
            // metrics 都不符 ⇒ 私有实现）
            Container(
              constraints: const BoxConstraints(minWidth: 18),
              height: 18,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: AylaColors.pink500,
                borderRadius: AylaRadii.pill,
              ),
              alignment: Alignment.center,
              child: Text(
                _unreadCount > AylaVoiceRoomBody.unreadCap
                    ? '${AylaVoiceRoomBody.unreadCap}+'
                    : '$_unreadCount',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, AylaVoiceChatMessage m) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Wrap(
      // `.voice-room-chat-message`：flex wrap · gap sp1 · 13px/1.4
      spacing: AylaSpacing.sp1,
      runSpacing: AylaSpacing.sp1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '${m.senderNickname}：', // tsx 191
          style: t.body.copyWith(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w700,
            color: AylaColors.textSecondary,
          ),
        ),
        if (m.mediaId != null && m.thumbnailUrl != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            child: SizedBox(
              width: 120, // `.voice-room-chat-image { width: 120px; max-height: 80px }`
              height: 80,
              child: ResourceImage(
                src: m.thumbnailUrl!,
                fit: BoxFit.cover, // `.voice-room-chat-image { object-fit: cover }`
              ),
            ),
          ),
        if (m.content != '图片') // tsx 201：发图时后端写的占位文案不重复渲染
          Text(
            m.content,
            style: t.body.copyWith(
              fontSize: 13,
              height: 1.4,
              color: AylaColors.textPrimary,
            ),
          ),
      ],
    );
  }

  /// `.voice-room-tags` 的 `max-width: 16ch`（在该容器的字体下实测 `0` 的宽度 × 16）。
  double _ch16(BuildContext context, AylaTextStyles t) {
    final TextPainter p = TextPainter(
      text: TextSpan(text: '0', style: t.body),
      textDirection: TextDirection.ltr,
    )..layout();
    return p.width * 16;
  }

  /// `.post-card-tag` 的 `max-width: 12ch`（Space Grotesk 11 / w600 / ls 0）。
  double _postTag12ch() {
    final TextPainter p = TextPainter(
      text: const TextSpan(
        text: '0',
        style: TextStyle(
          fontFamily: AylaFonts.utility,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return p.width * 12;
  }
}

/// 无材质的裸 `.btn`（`.btn-danger` 在 web 未定义 ⇒ 只有 `.btn` 盒模型与居中文字）。
class _BareButton extends StatelessWidget {
  const _BareButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40), // `.btn { min-height: 40px }`
        padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AylaRadii.rInput)),
        foregroundColor: AylaColors.textPrimary,
        textStyle: t.body.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      child: Text(label),
    );
  }
}

/// 窄屏聊天栏开关（`.voice-room-chat-toggle-btn`）。
class _HoverableChatToggle extends StatefulWidget {
  const _HoverableChatToggle({
    required this.expanded,
    required this.unread,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
  });

  final bool expanded;
  final int unread;
  final String semanticLabel;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_HoverableChatToggle> createState() => _HoverableChatToggleState();
}

class _HoverableChatToggleState extends State<_HoverableChatToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // tsx 257：`aria-expanded`
      expanded: widget.expanded,
      button: true,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AylaDurations.fast,
            curve: AylaCurves.easeOut,
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp2,
              vertical: AylaSpacing.sp1,
            ),
            decoration: BoxDecoration(
              // hover → `--glass-bg-hover`（未定义 ⇒ 透明；零透明同色相）
              color: _hovered
                  ? AylaColors.glassBg.withValues(alpha: 0)
                  : AylaColors.glassBg,
              borderRadius: BorderRadius.circular(AylaRadii.rSm),
              border: Border.all(color: AylaColors.glassBorder),
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: _hovered ? AylaColors.textPrimary : AylaColors.textSecondary,
              ),
              child: IconTheme(
                data: IconThemeData(
                  color: _hovered ? AylaColors.textPrimary : AylaColors.textSecondary,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窄屏聊天列表浮层：绝对定位在输入卡**上方**（`bottom: 100%`），h300，进出 240ms。
class _NarrowChatOverlay extends StatelessWidget {
  const _NarrowChatOverlay({
    required this.expanded,
    required this.height,
    required this.child,
  });

  final bool expanded;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration d = reduceMotion ? Duration.zero : AylaDurations.panel; // 240ms
    // ⚠️ 用 `SizedBox(height: 0)` + `OverflowBox(alignment: bottomCenter)` 表达
    // `position: absolute; bottom: 100%`：零高占位锚在卡片**顶部**，浮层向上溢出绘制
    // （不用 `Stack`：它在竖向无界父级里会直接报「requires bounded constraints」）。
    return SizedBox(
      height: 0,
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: height,
        maxHeight: height,
        child: IgnorePointer(
          ignoring: !expanded,
          child: ExcludeSemantics(
            excluding: !expanded,
            child: AnimatedOpacity(
              opacity: expanded ? 1 : 0,
              duration: d,
              curve: AylaCurves.easeOut,
              child: TweenAnimationBuilder<double>(
                // `transform: translateY(12px)` → 0（voice.css 108/118）
                tween: Tween<double>(end: expanded ? 0 : 12),
                duration: d,
                curve: AylaCurves.easeOut,
                builder: (BuildContext context, double dy, Widget? c) =>
                    Transform.translate(offset: Offset(0, dy), child: c),
                child: SizedBox(
                  height: height,
                  child: GlassSurface(
                    // --glass-bg-strong + blur18 sat1.4 + 只有上两角 radius 16 +
                    // `box-shadow: 0 -4px 16px rgba(70,91,146,.12)`（voice.css 92–100）
                    strong: true,
                    blur: AylaGlass.blurNav,
                    radiusOverride: const BorderRadius.only(
                      topLeft: Radius.circular(AylaRadii.rCard),
                      topRight: Radius.circular(AylaRadii.rCard),
                    ),
                    shadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1F465B92),
                        blurRadius: 16,
                        offset: Offset(0, -4),
                      ),
                    ],
                    borderOverride: Border.all(color: AylaColors.glassBorder),
                    padding: EdgeInsets.zero,
                    child: child,
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

/// 发送失败时由页面层抛出以给出精确文案（等价 web 的 `err.message`，tsx 165/180）。
class AylaVoiceChatSendException implements Exception {
  const AylaVoiceChatSendException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ======================= 预览 =======================

/// 语音房整页样张（画布与 @Preview 共用；**可交互**）。
///
/// - 宽屏（≥769）与窄屏（≤768）各一块：宽屏 = 两列 grid + 三分区按边缘入场；
///   窄屏 = 上下堆叠 + 聊天列表浮层（点右下开关展开，未读红点见上）；
/// - 房内聊天可发文本（空文本禁用发送）、点图片钮模拟上传、可看错误文案；
/// - 「删除房间」只在房主档出现（**无材质的裸 `.btn`**，见文件头）。
Widget aylaVoiceRoomBodySamples() => const _VoiceRoomBodyDemo();

class _VoiceRoomBodyDemo extends StatefulWidget {
  const _VoiceRoomBodyDemo();

  @override
  State<_VoiceRoomBodyDemo> createState() => _VoiceRoomBodyDemoState();
}

class _VoiceRoomBodyDemoState extends State<_VoiceRoomBodyDemo> {
  final List<AylaVoiceChatMessage> _messages = <AylaVoiceChatMessage>[
    const AylaVoiceChatMessage(
      id: 'm1',
      senderNickname: '爱莉',
      content: '我在呢～',
    ),
    const AylaVoiceChatMessage(
      id: 'm2',
      senderNickname: '汐汐',
      content: '今晚聊点什么呢',
    ),
  ];
  int _seq = 3;
  bool _failNext = false;

  Future<void> _send(String content) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (_failNext) throw const AylaVoiceChatSendException('房内聊天暂不可用');
    setState(() {
      _messages.add(AylaVoiceChatMessage(
        id: 'm${_seq++}',
        senderNickname: '汐汐',
        content: content,
      ));
    });
  }

  Future<void> _sendImage() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    setState(() {
      _messages.add(AylaVoiceChatMessage(
        id: 'm${_seq++}',
        senderNickname: '汐汐',
        content: '图片',
        mediaId: 'media-1',
        thumbnailUrl: null, // 无图源时不渲染缩略图（与 web 的 `message.media` 判定一致）
      ));
    });
  }

  Widget _body({required bool owner}) {
    return AylaVoiceRoomBody(
      channelName: '深夜电台 · 爱莉的语音房',
      channelId: 'v1',
      selfUserId: 'self',
      isOwner: owner,
      visibilityLabels: const <String>['公开', '冰樱研究社'],
      messages: _messages,
      history: const AylaVoiceChatHistory(hasMore: true),
      favorite: const SizedBox.shrink(), // 样张不接收藏状态
      onBack: () {},
      onDeleteChannel: owner ? () {} : null,
      onSendText: _send,
      onSendImage: _sendImage,
      voicePanelBuilder: (bool ownMaterial) => SizedBox(
        // 样张里用一块占位说明面板位置（真实面板 = AylaVoiceChannelPanel，见 B1-4 分区）
        child: Center(
          child: Text(
            'AylaVoiceChannelPanel(roomContext: true, ownMaterial: $ownMaterial)\n'
            '（真实面板见 B1-4 分区；房间体只决定材质归属档）',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _stage(
          const Size(1200, 620),
          '宽屏 1200（≥769）：body padding sp4 + gap sp4；layout = grid 两列；三分区按边缘入场；'
          'chat head 与列表常驻、开关钮隐藏；「删除房间」= 房主档才有（裸 .btn，无材质）',
          _body(owner: true),
        ),
        _stage(
          const Size(420, 700),
          '窄屏 420（≤768）：无 padding；head 只有下边框；卡片上下堆叠；'
          '聊天 = 底部输入卡 + 上方浮层（点右下 ▲ 展开，浮层 300 高、只有上两角圆角）',
          _body(owner: false),
        ),
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              const Text('开关：让下一次文本发送失败（看 .live-form-error）',
                  style: TextStyle(fontSize: 11)),
              GlassButton(
                label: _failNext ? '下一次发送：失败' : '下一次发送：成功',
                variant: GlassButtonVariant.ghost,
                minHeight: 32,
                fontSize: 12,
                onPressed: () => setState(() => _failNext = !_failNext),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stage(Size viewport, String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 语音房整页（宽屏 / 窄屏 / 房主档）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '语音房整页（head + 成员卡 + 房内聊天）',
  size: Size(1800, 800),
  wrapper: previewTheme,
)
Widget aylaVoiceRoomBodyPreview() => aylaVoiceRoomBodySamples();
