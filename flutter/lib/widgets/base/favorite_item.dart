/// 收藏列表项容器（web `pages/FavoritesPage.tsx:95` + `styles/typed-result-cards.css 17–20` +
/// `styles/profile.css 474–487 / 524–541` + `styles/auroraqua.css 29–52`）。
///
/// ## 事实源（逐条，2026-10-14 真实浏览器实测复核）
/// ```
/// FavoritesPage.tsx 95  <div className="favorite-item typed-result-card" data-favorite-id data-result-type>
///                       └─ <FavoriteResultCard … action=<button className="msg-action-btn typed-card-remove">取消收藏</button> />
///
/// ⚠️ **真正生效的那条（材质归零）**：typed-result-cards.css:17–20
///   .favorite-item.typed-result-card {
///     display: block; padding: 0; background: transparent; border: 0;
///     backdrop-filter: none; -webkit-backdrop-filter: none; box-shadow: none; }
///   特异性 0-2-0 > profile.css:474 的 0-1-0，且**不在任何媒体查询内**
///   ⇒ padding / 底 / 边 / 模糊 / 阴影**全部归零**；profile.css:539
///   （@media min-width:769 的 `.favorite-item { padding: var(--sp-4) }`）同样被压掉、**实际不生效**。
///   实测（1440）：item pad=0px · bg=rgba(0,0,0,0) · border-width=0 · box-shadow=none · backdrop=none。
///   ⇒ 真正画玻璃的是**内层那张卡**（.post-card / .voice-channel-card / .live-card /
///     .game-room-card，各自 --glass-bg + 1px 亮边 + blur(24) saturate(1.4) + --glass-shadow）。
///
/// profile.css 474–487  .favorite-item：display flex · align-items center · gap sp3 · padding sp3 ·
///                      radius-input · --glass-bg · 1px --glass-border · --glass-filter ·
///                      --glass-shadow-compact · transition box-shadow / border-color / translate
///                      ⇒ **只剩 `border-radius: --radius-input` 仍生效**（17–20 未覆写圆角），
///                        其余五条（display/gap 因只有一个子元素而无效果、padding/材质/阴影）全被压掉。
///
/// auroraqua.css 29–36  卡片族过渡组（含 .post-card / .voice-channel-card / .favorite-item）：
///                      translate / scale / box-shadow / border-color，300ms(--auroraqua-duration) var(--auroraqua-ease)
/// auroraqua.css 38–45  @media (hover:hover) and (pointer:fine) 的 hover 组 =
///                      :is(.group-card, .group-list-item, .game-room-card, .live-card,
///                          .voice-channel-card, .favorite-item):not([aria-disabled="true"]):hover
///                      + 单独的 `.posts-feed-item:hover .post-card`
///                      ⇒ translate: 0 -2px; box-shadow: var(--glass-shadow-hover)
///                      ⚠️ 该 :is() 里**没有 .post-card** —— post-card 只有作为 .posts-feed-item
///                        后代时才动；收藏页的帖卡无此祖先 ⇒ 本件与内层帖卡**不叠加上浮**。
/// auroraqua.css 47–52  :active ⇒ translate: 0 0; scale: .99
/// auroraqua.css 655–674 @media (prefers-reduced-motion: reduce) ⇒ translate / scale 归零
/// tokens.css 125       --glass-shadow-hover = 0 12px 40px rgba(70,91,146,.2), var(--glass-inset)
/// ```
///
/// ## 实测层叠（1440，CDP 悬停第 2 项 voice-channel-card-wrap）
/// ```
/// .favorite-item           translate=0px -2px  shadow=HAS   ← 本件表达的层
/// .voice-channel-card-wrap translate=none      shadow=none
/// .voice-channel-card      translate=0px -2px  shadow=HAS   ← 内层卡自己也在 hover 组里（各卡既有件承担）
/// ```
/// ⇒ 两层各自上移 2px（DOM 嵌套位移相加 = 4px），本件**不重复实现、也不取消**内层卡的 hover。
///
/// ## ⚠️ Flutter 侧的三条实现口径（勿照抄其它卡片件）
/// 1. **不能用 [AylaCardInteraction]**：它给整件挂了 `GestureDetector(behavior: opaque)` ——
///    web 的 `.favorite-item` 是 `<div>`（FavoritesPage.tsx:95），**自身不接收事件**，
///    点击全部由内层卡的主按钮 / 「取消收藏」按钮处理。opaque 命中层会吃掉本该落到内层卡按钮上的点击
///    （而内层卡的主按钮只盖自己那部分盒，无法与整块同高同宽）⇒ 本件只挂 hover 层。
///    另：web 的 `:active { scale: .99 }` 只在「指针**按下**该元素」时命中，本件不接收事件 ⇒
///    该分支由内层卡自己的 [AylaCardInteraction] 表达（内层卡在 hover 组里，本层不再叠一次）。
/// 2. **鼠标事件必须能穿透**：`MouseRegion(opaque: false)` —— 命中测试会同时收集
///    内层卡的 annotation（`mouse_tracker.dart:231–240` 遍历整条 hit-test path），
///    故本件与内层卡的 hover **各自独立**触发，与 web 的 per-element `:hover` 语义一致。
/// 3. **hover 阴影要走「只画形状之外」**：CSS 的 `box-shadow` 不在 border-box 内绘制，
///    而 Flutter 的 `BoxShadow` 会铺满整个形状（含内部）⇒ 半透明卡面上会被冰蓝染进卡内。
///    本件用与 `glass.dart` 的 `_OuterShadowPainter` 同构的画法（此处私有一份，
///    因需要按过渡进度缩放 alpha：CSS `transition: box-shadow` 从「无阴影」插值过来时
///    是**透明度连续上升**，用 `AnimatedOpacity` 做「无→有」会在起始帧闪出满档阴影）。
///
/// ## 公开面
/// `AylaFavoriteItem` · [kAylaFavoriteItemHoverLift]
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// hover 上浮量（web `auroraqua.css:42` `translate: 0 -2px`）。
const double kAylaFavoriteItemHoverLift = 2;

/// 收藏项容器：**纯布局容器**（材质归零，见文件头 typed-result-cards.css:17–20），
/// 并把 web 卡片族的 hover 反馈（上浮 2px + `--glass-shadow-hover`）表达在本层。
class AylaFavoriteItem extends StatefulWidget {
  const AylaFavoriteItem({super.key, required this.child});

  /// 对应的结果卡（`AylaFavoriteResultCard` / 四个 typed 卡）。
  final Widget child;

  @override
  State<AylaFavoriteItem> createState() => _AylaFavoriteItemState();
}

class _AylaFavoriteItemState extends State<AylaFavoriteItem> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // ⚠️ `@media (prefers-reduced-motion: reduce)`（auroraqua.css:655–674）把卡片族的 hover/active 覆写为 `translate: none; scale: none`（auroraqua.css:671–673）
    // —— 不只是「时长为 0」，**位移与缩放本身也要归零**（与库内 AylaCardInteraction 同口径）。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    // auroraqua.css:42 hover ⇒ `translate: 0 -2px`；auroraqua.css:49 :active ⇒ `translate: 0 0`。
    // ⚠️ CSS 的 y 轴向上、Flutter 向下 ⇒ 负号在此翻转（漏了会「hover 反而下沉 2px」，
    //    本文件首版即因此红过一次）。
    final double offsetY =
        (_hovered && !_pressed && !reduceMotion) ? -kAylaFavoriteItemHoverLift : 0;

    final BorderRadius radius =
        BorderRadius.circular(AylaRadii.rInput); // profile.css:480 仍生效的圆角

    return MouseRegion(
      // 见文件头「鼠标事件必须能穿透」：内层卡的 hover 与本层的 hover 互不吞并
      opaque: false,
      cursor: MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: offsetY),
          // auroraqua.css:32 `transition: translate var(--auroraqua-duration)` = 300ms
          duration: reduceMotion ? Duration.zero : AylaDurations.auroraqua,
          curve: AylaCurves.auroraqua, // var(--auroraqua-ease) = ease
          builder: (BuildContext context, double v, Widget? inner) {
            return Stack(
              clipBehavior: Clip.none, // 阴影画在形状之外，不能被裁
              children: <Widget>[
                if (v != 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _FavoriteHoverShadowPainter(
                          radius: radius,
                          // 阴影强度与位移同源（同一 tween 值）⇒ 不存在「先满档后位移」的闪帧。
                          // offsetY 为负（向上）⇒ 取绝对值。
                          factor: -v / kAylaFavoriteItemHoverLift,
                        ),
                      ),
                    ),
                  ),
                Transform.translate(offset: Offset(0, v), child: inner),
              ],
            );
          },
          child: AnimatedScale(
            // auroraqua.css:33 `transition: scale 200ms`
            duration: reduceMotion ? Duration.zero : AylaDurations.button,
            curve: AylaCurves.auroraqua,
            // auroraqua.css:47–52 的 :active 与 :hover 同特异性、源序在后 ⇒ 按下时
            // translate 回 0（上面 offsetY 的 !_pressed）且 scale .99；与是否 hover 无关。
            scale: (_pressed && !reduceMotion) ? 0.99 : 1.0, // auroraqua.css:51
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center, // align-items: center
              children: <Widget>[
                // profile.css:477 的 `gap: var(--sp-3)` 对单个 flex 子项无可见效果
                // （web 也只有一个结果卡子元素）⇒ 无需表达
                Expanded(child: widget.child), // flex 子项（卡片自身撑满）
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `--glass-shadow-hover` 的「只画形状之外」阴影环（透明度按过渡进度缩放）。
///
/// 与 `glass.dart` 的 `_OuterShadowPainter` 同构（`Path.combine(difference, 外框, 形状)`
/// 挖空内部）；差异只有一条：本条带 [factor]，因为 CSS 的 `transition: box-shadow`
/// 是从「无阴影」**连续插值**到 `--glass-shadow-hover` 的，alpha 必须跟着进度走。
class _FavoriteHoverShadowPainter extends CustomPainter {
  const _FavoriteHoverShadowPainter({
    required this.radius,
    required this.factor,
  });

  final BorderRadius radius;

  /// 0…1（hover 过渡进度）：0 = 无阴影，1 = 满档 `--glass-shadow-hover`。
  final double factor;

  @override
  void paint(Canvas canvas, Size size) {
    if (factor <= 0) return; // 静止态：web `box-shadow: none`（typed-result-cards.css:19）
    final Path hole = Path()..addRRect(radius.toRRect(Offset.zero & size));
    final Path frame = Path()
      ..addRect(Rect.fromLTWH(
        -size.width * 2,
        -size.height * 2,
        size.width * 5,
        size.height * 5,
      ));
    final Path ring = Path.combine(PathOperation.difference, frame, hole);

    canvas.save();
    canvas.clipPath(ring);
    for (final BoxShadow s in AylaShadows.glassHover) {
      final Paint paint = s.toPaint()
        ..color = s.color.withValues(alpha: s.color.a * factor);
      canvas.drawRRect(
        radius.toRRect((Offset.zero & size).shift(s.offset)),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FavoriteHoverShadowPainter old) =>
      old.factor != factor || old.radius != radius;
}
