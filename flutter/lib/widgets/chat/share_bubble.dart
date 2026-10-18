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
/// 1. **群申请弹窗**（2026-10-16 **已接线**）。web 在卡片内嵌 `GroupApplyDialog`
///    （tsx 124–136；未加入的群 → 不跳转、弹申请）。Flutter 侧保留两级注入口：
///    - [AylaShareBubble.onRequestJoin] 优先（页面层可自定义，例如接自己的弹窗宿主）；
///    - **未注入时**回退到自给自足档（= web 的原样）：本件自己
///      [aylaOpenGroupApplyDialog] 打开 [AylaGroupApplyDialog]（root Overlay），
///      提交走 [aylaSubmitGroupApply]，公开群加入成功后跳群。
///    唯一**必需的**外部输入仍是 [AylaShareBubble.isGroupJoined]（成员关系在会话列表里，
///    属页面层状态；未注入 = 不做守卫，与修前一致）。
/// 2. **存在性检查**：web 点击时异步查各域目录判断群内路径（见 `share_routes.dart`
///    文件头）；Flutter 侧默认走静态路由，页面层可注入
///    [AylaShareBubble.onResolveTarget] 覆盖。
///
/// ## 公开面
/// `AylaShareTypeIcon` · `AylaShareBubble` · 样张 `aylaShareBubbleSamples()`

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart' show GoRouter;

import '../../core/models/chat_message.dart';
import '../../core/models/subgroup.dart' show AylaGroupApplyData, AylaGroupJoinPolicy;
import '../../core/models/share_payload.dart';
import '../../core/models/share_routes.dart';
import '../../core/media/media_signer.dart';
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/resource_image.dart';
import '../group/group_apply.dart'
    show aylaOpenGroupApplyDialog, aylaShareGroupJoinedOf;

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
    // 群聊分享守卫：未加入的群不能通过分享卡片跳转进入（tsx 77–86）。
    //
    // 成员关系取两级（与 web 的同一条判据 `conversations.some(c.id === target && c.type === group)`）：
    // 1. 注入的 [AylaShareBubble.isGroupJoined]（页面层自定义；也给纯组件测试用）；
    // 2. 未注入 ⇒ 自查根容器的 chat store（[aylaShareGroupJoinedOf]，= web 的
    //    `useChatStore.getState()`）。无 ProviderScope ⇒ null ⇒ 不做守卫（与修前一致）。
    if (payload?.shareType == AylaShareType.group) {
      final bool? joined =
          widget.isGroupJoined?.call(payload!.targetId) ??
              aylaShareGroupJoinedOf(context, payload!.targetId);
      if (joined == false) {
        _requestJoin(payload!);
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

  /// 未加入的群分享卡被点 ⇒ 弹 GROUP REQUEST（web tsx 124–136 的 `setRequestOpen(true)`）。
  ///
  /// 两级注入口（见文件头「与 web 的差异」1）：
  /// 1. [AylaShareBubble.onRequestJoin] 优先 —— 页面层自定义弹窗宿主时用它；
  /// 2. 未注入 ⇒ **自给自足档**（= web 原样）：本件自己打开 [AylaGroupApplyDialog]
  ///    （root Overlay），提交走 [aylaSubmitGroupApply]；公开群加入成功后跳群。
  ///
  /// ⚠️ 自给自足档**仍要求** [AylaShareBubble.isGroupJoined] 注入 —— 成员关系在会话列表里，
  /// 属页面层状态。两者都未注入 ⇒ 不做守卫（与修前行为一致，不凭空造判断）。
  void _requestJoin(AylaSharePayload payload) {
    final void Function(AylaSharePayload)? injected = widget.onRequestJoin;
    if (injected != null) {
      injected(payload);
      return;
    }
    final AylaGroupJoinPolicy? policy =
        AylaGroupJoinPolicy.parse(payload.extra?['join_policy']);
    // 先把打开动作排到本次 tap 的回调之外（同 web 的 setState 语义），
    // 再用 payload 已知字段起弹窗；缺 join_policy 时 [aylaOpenGroupApplyDialog]
    // 内部补一次 public-summary（见该函数文档）。
    aylaOpenGroupApplyDialog(
      context,
      group: AylaGroupApplyData(
        id: payload.targetId,
        title: payload.title,
        joinPolicy: policy,
        avatar: payload.cover,
      ),
      onJoined: (String conversationId) {
        // web 的弹窗缺省 `onJoined` ⇒ GroupApplyDialog 自己 `navigate(`/group/${convId}`)`
        // （tsx 128–131）。分享卡未注入 onNavigate 时按同一条缺省跳转。
        final void Function(String route)? navigate = widget.onNavigate;
        final String route = '/group/${Uri.encodeComponent(conversationId)}';
        if (navigate != null) {
          navigate(route);
          return;
        }
        final GoRouter? router = GoRouter.maybeOf(context);
        router?.go(route);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AylaSharePayload? payload = _payload;
    // ⚠️ **不能用 `UnconstrainedBox`**（2026-10-18 用户实报窄屏分享卡文字溢出，根因在此）：
    // `UnconstrainedBox(constrainedAxis: vertical)` 虽然能让 `maxWidth:264` 生效，
    // 但它会给**整棵子树**下发**无界横约束** ⇒ 卡内 `Row` 的 `Expanded` 按内容撑开、
    // 长无空格 ID（`room_9331…`）直接撑破卡面（Debug 报
    // `RenderConstraintsTransformBox overflowed by 121 pixels`）。
    //
    // 正解：`Align(topLeft)` —— 它把**宽松**（loose）横约束传给子级、
    // 自身仍占满父级宽（等价 CSS 的 block 容器 + 子元素 `width: min(264px,100%)`），
    // 子级内部的 `Row/Expanded` 因此拿到**有界**宽度，可正常收窄换行。
    return Align(
      alignment: Alignment.topLeft,
      child: TweenAnimationBuilder<double>(
        // hover 上浮 1px（web `translateY(-1px)`，transition 200ms ease）
        tween: Tween<double>(begin: 0, end: _hovered ? -1 : 0),
        duration: AylaDurations.button,
        curve: AylaCurves.auroraqua,
        // ⚠️ **不能用 `child:` 参数承载 LayoutBuilder**（`TweenAnimationBuilder.child`
        // 会被缓存并在动画期间原样复用 ⇒ `LayoutBuilder` 只在**首次** build 取一次约束，
        // 窗口/气泡宽度变化后不会重算 —— 实测宽屏下卡片仍按初次的无界约束撑满整行）。
        // 放进 `builder` 里才会随每帧重建重新测量。
        builder: (BuildContext context, double dy, Widget? _) => Transform.translate(
          offset: Offset(0, dy),
          // ⚠️ **不能用 `Align`**：`Align` 会**尽可能占满父级**（= `Flexible` 给的全部宽度），
          // 于是外层气泡壳被撑成整行（2026-10-18 实拍：分享卡自身 264 了，但气泡背景仍横贯）。
          // web 的 `.bubble` 是 `inline-block` 行为 = **按内容收缩** ⇒
          // 这里用 `Align(widthFactor: 1.0)` 让容器宽 = 子级宽。
          child: Align(
            alignment: Alignment.topLeft,
            widthFactor: 1.0,
            heightFactor: 1.0,
            // `.share-bubble-card { width: min(264px, 100%) }`（app.css:1145）。
            // `width: min(264px, 100%)` 在 CSS 里是**紧宽度**；Flutter 侧必须用
            // `ConstrainedBox(minWidth: min(264, 可用), maxWidth: min(264, 可用))`
            // ⇒ 用 `SizedBox` + `LayoutBuilder` 在**同一层**算出紧宽更可靠。
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final double w = c.maxWidth.isFinite
                    ? math.min(264.0, c.maxWidth)
                    : 264.0;
                // 用 `ConstrainedBox(maxWidth: 264)` 而非 `SizedBox`：与 web
                // `width: min(264px, 100%)` 同义，且保留测试/后续读 `maxWidth` 的契约。
                return ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: w),
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
              child: AylaGlassSurface(
                radius: AylaRadii.rInput,
                blur: AylaGlass.blurCard,
                padding: const EdgeInsets.all(AylaSpacing.sp2),
                shadow: _hovered && !_disabled
                    ? _hoverShadow
                    : AylaShadows.compact,
                shadowTransition: AylaDurations.button,
                // `:disabled { opacity: .7 }` —— 按颜色降透明（见 AylaGlassSurface.dimAlpha）
                dimAlpha: _disabled ? 0.7 : null,
                child: Opacity(
                  opacity: _disabled ? 0.7 : 1.0,
                  // ⚠️ `.share-bubble-card { overflow: hidden }`（app.css:1158）——
                  // 长无空格串（如 `room_93312df4af194c8...`）在**窄气泡**里会把
                  // 标题撑出卡片右边界（2026-10-18 用户截图实报：文字溢出卡面、
                  // 视觉上像"错位"）。web 靠 `overflow:hidden` 裁掉；
                  // 阴影在 border-box **之外**绘制（CSS 规范），所以这层裁剪不影响卡阴影。
                  // 半径与 `--radius-input` 一致、比卡面小 1px（边框内侧）。
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      AylaRadii.rInput - 1,
                    ),
                    clipBehavior: Clip.hardEdge,
                    child: _body(payload),
                  ),
                ),
              ),
            ),
              ),
            );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AylaSharePayload? payload) {
    final String cover = (payload?.cover ?? '');
    return ConstrainedBox(
      // 只夹 **maxWidth**（= 卡片内容宽上限），不再重复扣 padding：
      // 外层已用 `SizedBox(width: min(264, 可用))` 锁住整卡宽，
      // 而本件是 `AylaGlassSurface(padding: sp2)` 的 child ⇒ 拿到的
      // 可用宽**已经**是 264 − 2×sp2。此处只作防御性上限（防内容撑破）。
      constraints: const BoxConstraints(
        minHeight: 64 - 2 * AylaSpacing.sp2,
      ),
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
                  ? AylaResourceImage(
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
            // ⚠️ **`crossAxisAlignment: start` + 宽松横约束 ⇒ Column 会按最宽子级撑开**，
            // 而 `Text` 在「横向无紧约束」时会一路撑到内容宽（长无空格 ID 不断行），
            // 结果整列溢出卡面（2026-10-18 用户截图 + Debug 黄黑溢出条）。
            // web 的 `.share-bubble-meta { flex:1; min-width:0 }` 里 `min-width:0` 正是
            // 让 flex 子项**可以被压窄** ⇒ 这里用 `stretch` 把列宽锁成 Expanded 给的宽。
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
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
                    fontFamilyFallback: AylaFonts.cjkFallback,
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
  /// 性能（2026-09-27 §8.17）：opacity .7 **乘进描边色**而不是套整层 Opacity ——
  /// 本件只有两条互不重叠的描边（BoxBorder 在角部按斜接分割、不叠加）⇒ 逐色
  /// alpha 与 group opacity 逐像素等价，但省掉一次 saveLayer。
  Widget _chevron() {
    final Color stroke = AylaColors.textSecondary.withValues(
      alpha: AylaColors.textSecondary.a * 0.7,
    );
    return Transform.rotate(
      angle: -math.pi / 4, // -45deg
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: stroke, width: 2),
            bottom: BorderSide(color: stroke, width: 2),
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

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

/// 分享卡样张：六类来源 + 禁用态 + 类型图标两档。
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
