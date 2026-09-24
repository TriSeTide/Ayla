/// 分享消息卡片（`components/chat/ShareBubble.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaShareTypeIcon] | `ShareBubble.tsx:31–55` `ShareTypeIcon`（6 类 + 默认 IconShare） |
/// | [AylaShareBubble] | tsx 57–139（卡片 + 跳转分流 + 群申请守卫） |
/// | 卡片材质/尺寸 | app.css 1138–1223（`.share-bubble-card` 及封面/标题/副标题/箭头） |
/// | 文案 | `utils/shareRoutes.ts`（[aylaShareTypeLabel] / [aylaShareTargetRoute]） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **群申请弹窗**：web 在卡片内嵌 `GroupApplyDialog`（未加入的群 → 不跳转、弹申请）。
///    `GroupApplyDialog` 属 B5（未开工）⇒ 本件改为注入
///    [AylaShareBubble.onRequestJoin]，未注入时不做守卫（web 的 store 自查走的是
///    会话列表，属页面层状态）。
/// 2. **存在性检查**：web 点击时异步查各域目录判断群内路径（见 `share_routes.dart`
///    文件头）；Flutter 侧默认走静态路由，页面层可注入
///    [AylaShareBubble.onResolveTarget] 覆盖。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/chat_message.dart';
import '../core/models/share_payload.dart';
import '../core/models/share_routes.dart';
import '../core/media/media_signer.dart';
import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart';
import '../theme/tokens.dart';
import 'resource_image.dart';

/// 分享来源图标（`ShareBubble.tsx:31–55`）：
/// group=IconUsers / voice=IconMic / live=IconVideo / post=IconPost /
/// boardgame=IconGame / user=IconUser；默认 IconShare。
class AylaShareTypeIcon extends StatelessWidget {
  const AylaShareTypeIcon({super.key, required this.shareType, this.size = 16});

  final AylaShareType shareType;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AylaIconData? icon = aylaIconByName(switch (shareType) {
      AylaShareType.group => 'iconUsers',
      AylaShareType.voice => 'iconMic',
      AylaShareType.live => 'iconVideo',
      AylaShareType.post => 'iconPost',
      AylaShareType.boardgame => 'iconGame',
      AylaShareType.user => 'iconUser',
    });
    if (icon == null) {
      final AylaIconData? fallback = aylaIconByName('iconShare');
      return fallback == null
          ? SizedBox(width: size, height: size)
          : AylaIcon(fallback, size: size);
    }
    return AylaIcon(icon, size: size);
  }
}

/// 分享消息卡片（气泡内渲染）。
class AylaShareBubble extends StatefulWidget {
  const AylaShareBubble({
    super.key,
    required this.msg,
    this.groupId,
    this.isGroupJoined,
    this.onRequestJoin,
    this.onNavigate,
    this.onResolveTarget,
  });

  /// `type=share` 消息。
  final AylaChatMessage msg;

  /// 当前会话为群聊时的群 id（分流跳转用；私聊/其他场景为 null）。
  final String? groupId;

  /// 目标群是否已加入（web 查 chat store `conversations`）——
  /// null = 不做守卫（弹窗依赖 B5 `GroupApplyDialog`，见文件头差异说明）。
  final bool Function(String groupId)? isGroupJoined;

  /// 未加入的群分享 → 申请弹窗（页面层接线 B5 `GroupApplyDialog`）。
  final void Function(AylaSharePayload payload)? onRequestJoin;

  /// 跳转（web `navigate(route, { state: { fromShare: true } })`）；
  /// 导航属页面层，未注入时卡片仍可点但无副作用。
  final void Function(String route)? onNavigate;

  /// 覆盖默认分流解析（web `resolveShareTarget` 的异步存在性检查）。
  final Future<String?> Function(AylaSharePayload? payload, String? groupId)?
      onResolveTarget;

  @override
  State<AylaShareBubble> createState() => _AylaShareBubbleState();
}

class _AylaShareBubbleState extends State<AylaShareBubble> {
  bool _resolving = false;
  bool _hovered = false;

  /// `.share-bubble-card:hover:not(:disabled) { box-shadow: 0 4px 16px rgba(70,91,146,.2) }`
  /// （app.css 1160–1163）——**不是 token**，是 web 的字面值。
  static const List<BoxShadow> _hoverShadow = <BoxShadow>[
    BoxShadow(color: Color(0x33465B92), blurRadius: 16, offset: Offset(0, 4)),
  ];

  AylaSharePayload? get _payload => widget.msg.sharePayload;

  /// 文案（tsx 70–73）。
  String get _title {
    final String fromPayload = (_payload?.title ?? '').trim();
    if (fromPayload.isNotEmpty) return fromPayload;
    final String fromContent = widget.msg.content.trim();
    return fromContent.isNotEmpty ? fromContent : '分享';
  }

  String get _subtitle {
    final AylaSharePayload? payload = _payload;
    final String label =
        payload == null ? '分享' : aylaShareTypeLabel(payload.shareType);
    final String sub = (payload?.subtitle ?? '').trim();
    return sub.isNotEmpty ? '$label · $sub' : label;
  }

  bool get _disabled =>
      _payload == null || _payload!.targetId.isEmpty || _resolving;

  Future<void> _handleTap() async {
    if (_resolving) return;
    final AylaSharePayload? payload = _payload;
    // 群聊分享守卫：未加入的群不能通过分享卡片跳转进入（tsx 77–86）
    if (payload?.shareType == AylaShareType.group) {
      final bool Function(String)? joined = widget.isGroupJoined;
      if (joined != null && !joined(payload!.targetId)) {
        widget.onRequestJoin?.call(payload);
        return;
      }
    }
    setState(() => _resolving = true);
    try {
      final String? route = widget.onResolveTarget != null
          ? await widget.onResolveTarget!(payload, widget.groupId)
          : aylaShareTargetRoute(payload, widget.groupId);
      if (route != null) widget.onNavigate?.call(route);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaSharePayload? payload = _payload;
    return UnconstrainedBox(
      // 卡片宽度 `width: min(264px, 100%)`：ConstrainedBox(maxWidth:) 在紧父级下会被
      // `constraints.enforce` 夹回（13 号 §五）⇒ 先松掉横向紧约束。
      constrainedAxis: Axis.vertical,
      alignment: Alignment.topLeft,
      child: TweenAnimationBuilder<double>(
        // hover 上浮 1px（web `translateY(-1px)`，transition 200ms ease）
        tween: Tween<double>(begin: 0, end: _hovered ? -1 : 0),
        duration: AylaDurations.button,
        curve: AylaCurves.auroraqua,
        builder: (BuildContext context, double dy, Widget? child) =>
            Transform.translate(offset: Offset(0, dy), child: child),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 264),
          child: AylaPressScale(
            // `.share-bubble-card` 不在 auroraqua 按钮组：hover 是 -1px 位移（非 1.02），
            // 但 `:active { transform: scale(.98) }` 属实（app.css 1164–1166）且自身
            // transition 就是 200ms ease ⇒ 只开压档。
            hoverScale: false,
            pressScale: !_disabled,
            enabled: !_disabled,
            semanticLabel: '${_subtitle.isEmpty ? '分享' : _subtitle}：$_title，点击打开',
            onTap: _disabled ? null : () => _handleTap(),
            child: MouseRegion(
              cursor: _disabled
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GlassSurface(
                radius: AylaRadii.rInput,
                blur: AylaGlass.blurCard,
                padding: const EdgeInsets.all(AylaSpacing.sp2),
                shadow: _hovered && !_disabled
                    ? _hoverShadow
                    : AylaShadows.compact,
                shadowTransition: AylaDurations.button,
                // `:disabled { opacity: .7 }` —— 按颜色降透明（见 GlassSurface.dimAlpha）
                dimAlpha: _disabled ? 0.7 : null,
                child: Opacity(
                  opacity: _disabled ? 0.7 : 1.0,
                  child: _body(payload),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AylaSharePayload? payload) {
    final String cover = (payload?.cover ?? '');
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64 - 2 * AylaSpacing.sp2),
      child: Row(
        // web `.share-bubble-card { align-items: stretch }` 只让 **meta 列**占满高度
        // （其内部 `justify-content: center` 做垂直居中）；封面有显式 72×72，
        // CSS 里 height 固定时不受 stretch 拉伸。Flutter 的 `CrossAxisAlignment.stretch`
        // 会**强制子级填满交叉轴、忽略其 height**（实测把封面拉成行高 284）⇒ 用 center。
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            // `.share-bubble-cover / -fallback`：72×72 + radius 10（app.css 1171–1181）
            width: 72,
            height: 72,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: cover.isNotEmpty
                  ? ResourceImage(
                      src: cover,
                      alt: '',
                      fit: BoxFit.cover,
                      variant: MediaVariant.thumb,
                      fallback: _coverFallback(payload),
                    )
                  : _coverFallback(payload),
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                    color: AylaColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontSize: 13,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3),
          Center(child: _chevron()),
        ],
      ),
    );
  }

  /// 封面兜底（`.share-bubble-cover-fallback`：135deg ice-100 → sakura-100 + 图标 22）。
  Widget _coverFallback(AylaSharePayload? payload) {
    return ColoredBox(
      color: AylaColors.ice100,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[AylaColors.ice100, AylaColors.sakura100],
          ),
        ),
        child: Center(
          child: AylaShareTypeIcon(
            shareType: payload?.shareType ?? AylaShareType.group,
            size: 22,
          ),
        ),
      ),
    );
  }

  /// `.share-bubble-chevron`：8×8 + 右/下 2px 边 + `rotate(-45deg)` + opacity .7。
  Widget _chevron() {
    return Opacity(
      opacity: 0.7,
      child: Transform.rotate(
        angle: -math.pi / 4, // -45deg
        child: Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            border: Border(
              right: BorderSide(color: AylaColors.textSecondary, width: 2),
              bottom: BorderSide(color: AylaColors.textSecondary, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

AylaChatMessage _previewShareMessage({
  required String id,
  required AylaSharePayload payload,
  String content = '',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderId: 'user-1',
      type: AylaMessageType.share,
      content: content,
      sharePayload: payload,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-09-24T10:00:00Z',
    );

/// 分享卡样张（**组件画布与 `@Preview` 共用**）：六类来源 + 禁用态 + 类型图标两档。
Widget aylaShareBubbleSamples() {
  aylaEnableSampleMedia();
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's1',
            payload: AylaSharePayload.group(
              id: '42',
              title: '爱莉的粉丝群',
              avatar: '/api/v1/media/group-cover/thumbnail',
              memberCount: 128,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's2',
            payload: AylaSharePayload.voice(
              id: '7',
              name: '深夜电台',
              memberCount: 3,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's3',
            payload: AylaSharePayload.live(
              id: '9',
              title: '今晚一起看星星',
              ownerName: '爱莉',
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's4',
            payload: AylaSharePayload.post(
              id: '12',
              title: '关于 Y2K 设计的一些想法',
              body: '这次主要想聊聊千禧年视觉语言在当代界面里的复现方式，以及…',
              group: '设计小组',
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's5',
            payload: AylaSharePayload.boardgame(
              id: '3',
              name: '你画我猜 6 人房',
              group: '桌游组',
              gameType: '你画我猜',
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's6',
            payload: AylaSharePayload.user(id: '5', nickname: '小樱', username: 'sakura'),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3),
        // 禁用态（无 target_id → `:disabled` opacity .7）
        AylaShareBubble(
          msg: _previewShareMessage(
            id: 's7',
            payload: const AylaSharePayload(
              shareType: AylaShareType.group,
              targetId: '',
              title: '没有目标的分享',
            ),
          ),
        ),
      ],
    ),
  );
}

/// 类型图标族（16 / 22 两档）。
@Preview(
  group: 'Chat',
  name: '分享类型图标（6 类 + 默认）',
  size: Size(360, 200),
  wrapper: previewTheme,
)
Widget shareTypeIconPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final AylaShareType type in AylaShareType.values) ...<Widget>[
              AylaShareTypeIcon(shareType: type),
              const SizedBox(width: AylaSpacing.sp4),
            ],
          ],
        ),
        const SizedBox(height: AylaSpacing.sp4),
        Row(
          children: <Widget>[
            for (final AylaShareType type in AylaShareType.values) ...<Widget>[
              AylaShareTypeIcon(shareType: type, size: 22),
              const SizedBox(width: AylaSpacing.sp4),
            ],
          ],
        ),
      ],
    ),
  );
}

/// 分享卡（六类来源 / 禁用态）。
@Preview(
  group: 'Chat',
  name: '分享卡（六类来源 / 禁用态）',
  size: Size(640, 700),
  wrapper: previewTheme,
)
Widget shareBubblePreview() => aylaShareBubbleSamples();
