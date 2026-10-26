/// 语音房整页（进房态）。
///
/// ## 事实源
/// ```
/// VoiceRoomBody.tsx 268–326    .voice-room-body.is-panel-motion = head + layout(两张卡)
/// VoiceRoomBody.tsx 270–293    head：返回钮 .icon-btn-40（IconBack 20）· ScrollingText
///                              （Fredoka 18）· ScrollingTags（max-width 16ch）· 收藏(compact) ·
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/voice/voice_room_body.dart` 一节）
/// ```
///
/// ## 机制差异
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
///
/// ## 有意偏离 web（两处，均已登记）
///
/// ### ① 房内聊天图片**可点开**大图（用户实报裁决，2026-10-24）
///
/// web 的房内聊天图**没有点击行为**：`VoiceRoomBody.tsx:192–200` 只渲染
/// `<ResourceImage src=… className="voice-room-chat-image" />`，**没有 onClick**、
/// 也没有 `ImageViewer`（对比同仓库的聊天域 `MediaContent.tsx:140`、弹幕
/// `DanmakuList.tsx:131` 都挂了 `<ImageViewer>`）。
/// 用户实报「语音房里的图片点不开」，裁决为**在 Flutter 侧补上**：
/// 点击 → 库内既有 [AylaImageViewer]（与弹幕图片完全同一交互/保存能力）。
/// 除「可点」外的一切（120×80 / radius-sm / object-fit cover / 图源解析）与 web 逐值一致。
///
/// ### ② 窄屏聊天浮层的**命中语义**（不是视觉，见 [_NarrowChatOverlay]）
///
/// 视觉与 web 一比一（`--glass-bg-strong` + blur18 sat1.4 + 上两角 radius 16 +
/// `0 -4px 16px rgba(70,91,146,.12)` + 240ms + translateY(12px)），
/// 但**实现手段必须偏离**：web 用 CSS absolute（浏览器按绘制后几何命中），
/// Flutter 的 `OverflowBox` 溢出部分**永远收不到指针**（`RenderBox.hitTest` 先判
/// `_size.contains(position)`）⇒ 浮层改挂在**语音卡槽的 Stack** 里
/// （`Positioned(bottom: 0, height: 300)`，槽底边 = 聊天卡顶边 ⇒ 与 `bottom: 100%`
/// 几何重合，且祖先盒覆盖那 300px）—— 完整推导见 [_NarrowChatOverlay]。
///
/// ## 公开面
/// `AylaVoiceChatMessage` · `AylaVoiceChatHistory` · `AylaVoiceRoomBody` · `AylaVoiceChatSendException` · 样张 `aylaVoiceRoomBodySamples()`

library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../../core/models/media_kind.dart' show AylaMediaKind;
import '../../core/models/post.dart' show AylaMediaDescriptor;
import '../base/overlays.dart' show aylaOverlayEntry;
import '../base/safe_area.dart' show AylaTopInsetGap;
import '../base/directory_controls.dart';
import '../base/primitives.dart';
import '../base/resource_image.dart';
import '../base/reveal.dart';
import '../base/share.dart' show AylaShareButton;
import '../chat/image_viewer.dart' show AylaImageViewer;

/// 房内聊天消息投影（web `voice.chat.message` 帧 / `listVoiceChatMessagesPage` 的 item）。
class AylaVoiceChatMessage {
  const AylaVoiceChatMessage({
    required this.id,
    required this.senderNickname,
    this.senderUserId,
    this.content = '',
    this.mediaId,
    this.thumbnailUrl,
    this.media,
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

  /// 媒体描述符（点开大图查看器用；null = 调用方未给 ⇒ 由 [mediaId] 兜底构造）。
  ///
  /// web 侧房内聊天图**不可点**（`VoiceRoomBody.tsx:192–200` 的 `ResourceImage`
  /// 没有 onClick）—— 见文件头「有意偏离」段。
  final AylaMediaDescriptor? media;
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
    this.topInset = true,
  });

  /// 头部是否自己让出**顶部状态栏**（默认 true）。
  ///
  /// 群内语音（`/group/:id/voice/:cid`）传 `false`：群页已渲染 `AylaGroupTopTabs`，
  /// 状态栏由群顶栏覆盖着色，房内头部再让一次会在两者之间多出一条空白色带
  /// （2026-10-19 用户实拍）。
  final bool topInset;

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

  /// 房内聊天图片的大图查看器宿主（见 [_openImage]）。
  final _VoiceChatViewerHost _viewer = _VoiceChatViewerHost();

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
    _viewer.close();
    _draft.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  /// 点开房内聊天图片（**有意偏离 web**，见文件头「有意偏离 · 房内聊天图片可点开」）。
  void _openImage(AylaVoiceChatMessage m) {
    final String? mediaId = m.mediaId;
    if (mediaId == null) return;
    _viewer.open(
      context,
      m.media ??
          AylaMediaDescriptor(
            mediaId: mediaId,
            kind: AylaMediaKind.image,
            thumbnail: m.thumbnailUrl,
          ),
      m.content.isEmpty ? '房内聊天图片' : m.content,
    );
  }

  bool get _busy => _sending || _uploading;

  bool get _wide => MediaQuery.sizeOf(context).width > AylaBreakpoints.sm;

  @override
  Widget build(BuildContext context) {
    final bool wide = _wide;
    final Widget head = _buildHead(context, wide);
    final Widget voiceCard = _buildVoiceCard(wide);
    final Widget? chatCard =
        widget.channelId == null ? null : _buildChatCard(context, wide);

    // ---- 入场（voice.css 325–346 宽屏三分区按边缘入；base.css 463 窄屏统一浮入 20px）----
    Widget reveal(Widget child, Offset offset) => AylaRevealItem(
          fadeGlass: false,
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
      // 窄屏：语音卡槽 Expanded + 聊天输入卡列。
      // 聊天浮层 `position: absolute; bottom: 100%` 挂在**语音卡槽的 Stack** 里：
      // 该槽底边 = 聊天卡顶边（二者在 Column 里相邻、gap 0），所以
      // `Positioned(left:0, right:0, bottom:0) + 300 高` 与 CSS 的
      // `bottom: 100%` 几何完全重合，而**祖先盒覆盖了那 300px**
      // ⇒ 浮层内部可正常命中（OverflowBox 的根因见 [_buildNarrowOverlay]）。
      // `Clip.none`：浮层只在本槽内部（底边对齐、向上 300 高，槽本身更高），
      // 不会越出槽；仍然显式给 none，避免未来槽变矮时被硬裁。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(child: children.first),
                if (children.length > 1 && widget.channelId != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: AylaVoiceRoomBody.narrowChatListHeight,
                    child: _buildNarrowOverlay(context),
                  ),
              ],
            ),
          ),
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
                // 来源标签：**共享件 `AylaSourceTag`**（裁决统一三域，
                // 粉色；它自带 `max-width: 12ch` 实测换算）。
                // ⚠️ 不再复刻 `.post-card-tag` 的 ice-100 灰底（`--ice-600` 零定义、
                // 用户判为错误）。容器 `.voice-room-tags { max-width: 16ch }` 不变。
                AylaSourceTag(label),
            ],
          ),
        ),
      if (widget.favorite != null) widget.favorite!,
      if (widget.share != null) widget.share!,
      if (widget.isOwner && widget.onDeleteChannel != null)
        _BareButton(
          // ⚠️ tsx 291 的 `.btn-danger` **全 CSS 无定义** ⇒ 实渲染为无材质的裸 `.btn`
          //（拍板按实渲染；与 A5 的 `--glass-bg-hover` 同类）
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

    return AylaGlassSurface(
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
      // 窄屏：状态栏高度放在**玻璃材质内部**（顶部），让磨砂底与顶栏连成一片。
      // 不能是外层裸留白 —— 否则状态栏区露出极光背景，与玻璃头之间出现色带。
      // 详见 `widgets/base/safe_area.dart` 的库文档。宽屏无状态栏遮挡，占位恒 0。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!wide && widget.topInset) const AylaTopInsetGap(),
          Row(
            spacing: AylaSpacing.sp3, // gap: var(--sp-3)
            children: children,
          ),
        ],
      ),
    );
  }

  /// section.voice-room-voice-card（宽屏自带材质 + padding sp4；窄屏透明 + **margin sp4**）。
  Widget _buildVoiceCard(bool wide) {
    final Widget panel = widget.voicePanelBuilder(!wide);
    if (!wide) {
      // 窄屏：`.voice-room-voice-card` 透明（auroraqua.css 584–589），材质在 `.voice-panel`；
      // **但保留它自己的 `margin: var(--sp-4)`**（voice.css 23-30，默认断点、无媒体查询）。
      //
      // 这一条曾被整条漏掉（2026-10-23 用户实报「群内群外语音房窄屏界面中部内容区
      // 上下左右不留空」）：voice.css 里该 margin 只在 `@media (min-width: 769px)` 的
      // 372-375 行被改成 `margin: 0; padding: var(--sp-4)` ⇒ 窄屏是 16px 外边距，
      // 宽屏才是 0 外边距 + 16 内边距。当时只实现宽屏档，窄屏返回裸 ColoredBox
      // ⇒ 四边各少 16px（宽 32 / 高 32）。
      //
      // 等价表达：CSS margin 在 flex 子项上的占位语义 = 布局空白 ⇒ Flutter 用 Padding
      //（本件在 Expanded 槽内，四边内缩与 margin 同效）。
      // 不能改 `_buildLayout` 的 spacing：web 窄屏 `.voice-room-layout` 的 gap 确实是 0
      //（只有 >=769 的 354 行才给 16）。也不给 chat card 加：它是通栏条（voice.css 55-66）。
      return Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp4), // voice.css 29 margin: var(--sp-4)
        child: ColoredBox(
          color: const Color(0x00000000),
          child: panel,
        ),
      );
    }
    return AylaGlassSurface(
      // ≥769：1px 边 + radius 16 + --glass-bg + --glass-shadow + blur24（voice.css 361–375）
      radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.glass,
      padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
      child: panel,
    );
  }

  /// `.voice-room-chat-list`（滚动容器 = 历史控件 + 消息行，voice.css 285–293）。
  ///
  /// 两档共用：宽屏放进卡片内常驻，窄屏装进浮层（[`_NarrowChatOverlay`]）。
  Widget _buildChatList(BuildContext context) {
    return SingleChildScrollView(
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
  }

  /// 窄屏浮层（`.voice-room-chat-card > .voice-room-chat-list`，voice.css 72–105）。
  ///
  /// ⚠️ **浮层不能挂在聊天卡内部**（这是 2026-10-24「点击穿透」修复的关键）：
  /// `RenderBox.hitTest` 先判 `_size.contains(position)`（`rendering/box.dart:2952`），
  /// 且**每个祖先盒都要包含该点**才会继续往下走。浮层向上溢出聊天卡 300px，
  /// 落在**语音卡那个 Expanded 槽**的矩形里 —— 若浮层是聊天卡的后代，
  /// 命中在聊天卡这一层就被截断（点不到），再叠加 `OverflowBox` 零高盒
  /// 就等于完全不可命中 = 用户看到的「穿透」。
  /// ⇒ 由 [`_buildLayout`] 把它 `Positioned` 在**语音卡槽**的 `bottom: 0`
  /// （该槽底边 = 聊天卡顶边 ⇒ 视觉上就是 CSS `bottom: 100%`），祖先盒与绘制盒一致。
  Widget _buildNarrowOverlay(BuildContext context) {
    return _NarrowChatOverlay(
      expanded: _chatExpanded,
      height: AylaVoiceRoomBody.narrowChatListHeight,
      child: _buildChatList(context),
    );
  }

  /// section.voice-room-chat-card（窄屏 = 底部输入卡 + 上方浮层；宽屏 = 卡内常驻列表）。
  Widget _buildChatCard(BuildContext context, bool wide) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    final Widget list = _buildChatList(context);

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
            child: AylaGlassInput(
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
          AylaGlassButton(
            label: '',
            icon: AylaIcon(aylaIconByName('iconSend')!, size: 15), // tsx 250
            variant: AylaGlassButtonVariant.primary,
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
        // 窄屏浮层**不在这里**：它向上溢出聊天卡 300px，必须挂在
        // 「语音卡槽」那一层才可命中（见 [_buildNarrowOverlay] 的注释）。
        // `.voice-room-chat-card-head { display: none }`（窄屏）⇒ 只在宽屏渲染
        if (wide)
          Container(
            // voice.css 389–397（≥769）：flex none / center / space-between /
            // `gap: var(--sp-2)` / `padding: var(--sp-3) var(--sp-4)` /
            // `border-bottom: 1px solid var(--glass-border)` / `background: var(--glass-bg)`
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp3,
            ),
            decoration: const BoxDecoration(
              // ⚠️ 底色是**透明**：auroraqua.css 593–599（同样 ≥769、最后加载、
              // 特异性 0-2-0 压过 voice.css 的 0-1-0）把
              // `.voice-room-chat-card > .voice-room-chat-card-head` 的
              // background / box-shadow / backdrop-filter **全部清零**
              // ⇒ voice.css 那条 `--glass-bg` 不生效（卡片底透上来）。
              // 此前照 voice.css 抄了 --glass-bg ⇒ 卡面上又叠一层。
              border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
            ),
            child: Row(
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  '房内聊天', // tsx 315
                  style: t.body.copyWith(
                    fontSize: 13, // `.voice-room-chat-title`
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textSecondary,
                  ),
                ),
                Text(
                  '${widget.messages.length} 条消息', // tsx 316
                  // `.voice-room-chat-count-label`：--text-secondary / 12px
                  style: t.body.copyWith(
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        // 列表：宽屏 = 常驻并吃掉剩余高度；窄屏作为浮层挂在语音卡槽（见 _buildLayout）
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
      // ⚠️ 必须走库内 AylaGlassSurface（它内部已用 ClipRect 包住 BackdropFilter）；
      //    手搓裸 `BackdropFilter` 会把**整块画布**都糊掉（实测「遮罩把整个
      //    大画布都遮住了」）——Flutter 的 BackdropFilter 未裁剪时过滤的是整个 backdrop。
      return AylaGlassSurface(
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
    return AylaGlassSurface(
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
            // `.voice-room-chat-count`：18/11/600/--pink-500 白字（库内 AylaTabBadge 各档
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
          _VoiceChatImageButton(
            message: m,
            onOpen: () => _openImage(m),
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

/// 房内聊天图片（`.voice-room-chat-image`：120×80 · `object-fit: cover` · radius-sm）。
///
/// web 里这只是一张 `<ResourceImage>`，**没有 onClick**（`VoiceRoomBody.tsx:192–200`）
/// ⇒ 房内聊天图在 web 上点不开。Flutter 侧按用户实报补了「点开大图」
/// （见文件头「有意偏离」），尺寸/圆角/裁切与 web 逐值一致。
class _VoiceChatImageButton extends StatelessWidget {
  const _VoiceChatImageButton({required this.message, required this.onOpen});

  final AylaVoiceChatMessage message;

  /// 点开大图（宿主在 [AylaVoiceRoomBody] 的 State 内，见 `_openImage`）。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '查看房内聊天图片',
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn, // 同聊天域媒体（`media_content.dart`）
        child: GestureDetector(
          // 图片加载中/失败态是空装饰盒，不加 opaque 会穿透到背后的浮层/列表
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            child: SizedBox(
              width: 120, // `.voice-room-chat-image { width: 120px; max-height: 80px }`
              height: 80,
              child: AylaResourceImage(
                src: message.thumbnailUrl!,
                alt: message.content.isEmpty ? '房内聊天图片' : message.content,
                fit: BoxFit.cover, // `.voice-room-chat-image { object-fit: cover }`
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 房内聊天图片的大图查看器宿主。
///
/// 与 `widgets/live/danmaku.dart` 的 `_DanmakuViewerHost` 同一写法：
/// web 的 `<ImageViewer>` 是 `position: fixed; inset: 0`（`app.css:1459+`）
/// ⇒ 全屏、不被祖先 `overflow: hidden` 裁剪；Flutter 没有 portal，组件又常被
/// 嵌进卡片内 ⇒ 一律插到 **Overlay**（库内统一入口 [aylaOverlayEntry]，自动带
/// 文本作用域兜底）。用「最近」的 Overlay 而不是 `rootOverlay: true`：
/// 画布/测试宿主没有 Navigator，`rootOverlay` 会抛 `No Overlay widget found`。
class _VoiceChatViewerHost {
  OverlayEntry? _entry;

  void open(BuildContext context, AylaMediaDescriptor media, String alt) {
    close();
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => AylaImageViewer(
        media: media,
        alt: alt,
        onClose: close,
      ),
    );
    _entry = entry;
    Overlay.of(context).insert(entry);
  }

  void close() {
    _entry?.remove();
    _entry = null;
  }
}

/// 窄屏聊天列表浮层：绝对定位在输入卡**上方**（`bottom: 100%`），h300，进出 240ms。
///
/// ## ⚠️ 为什么不能用 `SizedBox(height: 0) + OverflowBox`（2026-10-24 用户实报「弹窗穿透」的根因）
///
/// 旧实现用零高盒子 + `OverflowBox(alignment: bottomCenter)` 把 300 高的浮层
/// **溢出绘制**到卡片上方。视觉上能看到，但 **Flutter 的命中测试只走布局矩形**：
/// `RenderBox.hitTest` 首行是 `if (_size!.contains(position))`（`rendering/box.dart:2952`），
/// 零高盒子的 `size` 不含任何向上 300px 的点 ⇒ 浮层内部的图片/文字**一律点不到**，
/// 点击继续下沉到浮层背后的页面 = 用户说的「穿透」。
/// （实测探针：点浮层中心 `overlayTaps=0`、背后 counter `behindTaps=1`。）
///
/// web 没有这个问题：`.voice-room-chat-list` 是 `position: absolute; bottom: 100%`
/// （`voice.css:72–105`），父 `.voice-room-chat-card` 是 `position: relative` 的
/// **流内元素**（`voice.css:55–65`）⇒ absolute 子元素**仍在卡片盒内、按绘制后几何参与
/// 浏览器命中测试**。CSS 的 `pointer-events: none/auto` 也由浏览器按几何判定。
///
/// ## Flutter 等价实现 = 把它 `Positioned` 在**语音卡槽**的 `bottom: 0`
///
/// 关键约束（Flutter 命中测试的真实规则，2026-10-24 实测 + 回读
/// `rendering/box.dart:2952` `if (_size!.contains(position))`）：
/// **从根到浮层的每一个祖先 RenderBox 都必须包含该点**，否则命中在该层即被截断。
/// 聊天卡是流内的 `Column`（高度 = 卡片自身），它上方 300px 不在其 `size` 内 ⇒
/// **浮层只要还是聊天卡的后代就永远点不到**（无论用 OverflowBox 还是自定义 RenderBox）。
///
/// 所以浮层由 [`_buildLayout`] 挂在**语音卡槽的 Stack** 里：
/// 该槽底边 = 聊天卡顶边（Column 内相邻、gap 0）⇒ `Positioned(bottom: 0, height: 300)`
/// 与 CSS `bottom: 100%` 的**绘制几何完全重合**，而槽的 `size` 覆盖那 300px
/// ⇒ 祖先链上每一层都包含该点，浮层内部（含图片）正常参与命中。
///
/// 另外两个错误等价物（都已实测排除，别再走回去）：
/// - `SizedBox(height:0) + OverflowBox`：盒子 `size` 零高，溢出部分**永久**不可命中；
/// - 自定义 RenderBox 在卡片内向上 `paint`/`hitTest`：自身能命中，但**父 Column 不包含该点**
///   ⇒ `RenderBox.hitTest` 在 Column 那层就返回 false，等于白做。
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
    return IgnorePointer(
      // `pointer-events: none`（voice.css:93）→ 展开态 105 行恢复 auto。
      // 收起态**必须**零命中且不拦截背后点击（不只是视觉透明）。
      ignoring: !expanded,
      child: ExcludeSemantics(
        excluding: !expanded,
        child: AnimatedOpacity(
          // 依据（2026-09-27 收口；13 号 §8.19）：web 是**整层 opacity** ——
          //   `.voice-room-chat-card > .voice-room-chat-list { opacity: 0;
          //   transform: translateY(12px); visibility: hidden; pointer-events: none;
          //   transition: opacity/transform/visibility var(--dur-panel) }`（voice.css:72–99）；
          //   展开态 `.is-expanded > … { opacity: 1; translateY(0); visibility: visible;
          //   pointer-events: auto }`（voice.css:100–105）。
          //   该浮层自身是 `--glass-bg-strong` + `backdrop-filter: blur(18px) saturate(1.4)`
          //   （voice.css:84–86）⇒ 保持整层（不以颜色 alpha 替代）。
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
              child: AylaGlassSurface(
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

// ======================= 样张 =======================

/// 语音房整页样张。
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
  bool _favorited = true; // 样张：收藏键可点
  int _shareTaps = 0; // 样张：转发键可点（计数仅用于演示）

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
      // 头部两键：收藏（compact 32）+ 转发（32）——与卡片族同尺寸
      //（裁决：web 的 40×40 转发键判为错误，统一取收藏键的 32）
      favorite: AylaFavoriteButton(
        state: _favorited ? AylaFavoriteState.favorited : AylaFavoriteState.notFavorited,
        compact: true,
        onToggle: (bool next) => setState(() => _favorited = next),
      ),
      share: AylaShareButton(
        label: '分享语音房',
        onPressed: () => setState(() => _shareTaps += 1),
      ),
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
          '窄屏 420（≤768）：body 无 padding、voice card 四边 margin sp4=16；'
          'head 只有下边框；卡片上下堆叠；'
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
              const Text('下次发送失败',
                  style: TextStyle(fontSize: 11)),
              AylaGlassButton(
                label: _failNext ? '下一次发送：失败' : '下一次发送：成功',
                variant: AylaGlassButtonVariant.ghost,
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
