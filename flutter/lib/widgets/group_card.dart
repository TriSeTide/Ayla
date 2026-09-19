/// 群卡片 + 状态轮播 + 群列表项（`GroupCard` / `GroupCarousel` / `GroupListItem`）。
///
/// 事实源：`components/home/GroupCard.tsx`、`GroupCarousel.tsx`、
/// `GroupListItem.tsx`、`groupActivity.ts`（`GroupCarouselSlide`）+
/// `home.css` 224–620 + `auroraqua.css` 29–52/452–453/658。
///
/// 全局事实链见本文件各段落注释；此处只列**跨组件的共用**部分：
///
/// 1. **可交互卡片动效**（`auroraqua.css` 29–52，卡片族共用）：
///    ```
///    transition: translate 300ms ease, scale 200ms ease,
///                box-shadow 300ms ease, border-color 300ms ease;
///    :hover  → translate: 0 -2px; box-shadow: var(--glass-shadow-hover);
///    :active → translate: 0 0;    scale: 0.99;
///    ```
///    仅 `(hover: hover) and (pointer: fine)` 生效。
/// 2. **材质**：卡片 `--glass-bg`(.55) + `--glass-filter`(blur24+saturate1.4)
///    + `--radius-card`(16) + `1px --glass-border` + `--glass-shadow`(含 inset)。
///    列表项：`--glass-bg` + `--glass-filter` + `--radius-input`(12)
///    + `--glass-shadow-compact`(含 inset)。
/// 3. **逐条浮入**（`reveal-item`，base.css 483–506）：从下方 20px + 淡入、
///    300ms `--auroraqua-ease-out`，延迟 `staggerDelay(i)` = `min(i*80, 300)`ms；
///    reduced-motion 直接可见。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'avatar_status_badges.dart';
import 'conversation_more_menu.dart';

// ======================= 轮播数据 =======================

/// 轮播卡种类（`GroupCarouselSlide`，groupActivity.ts 270–281）。
enum GroupSlideKind {
  /// 消息 + 语音合卡（文本两行）。
  messageVoice,

  /// 直播卡（封面 + 左下「主播 在直播 标题」）。
  live,

  /// 帖子卡（图 + 左上有新帖 + 左下标题）。
  post,

  /// 桌游卡（开关关闭，保留实现）。
  game,
}

/// 语音房条目（轮播「N人在{房间名}连麦」）。
class GroupSlideVoiceRoom {
  const GroupSlideVoiceRoom({required this.name, required this.memberCount});

  /// 房间名。
  final String name;

  /// 成员数。
  final int memberCount;
}

/// 单张轮播卡（`GroupCarouselSlide` 的联合类型 → 单一数据类 + [kind] 判定）。
class GroupCarouselSlide {
  const GroupCarouselSlide._({
    required this.kind,
    this.newMessageCount = 0,
    this.voiceRooms = const <GroupSlideVoiceRoom>[],
    this.host = '',
    this.title = '',
    this.cover,
    this.body = '',
    this.image,
    this.hasUnread = false,
    this.name = '',
    this.memberCount = 0,
  });

  /// 消息 + 语音合卡。
  const GroupCarouselSlide.messageVoice({
    required int newMessageCount,
    required List<GroupSlideVoiceRoom> voiceRooms,
  }) : this._(
          kind: GroupSlideKind.messageVoice,
          newMessageCount: newMessageCount,
          voiceRooms: voiceRooms,
        );

  /// 直播卡。
  const GroupCarouselSlide.live({
    required String host,
    required String title,
    String? cover,
  }) : this._(
          kind: GroupSlideKind.live,
          host: host,
          title: title,
          cover: cover,
        );

  /// 帖子卡。
  const GroupCarouselSlide.post({
    required String title,
    required String body,
    String? image,
    required bool hasUnread,
  }) : this._(
          kind: GroupSlideKind.post,
          title: title,
          body: body,
          image: image,
          hasUnread: hasUnread,
        );

  /// 桌游卡。
  const GroupCarouselSlide.game({
    required String name,
    required int memberCount,
    String? cover,
  }) : this._(
          kind: GroupSlideKind.game,
          name: name,
          memberCount: memberCount,
          cover: cover,
        );

  /// 种类。
  final GroupSlideKind kind;

  /// 消息合卡：新消息数。
  final int newMessageCount;

  /// 消息合卡：语音房（人数降序，≤3）。
  final List<GroupSlideVoiceRoom> voiceRooms;

  /// 直播卡：主播。
  final String host;

  /// 直播/帖子卡：标题。
  final String title;

  /// 直播/桌游卡：封面。
  final String? cover;

  /// 帖子卡：正文。
  final String body;

  /// 帖子卡：图片。
  final String? image;

  /// 帖子卡：是否有未读帖子（显示「有新帖」）。
  final bool hasUnread;

  /// 桌游卡：名称。
  final String name;

  /// 桌游卡：人数。
  final int memberCount;
}

/// 计数格式化（tsx `formatCount`：`n > 99 ? "99+" : String(n)`）。
String formatGroupCount(int n) => n > 99 ? '99+' : '$n';

// ======================= 轮播 =======================

/// `.group-carousel` —— 4:3 状态轮播。
///
/// **1:1 对照 `GroupCarousel.tsx` + home.css 337–503**：
/// - 容器 `padding: 8px`；`track` 圆角 12 + overflow hidden；
/// - `slide`：`flex: 0 0 100%`、**`aspect-ratio: 4/3`**、圆角 12、
///   底 `linear-gradient(135deg, ice-300, sakura-100)`；
/// - 文本卡（第一张）：`135deg rgba(157,191,230,.55) → rgba(249,176,255,.5)`
///   + `1px solid rgba(255,255,255,.6)`，内容居中、行间距 sp1、内边距 sp3；
/// - 指示点：底部 4px 处居中，点 4×4 pill，当前 `--glow-500` 其余 `--ice-300`；
/// - **轮播节拍**：`INTERVAL_MS = 3000`、`SLIDE_MS = 300`、
///   `transition: transform 300ms var(--ease-out)`；
/// - **进视口才启动、离开暂停**（IntersectionObserver threshold 0.1）；
/// - **`prefers-reduced-motion` 降级首帧静态**；
/// - 无状态 → 空态回退群头像（64px，居中，同渐变底）。
class AylaGroupCarousel extends StatefulWidget {
  const AylaGroupCarousel({
    super.key,
    required this.slides,
    required this.groupName,
    this.avatarUrl,
  });

  /// 轮播卡列表（消息+语音 / 直播 / 帖子 / 桌游）。
  final List<GroupCarouselSlide> slides;

  /// 群名（空态 aria 用）。
  final String groupName;

  /// 群头像（空态回退显示）。
  final String? avatarUrl;

  /// 轮播间隔（tsx `INTERVAL_MS = 3000`）。
  static const Duration interval = Duration(milliseconds: 3000);

  /// 滑入时长（tsx `SLIDE_MS = 300`）。
  static const Duration slideDuration = Duration(milliseconds: 300);

  /// 内嵌（`.group-carousel { padding: 8px }`）。
  static const double inset = 8;

  /// 圆角（`border-radius: 12px`）。
  static const double radius = 12;

  @override
  State<AylaGroupCarousel> createState() => _AylaGroupCarouselState();
}

class _AylaGroupCarouselState extends State<AylaGroupCarousel> {
  int _index = 0;

  /// 是否在视口内（IntersectionObserver 等价：见 [_checkVisible]）。
  bool _visible = false;

  /// 可见性判定用的 key（测量自身在视口中的位置）。
  final GlobalKey _viewportKey = GlobalKey();

  /// 祖先滚动位置（监听其变化以重新判定可见性）。
  ///
  /// ⚠️ **不能用 `NotificationListener<ScrollNotification>`**：滚动通知只从
  /// `Scrollable` **向上**冒泡，而本组件在 `Scrollable` 的**子树下面**，收不到。
  /// 实测：拖动外层 `SingleChildScrollView` 时内部 NotificationListener
  /// 一次都没触发 → 卡片滚进视口后轮播仍不启动（用户看到"只有一个轮播在滚"）。
  /// web 的 `IntersectionObserver` 是全局观察、不受此限；这里改为直接监听
  /// 祖先 [ScrollPosition]（`ViewportOffset extends ChangeNotifier`）。
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindScrollPosition();
      _checkVisible();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindScrollPosition();
  }

  /// 绑定最近的祖先滚动位置（首次进树 / 依赖变化时）。
  void _bindScrollPosition() {
    if (!mounted) return;
    ScrollPosition? found;
    context.visitAncestorElements((Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        found = (e.state as ScrollableState).position;
        return false; // 取最近的一个即停
      }
      return true;
    });
    if (identical(found, _scrollPosition)) return;
    _scrollPosition?.removeListener(_checkVisible);
    _scrollPosition = found;
    _scrollPosition?.addListener(_checkVisible);
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkVisible);
    super.dispose();
  }

  /// **自实现「进视口才启动」**（web 用 `IntersectionObserver{threshold:0.1}`）。
  ///
  /// Flutter 无内置等价物（不引新依赖）：取自身全局矩形与所在视口求交，
  /// 交集面积 ≥ 自身面积 10% 即视为可见。滚动或布局变化后重新判定。
  void _checkVisible() {
    if (!mounted) return;
    final BuildContext? ctx = _viewportKey.currentContext;
    if (ctx == null) return;
    final RenderBox? box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final RenderObject? vp = RenderAbstractViewport.maybeOf(box);
    final Rect self = box.localToGlobal(Offset.zero) & box.size;
    final Size screen = MediaQuery.of(context).size;
    final Rect viewport = vp == null ? Offset.zero & screen : Offset.zero & screen;
    final Rect overlap = self.intersect(viewport);
    final double area = overlap.width <= 0 || overlap.height <= 0
        ? 0
        : overlap.width * overlap.height;
    final double own = self.width * self.height;
    final bool visible = own > 0 && area / own >= 0.1; // threshold: 0.1
    if (visible != _visible) {
      setState(() => _visible = visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasItems = widget.slides.isNotEmpty;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    if (!hasItems) {
      // 空态：回退群头像（`.group-carousel-empty`，home.css 420–428）
      return Padding(
        padding: const EdgeInsets.all(AylaGroupCarousel.inset),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AylaGroupCarousel.radius),
            gradient: cssLinearGradient(
              angleDeg: 135,
              colors: <Color>[AylaColors.ice300, AylaColors.sakura100],
            ),
            border: Border.all(color: const Color(0x99FFFFFF)), // rgba(255,255,255,.6)
          ),
          child: AspectRatio(
            aspectRatio: 4 / 3, // aspect-ratio: 4 / 3
            child: Center(
              child: AvatarHalo(
                label: widget.groupName,
                size: 64, // <Avatar size={64} online />
                online: true,
                resourceUrl: widget.avatarUrl,
              ),
            ),
          ),
        ),
      );
    }

    final int safeIndex = _index % widget.slides.length;
    // 轮播节拍：可见 + 多项 + 非 reduced-motion 才转（tsx 121–127）
    final bool shouldRun = _visible && !reduceMotion && widget.slides.length > 1;

    return Padding(
      padding: const EdgeInsets.all(AylaGroupCarousel.inset),
      // 无需 NotificationListener：可见性由祖先 ScrollPosition 的 listener 驱动
      // （见 [_bindScrollPosition]；滚动通知不会向下传播到本子树）。
      child: KeyedSubtree(
          key: _viewportKey,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              return Stack(
                // ⚠️ **必须 Clip.none**：指示点的 `bottom: -4` 让它的渲染盒越出
                // Stack 底边 4px（落在容器的 padding 区里，这正是 web 的位置）。
                // Stack 默认 Clip.hardEdge 会把越界部分裁掉 → **点完全看不见**
                // （用户验收时指出「轮播图下面有点的啊」）。
                // 越界内容是纯装饰点，不涉及其它溢出，可安全放开裁剪。
                clipBehavior: Clip.none,
                children: <Widget>[
                  // track：圆角 12 + overflow hidden（只裁轮播内容）
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AylaGroupCarousel.radius),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: _SlidesViewport(
                        slides: widget.slides,
                        index: safeIndex,
                        animate: !reduceMotion,
                        shouldRun: shouldRun,
                        onTick: () {
                          if (!mounted) return;
                          setState(() {
                            _index = (_index + 1) % widget.slides.length;
                          });
                        },
                      ),
                    ),
                  ),
                  // 指示点（`.group-carousel-dots`，home.css 483–503）：
                  //   `position:absolute; left:0; right:0; bottom:4px` —— 相对
                  //   `.group-carousel`（含 8px padding 的容器）定位。
                  //
                  // 本 Stack 在 padding **内部**（Stack 底边距容器底 8px），故：
                  //   点底边距容器底 4px ⇒ 相对 Stack 的 bottom = 8 − 4 − 4(点高)
                  //   ... 换算为「点底边在 Stack 底边下方 4px」= bottom: **-4**
                  // 即点落在封面**下方的 padding 区**，与 web 一致
                  // （web 实测：点顶边 y == 封面底边 y）。
                  if (widget.slides.length > 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: -4, // 见上换算；靠 Stack Clip.none 才可见
                      child: IgnorePointer(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            for (int i = 0; i < widget.slides.length; i++) ...<Widget>[
                              if (i > 0) const SizedBox(width: 4), // gap: 4px
                              _Dot(active: i == safeIndex),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ),
    );
  }
}

/// `.group-carousel-dot` —— 4×4 pill；当前 `--glow-500`，其余 `--ice-300`。
class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4, // width: 4px
      height: 4, // height: 4px
      decoration: BoxDecoration(
        color: active ? AylaColors.glow500 : AylaColors.ice300,
        borderRadius: AylaRadii.pill, // border-radius: var(--radius-pill)
      ),
    );
  }
}

/// 滑轨：`translateX(-index*100%)`，300ms `var(--ease-out)`（tsx 143–149）。
class _SlidesViewport extends StatefulWidget {
  const _SlidesViewport({
    required this.slides,
    required this.index,
    required this.animate,
    required this.shouldRun,
    required this.onTick,
  });

  final List<GroupCarouselSlide> slides;
  final int index;
  final bool animate;
  final bool shouldRun;
  final VoidCallback onTick;

  @override
  State<_SlidesViewport> createState() => _SlidesViewportState();
}

class _SlidesViewportState extends State<_SlidesViewport>
    with SingleTickerProviderStateMixin {
  /// 3s 间隔计时（tsx `window.setInterval(..., INTERVAL_MS)`）。
  /// 用 AnimationController 承载：可随 shouldRun 启停、随 widget 释放而回收。
  late final AnimationController _timer = AnimationController(
    vsync: this,
    duration: AylaGroupCarousel.interval, // 3s
  )..addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.completed) {
        widget.onTick();
        if (widget.shouldRun) _timer.forward(from: 0);
      }
    });

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _SlidesViewport old) {
    super.didUpdateWidget(old);
    if (old.shouldRun != widget.shouldRun) _syncTimer();
  }

  void _syncTimer() {
    if (widget.shouldRun) {
      if (!_timer.isAnimating) _timer.forward(from: 0);
    } else {
      _timer.stop();
    }
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int n = widget.slides.length;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        // web：`.group-carousel-slides { transform: translateX(-index * 100%) }`
        // 其中百分比基准是**滑轨自身宽度**（`w * n`）→ 位移 = `-index * w` px。
        //
        // ⚠️ **不要用 `AnimatedSlide`**：它的位移 = `offset × 直接 child 的尺寸`，
        // 若直接 child 是 `OverflowBox`（自身尺寸 = 传入约束 = 视口宽 w，不是
        // 滑轨宽 w*n），位移会缩成 `-index/n × w` —— 实测 n=2 时只滑半张卡
        // （-179.5px 而非 -359px），n=4 时只滑 1/4 张（用户看出"只滑三分之一"）。
        // 改用 `TweenAnimationBuilder<double>` + `Transform.translate` 直接按
        // **像素**位移，无百分比歧义。
        return ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0,
              end: n == 0 ? 0 : -widget.index * w, // 像素位移（-index 张卡宽）
            ),
            duration: widget.animate
                ? AylaGroupCarousel.slideDuration // 300ms
                : Duration.zero, // reduced-motion: transition none
            curve: AylaCurves.easeOut, // var(--ease-out)
            builder: (BuildContext context, double dx, Widget? child) {
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            // 滑轨：总宽 = n 张卡；每张卡宽 = 视口宽 w
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: SizedBox(
                width: w * n,
                child: Row(
                  children: <Widget>[
                    for (final GroupCarouselSlide s in widget.slides)
                      SizedBox(width: w, child: _Slide(slide: s)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// `.group-carousel-slide` —— 一张卡（4:3、圆角 12、按 kind 渲染内容）。
class _Slide extends StatelessWidget {
  const _Slide({required this.slide});

  final GroupCarouselSlide slide;

  @override
  Widget build(BuildContext context) {
    final bool isText = slide.kind == GroupSlideKind.messageVoice;
    // 文本卡与媒体卡的底不同（home.css 351–366）
    final Gradient bg = isText
        ? cssLinearGradient(
            angleDeg: 135,
            colors: <Color>[
              AylaColors.ice500.withValues(alpha: 0.55), // rgba(157,191,230,.55)
              AylaColors.sakura300.withValues(alpha: 0.5), // rgba(249,176,255,.5)
            ],
          )
        : cssLinearGradient(
            angleDeg: 135,
            colors: <Color>[AylaColors.ice300, AylaColors.sakura100],
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: bg,
        borderRadius: BorderRadius.circular(AylaGroupCarousel.radius),
        border: isText
            ? Border.all(color: const Color(0x99FFFFFF)) // rgba(255,255,255,.6)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AylaGroupCarousel.radius),
        child: switch (slide.kind) {
          GroupSlideKind.messageVoice => _MessageVoiceContent(slide: slide),
          GroupSlideKind.live => _LiveContent(slide: slide),
          GroupSlideKind.post => _PostContent(slide: slide),
          GroupSlideKind.game => _GameContent(slide: slide),
        },
      ),
    );
  }
}

/// 消息+语音合卡：渐变底居中多行（`.group-carousel-text-lines`）。
class _MessageVoiceContent extends StatelessWidget {
  const _MessageVoiceContent({required this.slide});

  final GroupCarouselSlide slide;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center, // justify-content: center
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: AylaSpacing.sp1, // gap: var(--sp-1)
        children: <Widget>[
          if (slide.newMessageCount > 0)
            _textLine(t, '${formatGroupCount(slide.newMessageCount)}条新消息'),
          for (final GroupSlideVoiceRoom r in slide.voiceRooms)
            _textLine(t, '${formatGroupCount(r.memberCount)}人在${r.name}连麦'),
        ],
      ),
    );
  }

  Widget _textLine(AylaTextStyles t, String s) => Text(
        s,
        textAlign: TextAlign.center, // text-align: center
        style: t.label.copyWith(
          fontSize: 14, // font-size: 14px
          fontWeight: FontWeight.w700, // font-weight: 700
          color: AylaColors.grape700, // color: var(--grape-700)
        ),
      );
}

/// 直播卡：封面（或渐变占位）+ 左下 caption。
class _LiveContent extends StatelessWidget {
  const _LiveContent({required this.slide});

  final GroupCarouselSlide slide;

  @override
  Widget build(BuildContext context) {
    final String? cover = slide.cover;
    if (cover != null) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _CarouselImage(url: cover), // ResourceImage（alt="" ⇒ decorative）
          _Caption(text: '${slide.host} 在直播 ${slide.title}'),
        ],
      );
    }
    // `.group-carousel-fallback-live`：135deg ice-300 → ice-500
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: cssLinearGradient(
              angleDeg: 135,
              colors: <Color>[AylaColors.ice300, AylaColors.ice500],
            ),
          ),
          child: Center(child: _FallbackText(slide.title, AylaColors.indigo700)),
        ),
        _Caption(text: '${slide.host} 在直播 ${slide.title}'),
      ],
    );
  }
}

/// 帖子卡：图/占位 + 左上有新帖 + 正文（4 行）+ 左下标题。
class _PostContent extends StatelessWidget {
  const _PostContent({required this.slide});

  final GroupCarouselSlide slide;

  @override
  Widget build(BuildContext context) {
    final String? image = slide.image;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (image != null)
          _CarouselImage(url: image) // ResourceImage（alt="" ⇒ decorative）
        else
          const _PostFallback(),
        if (slide.hasUnread)
          const Positioned(top: 8, left: 8, child: _NewPostBadge()), // sp-2
        if (slide.body.isNotEmpty)
          Positioned(
            left: 8, // var(--sp-2)
            right: 8,
            bottom: 34, // bottom: 34px
            child: _PostBody(text: slide.body),
          ),
        _Caption(text: slide.title),
      ],
    );
  }
}

/// `.group-carousel-fallback-post`：135deg ice-500 → sakura-300（无文字）。
class _PostFallback extends StatelessWidget {
  const _PostFallback();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: cssLinearGradient(
          angleDeg: 135,
          colors: <Color>[AylaColors.ice500, AylaColors.sakura300],
        ),
      ),
    );
  }
}

/// 「有新帖」徽标（`.group-carousel-badge`，home.css 430–441）。
class _NewPostBadge extends StatelessWidget {
  const _NewPostBadge();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), // 2px 8px
      decoration: BoxDecoration(
        color: AylaColors.pink500, // background: var(--pink-500)
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        '有新帖',
        style: t.microTag.copyWith(
          fontFamily: AylaFonts.display,
          fontSize: 11, // font-size: 11px
          letterSpacing: 0.8, // letter-spacing: 0.8px
          color: AylaColors.surface, // color: #fffafb
        ),
      ),
    );
  }
}

/// 帖子正文（`.group-carousel-post-body`）：白字 + 描边 + 阴影，最多 4 行。
class _PostBody extends StatelessWidget {
  const _PostBody({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 4, // -webkit-line-clamp: 4
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AylaFonts.body,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 12, // font-size: 12px
        fontWeight: FontWeight.w700, // font-weight: 700
        height: 1.45, // line-height: 1.45
        color: AylaColors.surface, // color: #fffafb
        // -webkit-text-stroke: 1px rgba(70,91,146,.9)；paint-order: stroke fill
        // → Flutter 等价：先描边再填充（两个 Paint，stroke 在下）
        shadows: const <Shadow>[
          Shadow(
            color: Color(0xB3465B92), // text-shadow 0 1px 4px rgba(70,91,146,.7)
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

/// 桌游卡：渐变占位（名称）+ 左下 caption。
class _GameContent extends StatelessWidget {
  const _GameContent({required this.slide});

  final GroupCarouselSlide slide;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // `.group-carousel-fallback-game`：135deg sakura-100 → sakura-300
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: cssLinearGradient(
              angleDeg: 135,
              colors: <Color>[AylaColors.sakura100, AylaColors.sakura300],
            ),
          ),
          child: Center(child: _FallbackText(slide.name, AylaColors.grape700)),
        ),
        _Caption(text: '${slide.memberCount}人在玩${slide.name}'),
      ],
    );
  }
}

/// `.group-carousel-img` 的 Flutter 等价（`width/height 100%` + `object-fit: cover`）。
///
/// **对应 web `ResourceImage`**（`components/ResourceImage.tsx`）在轮播里的用法：
/// 两处调用都传 `alt=""` ⇒ **decorative**，因此**加载失败/过期不显示任何提示**，
/// 由下层渐变底透出（web：`if (decorative) return <span>{fallback}</span>`；
/// 轮播未传 `fallback` ⇒ 渲染空）。
///
/// ⚠️ **web 的完整媒体链路**（media_id 提取 → 短时签名 URL → 过期降级/重试）
/// 属**媒体批次**；本组件只实现轮播所需的最小语义（直连 URL + 失败留空）。
/// 签名链路落地后替换此处实现即可，调用方不变。
class _CarouselImage extends StatelessWidget {
  const _CarouselImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover, // object-fit: cover
      width: double.infinity, // width: 100%
      height: double.infinity, // height: 100%
      // decorative（alt=""）→ 失败留空，透出下层渐变底
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      // 加载中同样留空（web `resource-image-loading` + 无 fallback ⇒ 空）
      frameBuilder: (BuildContext context, Widget child, int? frame,
          bool wasSync) {
        return frame == null ? const SizedBox.shrink() : child;
      },
    );
  }
}

/// `.group-carousel-fallback` 的文字样式（居中 13px/700）。
class _FallbackText extends StatelessWidget {
  const _FallbackText(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: t.label.copyWith(
          fontSize: 13, // font-size: 13px
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// `.group-carousel-caption` —— 左下角字幕（home.css 444–460）。
class _Caption extends StatelessWidget {
  const _Caption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Positioned(
      left: 8, // left: var(--sp-2)
      right: 8, // right: var(--sp-2)
      bottom: 8, // bottom: var(--sp-2)
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), // 3px 8px
        decoration: BoxDecoration(
          color: const Color(0xC7FFFAFB), // rgba(255,250,251,.78)
          borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius-input 12
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis, // text-overflow: ellipsis
          style: t.label.copyWith(
            fontSize: 12, // font-size: 12px
            fontWeight: FontWeight.w700,
            height: 1.4, // line-height: 1.4
            color: AylaColors.grape700, // color: var(--grape-700)
          ),
        ),
      ),
    );
  }
}

// ======================= 群卡片 =======================

/// `.group-card` —— 群卡片（4:3 状态轮播 + 底部群头像行）。
///
/// **1:1 对照 `GroupCard.tsx` + home.css 224–300 + auroraqua.css 29–52/452–453**：
///
/// ```
/// <article class="group-card [is-pinned] [reveal-item]">
///   {isPinned && <span class="group-card-pin"><IconPinFilled 16/></span>}
///   <div class="group-card-main" onClick>            // 轮播 + 未读徽标
///     <GroupCarousel/>
///     {unread > 0 && <span class="group-badge group-badge-unread group-card-unread"/>}
///   </div>
///   <button class="group-card-foot" onClick>          // Avatar 24 + 标题
///     <Avatar size={24} online/>
///     <span class="group-card-title"/>
///   </button>
///   <ConversationMoreMenu showDelete={false}/>
/// </article>
/// ```
///
/// 关键值：
/// - 卡片：`--glass-bg` + `--glass-filter` + `--radius-card`(16)
///   + `1px --glass-border` + `--glass-shadow`(含 inset)
/// - `.group-card-main`：`overflow:hidden` + `border-radius: 16px 16px 0 0`
///   （**只裁上部圆角**；置顶图标要越出卡片左上角，故卡片本身不裁剪）
/// - `.group-card-pin`：`top:-6px; left:-6px; rotate(-45deg)`、`--pink-500`、
///   `pointer-events:none`
/// - `.group-card-unread`：`top: sp3; right: sp3`（封面右上角）
/// - `.group-card-foot`：`gap: sp2` + `padding: sp2 48px sp3 sp3`
///   （右侧 48px 给 ⋯ 按钮让位）；
///   **窄屏(≤768)**：`gap:4px; padding-left:8px; padding-right:40px`
/// - `.group-card-title`：15px/700/`--text-primary`、单行 ellipsis
/// - `.group-card .conv-more`：`bottom:10px; right:8px`（窄屏 `right:2px`）
class AylaGroupCard extends StatelessWidget {
  const AylaGroupCard({
    super.key,
    required this.groupId,
    required this.title,
    required this.slides,
    this.avatarUrl,
    this.unread = 0,
    this.isPinned = false,
    this.onOpen,
    this.onTogglePin,
    this.revealDelay,
  });

  /// 群 id。
  final String groupId;

  /// 群名。
  final String title;

  /// 轮播卡（消息+语音 / 直播 / 帖子 / 桌游）。
  final List<GroupCarouselSlide> slides;

  /// 群头像 URL。
  final String? avatarUrl;

  /// 未读数（>0 时右上角显示徽标）。
  final int unread;

  /// 是否置顶（显示卡外左上角 pin 图标）。
  final bool isPinned;

  /// 点击轮播区或底部行 → 进入群聊。
  final VoidCallback? onOpen;

  /// ⋯ 菜单的置顶切换回调。
  final ValueChanged<bool>? onTogglePin;

  /// 逐条浮入延迟（null = 不挂载入场动画）。
  final Duration? revealDelay;

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.of(context).size.width > 768; // ≤768 窄屏

    final BorderRadius cardRadius = BorderRadius.circular(AylaRadii.rCard);

    // 卡面：玻璃材质（分层见 GlassSurface；此处卡片本身用 GlassCard 等价层）
    final Widget card = Stack(
      clipBehavior: Clip.none, // 置顶图标越出卡片（`.group-card-pin` 在卡外）
      children: <Widget>[
        ClipRRect(
          borderRadius: cardRadius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // ---------- group-card-main：轮播 + 未读徽标 ----------
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 轮播区可点击进群（`.group-card-main { display:block }` + onClick）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onOpen,
                    child: AylaGroupCarousel(
                      slides: slides,
                      groupName: title,
                      avatarUrl: avatarUrl,
                    ),
                  ),
                  // `.group-card-unread { top: sp3; right: sp3 }`
                  if (unread > 0)
                    Positioned(
                      top: AylaSpacing.sp3,
                      right: AylaSpacing.sp3,
                      child: IgnorePointer(
                        child: Container(
                          constraints:
                              const BoxConstraints(minWidth: 16), // min-width:16px
                          height: 16, // height: 16px
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4), // padding: 0 4px
                          decoration: BoxDecoration(
                            color: AylaColors.pink500, // --pink-500
                            borderRadius: AylaRadii.pill,
                          ),
                          child: Text(
                            formatGroupCount(unread),
                            style: TextStyle(
                              fontFamily: AylaFonts.display, // --font-display
                              fontFamilyFallback: AylaFonts.cjkFallback,
                              fontSize: 11, // font-size: 11px
                              height: 1, // line-height: 1
                              color: AylaColors.surface, // #fffafb
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // ---------- group-card-foot ----------
              _GroupCardFoot(
                title: title,
                avatarUrl: avatarUrl,
                wide: wide,
                onOpen: onOpen,
              ),
            ],
          ),
        ),
        // ⋯ 更多菜单（`.group-card .conv-more { bottom:10px; right:8px }`
        // ；窄屏 `right:2px`）—— 放在 ClipRRect 外，弹出面板才能溢出卡片
        AylaConversationMoreMenu(
          conversation: AylaConversation(
            id: groupId,
            title: title,
            isPinned: isPinned,
          ),
          showDelete: false, // 群聊不提供删除（需求）
          align: ConversationMoreAlign.bottomRight,
          right: wide ? 8 : 2,
          onTogglePin: onTogglePin,
        ),
        // ---------- group-card-pin（卡外左上角） ----------
        if (isPinned)
          Positioned(
            top: -6, // top: -6px
            left: -6, // left: -6px
            child: IgnorePointer(
              child: Transform.rotate(
                angle: -0.7853981633974483, // rotate(-45deg) = -π/4
                child: AylaIcon(
                  aylaIconByName('iconPinFilled')!,
                  size: 16, // <IconPinFilled width={16} height={16}/>
                  color: AylaColors.pink500, // color: var(--pink-500)
                ),
              ),
            ),
          ),
      ],
    );

    // 玻璃卡材质（分层：模糊 → 阴影环 → 卡面，见 skill「卡片发黑」三差异）
    // + 卡片族交互动效（hover 上浮 2px 并换 --glass-shadow-hover；active .99）
    final Widget glass = AylaCardInteraction(
      onTap: onOpen,
      semanticLabel: '进入群聊 $title',
      builder: (BuildContext context, bool hovered) => _GlassCardShell(
        radius: cardRadius,
        // hover → --glass-shadow-hover（12/40）；静止 → --glass-shadow（8/32）
        shadow: hovered ? AylaShadows.glassHover : AylaShadows.glass,
        child: card,
      ),
    );
    return _RevealItem(delay: revealDelay, child: glass);
  }
}

/// `.group-card-foot` —— 底部行（Avatar 24 + 群名）。
class _GroupCardFoot extends StatelessWidget {
  const _GroupCardFoot({
    required this.title,
    required this.avatarUrl,
    required this.wide,
    required this.onOpen,
  });

  final String title;
  final String? avatarUrl;
  final bool wide;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Semantics(
      button: true,
      label: '进入群聊 $title',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Padding(
          // padding: var(--sp-2) 48px var(--sp-3) var(--sp-3)
          // 窄屏(≤768): gap 4 / padding-left 8 / padding-right 40
          padding: wide
              ? const EdgeInsets.fromLTRB(
                  AylaSpacing.sp3, AylaSpacing.sp2, 48, AylaSpacing.sp3)
              : const EdgeInsets.fromLTRB(8, AylaSpacing.sp2, 40, AylaSpacing.sp3),
          child: Row(
            children: <Widget>[
              AvatarHalo(
                label: title,
                size: 24, // <Avatar size={24} online/>
                online: true,
                resourceUrl: avatarUrl,
              ),
              SizedBox(width: wide ? AylaSpacing.sp2 : 4), // gap: sp2 / 4
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis, // text-overflow: ellipsis
                  style: t.label.copyWith(
                    fontSize: 15, // font-size: 15px
                    fontWeight: FontWeight.w700, // font-weight: 700
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 玻璃卡外壳（`.group-card` 材质：底 + 边 + 模糊 + 阴影环 + 内高光）。
///
/// 分层顺序遵循 skill「卡片发黑」事故结论：
/// `模糊层 → 阴影环 → 卡面`（阴影必须在模糊层**之上**，否则被 BackdropFilter
/// 一并模糊吸进卡内）。
class _GlassCardShell extends StatelessWidget {
  const _GlassCardShell({
    required this.radius,
    required this.child,
    this.shadow = AylaShadows.glass,
  });

  final BorderRadius radius;
  final Widget child;

  /// 当前阴影（静止 `--glass-shadow`；hover `--glass-shadow-hover`）。
  final List<BoxShadow> shadow;

  @override
  Widget build(BuildContext context) {
    final bool opaque = GlassConfig.useOpaqueFallback;

    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: false), // --glass-bg .55
        borderRadius: radius,
        border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
      ),
      child: child,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // ① 模糊层（blur24 + saturate1.4；只作用于卡片背后的页面内容）
        if (!opaque)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        // ② 阴影环（--glass-shadow / hover → --glass-shadow-hover；含
        //    --glass-inset；不参与裁剪、位于模糊层之上）
        Positioned.fill(
          child: AnimatedContainer(
            duration: AylaDurations.auroraqua, // box-shadow 300ms
            curve: AylaCurves.auroraqua,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: shadow,
            ),
          ),
        ),
        // ③ 卡面
        face,
        // ④ --glass-inset 顶沿 1px 内高光
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 逐条浮入（`.reveal-item`，base.css 483–506）：
/// 下方 20px + 淡入、300ms `--auroraqua-ease-out`、延迟 [delay]；
/// `delay == null` 则不挂载动画（直接可见）。
class _RevealItem extends StatefulWidget {
  const _RevealItem({required this.child, this.delay});

  final Widget child;
  final Duration? delay;

  @override
  State<_RevealItem> createState() => _RevealItemState();
}

class _RevealItemState extends State<_RevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AylaDurations.auroraqua, // --auroraqua-duration 300ms
  );

  @override
  void initState() {
    super.initState();
    if (widget.delay == null) {
      _c.value = 1;
    } else {
      Future<void>.delayed(widget.delay!, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.delay == null) return widget.child; // 不挂 reveal-item
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) return widget.child; // reduced-motion：直接可见

    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? child) {
        final double t = AylaCurves.auroraquaEaseOut.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, 20 * (1 - t)), child: child),
        );
      },
      child: widget.child,
    );
  }
}

// ======================= 群列表项 =======================

/// `.group-list-item` —— 群列表行（design.md §12.6）。
///
/// **1:1 对照 `GroupListItem.tsx` + home.css 513–620**：
///
/// ```
/// <div class="group-list-item-wrap [is-pinned] [reveal-item]">
///   <button class="group-list-item" onClick>
///     <span class="group-list-avatar">              // 头像 + 三位置角标
///       <Avatar size={44} online/>
///       <AvatarStatusBadges status={status}/>
///     </span>
///     <span class="group-list-body">
///       <span class="group-list-title">{pin && <IconPinFilled 16/>}{title}</span>
///       <span class="group-list-sub [is-new]">{preview ?? newEventText ?? "N 人"}</span>
///     </span>
///     {unread > 0 && <span class="group-badge group-badge-unread">{unread}</span>}
///   </button>
///   <ConversationMoreMenu showDelete={false}/>
/// </div>
/// ```
///
/// 关键值（home.css 517–620）：
/// - 行：`gap: sp3`、`min-height: 64px`、`padding: sp2 sp3` + `padding-right: 52px`
///   （给 ⋯ 让位）、`radius-input`(12)、`--glass-bg` + `--glass-filter`
///   + `1px --glass-border` + `--glass-shadow-compact`(含 inset)
/// - 标题 15/700 `--text-primary`；副行 13 `--text-secondary`；
///   `.is-new` → `--pink-500` + 600
/// - 置顶：标题转 `--grape-700`；行内 pin 图标 16、`rotate(-45deg)`、
///   `margin-right: 3px`、`vertical-align: -3px`
/// - 头像 44（`.group-list-avatar { position:relative }` 作为角标定位基准）
/// - `.group-list-item-wrap .conv-more { right: 6px }`
class AylaGroupListItem extends StatelessWidget {
  const AylaGroupListItem({
    super.key,
    required this.groupId,
    required this.title,
    this.avatarUrl,
    this.status = const AvatarStatus(),
    this.preview,
    this.newEventText,
    this.isPinned = false,
    this.memberCount,
    this.onOpen,
    this.onTogglePin,
    this.revealDelay,
  });

  /// 群 id。
  final String groupId;

  /// 群名。
  final String title;

  /// 群头像 URL。
  final String? avatarUrl;

  /// 群状态（驱动三位置角标）。
  final AvatarStatus status;

  /// 最新消息摘要；null 时回退 [newEventText] 或「N 人」。
  final String? preview;

  /// 最近「新内容」事件描述（有则 sub 转 pink 600）。
  final String? newEventText;

  /// 是否置顶。
  final bool isPinned;

  /// 成员数（无 preview/newEventText 时的兜底文案）。
  final int? memberCount;

  /// 点击进群。
  final VoidCallback? onOpen;

  /// ⋯ 菜单置顶切换。
  final ValueChanged<bool>? onTogglePin;

  /// 逐条浮入延迟（null = 不挂动画）。
  final Duration? revealDelay;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool isNew = newEventText != null;
    // sub 文案：preview ?? (newEventText ?? "N 人")（tsx 54）
    final String sub = preview ?? (newEventText ?? '${memberCount ?? 0} 人');

    final Widget row = Semantics(
      button: true,
      label: '进入群聊 $title',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64), // min-height: 64px
          padding: const EdgeInsets.fromLTRB(
            AylaSpacing.sp3, // padding-left: sp3
            AylaSpacing.sp2, // padding-top: sp2
            52, // padding-right: 52px（给 ⋯ 让位）
            AylaSpacing.sp2, // padding-bottom: sp2
          ),
          child: Row(
            children: <Widget>[
              // ---------- 头像 + 三位置状态角标 ----------
              // `.group-list-avatar { position:relative; flex:none }` → Stack 基准
              SizedBox(
                width: 44, // Avatar size 44
                height: 44,
                child: Stack(
                  clipBehavior: Clip.none, // 角标 right:-3px 越出
                  children: <Widget>[
                    AvatarHalo(
                      label: title,
                      size: 44, // <Avatar size={44} online/>
                      online: true,
                      resourceUrl: avatarUrl,
                    ),
                    AylaAvatarStatusBadges(status: status),
                  ],
                ),
              ),
              const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
              // ---------- group-list-body ----------
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (isPinned) ...<Widget>[
                          // `.group-list-pin-icon { rotate(-45deg); margin-right:3px }`
                          Transform.rotate(
                            angle: -0.7853981633974483, // -45deg
                            child: AylaIcon(
                              aylaIconByName('iconPinFilled')!,
                              size: 16,
                              color: AylaColors.pink500, // --pink-500
                            ),
                          ),
                          const SizedBox(width: 3), // margin-right: 3px
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.label.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              // `.is-pinned .group-list-title { color: --grape-700 }`
                              color: isPinned
                                  ? AylaColors.grape700
                                  : AylaColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.caption.copyWith(
                        fontSize: 13, // font-size: 13px
                        // `.is-new { font-weight:600; color: --pink-500 }`
                        fontWeight: isNew ? FontWeight.w600 : FontWeight.w400,
                        color: isNew
                            ? AylaColors.pink500
                            : AylaColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              // ---------- 未读徽标 ----------
              if (status.unread != null && status.unread! > 0) ...<Widget>[
                const SizedBox(width: AylaSpacing.sp2),
                _UnreadBadge(count: status.unread!),
              ],
            ],
          ),
        ),
      ),
    );

    // 行玻璃材质（--glass-shadow-compact 含 inset）+ 卡片族交互动效
    final BorderRadius r = BorderRadius.circular(AylaRadii.rInput);
    final Widget glass = AylaCardInteraction(
      onTap: onOpen,
      semanticLabel: '进入群聊 $title',
      builder: (BuildContext context, bool hovered) => _ListItemShell(
        radius: r,
        // hover → --glass-shadow-hover；静止 → --glass-shadow-compact
        shadow: hovered ? AylaShadows.glassHover : AylaShadows.compact,
        child: row,
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        _RevealItem(delay: revealDelay, child: glass),
        // `.group-list-item-wrap .conv-more { right: 6px }`（行内垂直居中）
        AylaConversationMoreMenu(
          conversation: AylaConversation(
            id: groupId,
            title: title,
            isPinned: isPinned,
          ),
          showDelete: false,
          right: 6,
          onTogglePin: onTogglePin,
        ),
      ],
    );
  }
}

/// 未读徽标（`.group-badge.group-badge-unread`）。
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16), // min-width: 16px
      height: 16, // height: 16px
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4), // padding: 0 4px
      decoration: BoxDecoration(
        color: AylaColors.pink500, // .group-badge-unread { background: --pink-500 }
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        formatGroupCount(count),
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11, // font-size: 11px
          height: 1, // line-height: 1
          color: AylaColors.surface, // color: #fffafb
        ),
      ),
    );
  }
}

/// 列表行的玻璃外壳（`--glass-shadow-compact` 含 `--glass-inset`）。
class _ListItemShell extends StatelessWidget {
  const _ListItemShell({
    required this.radius,
    required this.child,
    this.shadow = AylaShadows.compact,
  });

  final BorderRadius radius;
  final Widget child;

  /// 当前阴影（静止 `--glass-shadow-compact`；hover `--glass-shadow-hover`）。
  final List<BoxShadow> shadow;

  @override
  Widget build(BuildContext context) {
    final bool opaque = GlassConfig.useOpaqueFallback;

    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: false),
        borderRadius: radius,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: child,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        if (!opaque)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        Positioned.fill(
          child: AnimatedContainer(
            duration: AylaDurations.auroraqua, // box-shadow 300ms
            curve: AylaCurves.auroraqua,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: shadow, // --glass-shadow-compact / hover → -hover
            ),
          ),
        ),
        face,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ======================= 容器 =======================

/// `.home-grid` —— 群卡片网格（home.css 210–214）。
///
/// ```
/// display: grid; grid-template-columns: repeat(2, 1fr);
/// gap: var(--sp-3); padding: 0 var(--sp-3) var(--sp-3);
/// ```
/// **窄屏与宽屏同为 2 列**（web 未按断点改列数）。
///
/// **行高内容自适应**：web 未设 `grid-auto-rows` ⇒ 行高 = 卡片自然高。
/// 卡片高 = `轮播 padding 上下(16) + 封面高 + foot 高(44)`，其中
/// **封面高 = (列宽 − 16) × 3/4**（16 = 轮播左右 padding 各 8）。
/// Flutter 的 `GridView` 需要固定 `childAspectRatio`（那只能靠猜），
/// 因此这里用 `LayoutBuilder` **由列宽精确算出卡片高**再交给 `Wrap`——
/// 与 CSS「内容自适应」语义一致（列宽变化时高度自动跟随）。
class AylaGroupGrid extends StatelessWidget {
  const AylaGroupGrid({super.key, required this.children});

  /// 卡片列表（[AylaGroupCard]）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // padding: 0 var(--sp-3) var(--sp-3)
      padding: const EdgeInsets.only(
        left: AylaSpacing.sp3,
        right: AylaSpacing.sp3,
        bottom: AylaSpacing.sp3,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          const double gap = AylaSpacing.sp3; // gap: var(--sp-3)
          final double colW = (c.maxWidth - gap) / 2; // repeat(2, 1fr)
          final double coverH =
              (colW - AylaGroupCarousel.inset * 2) * 3 / 4; // 4:3 封面
          final double cardH = AylaGroupCarousel.inset * 2 + // 轮播上下 padding
              coverH +
              _kGroupCardFootHeight;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final Widget child in children)
                SizedBox(width: colW, height: cardH, child: child),
            ],
          );
        },
      ),
    );
  }
}

/// `.group-card-foot` 高度：`sp2(8) + 头像外径 + sp3(12)`。
///
/// ⚠️ **头像外径 = `size + 光环 2.5×2`**（`Avatar.tsx` 39 行
/// `haloStyle = { width: size + 5 }`），即 24 + 5 = **29**，不是 24。
/// 此前误用 24 导致卡片内容比分配高度高 5px（widget test 抓到 RenderFlex
/// overflow 5.0 pixels）。
const double _kGroupCardFootHeight =
    AylaSpacing.sp2 + (24 + AvatarHalo.haloWidth * 2) + AylaSpacing.sp3;

/// `.home-list` —— 群列表容器（home.css 505–511）。
///
/// ```
/// display: flex; flex-direction: column;
/// padding: 0 var(--sp-3) var(--sp-3); gap: var(--sp-2);
/// ```
class AylaGroupList extends StatelessWidget {
  const AylaGroupList({super.key, required this.children});

  /// 行列表（[AylaGroupListItem]）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AylaSpacing.sp3,
        right: AylaSpacing.sp3,
        bottom: AylaSpacing.sp3,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: children,
      ),
    );
  }
}

// ======================= 卡片族共用交互 =======================

/// 卡片族 hover/press 动效（`auroraqua.css` 29–52）。
///
/// ```
/// :is(.group-card, .group-list-item, .game-room-card, .live-card,
///     .voice-channel-card, .post-card, .favorite-item) {
///   transform-origin: center;
///   transition: translate 300ms ease, scale 200ms ease,
///               box-shadow 300ms ease, border-color 300ms ease;
/// }
/// @media (hover: hover) and (pointer: fine) {
///   :hover  → translate: 0 -2px; box-shadow: var(--glass-shadow-hover);
/// }
/// :active → translate: 0 0; scale: 0.99;
/// ```
///
/// 要点：
/// - hover **上浮 2px 同时换 `--glass-shadow-hover`**（12/40 阴影）；
/// - **按下会把 translate 复位为 0**（`translate: 0 0`）并缩到 `.99`
///   —— 不是"在 -2px 基础上再缩"，而是先回到原位（用户可感知的"按下去"）；
/// - 时长不同：`translate`/`box-shadow` 300ms，`scale` **200ms**（`--auroraqua-ease`）；
/// - 仅指针精确设备生效（Flutter 侧用 `MouseRegion` 天然只对鼠标触发）；
/// - reduced-motion 下不做位移。
///
/// [shadowFor] 回调：把「当前该用哪条阴影」交给调用方绘制（hover →
/// `AylaShadows.glassHover`）。卡片的阴影环是独立层（不参与裁剪），
/// 不能由本组件用 BoxDecoration 包一层，故用回调而非参数。
class AylaCardInteraction extends StatefulWidget {
  const AylaCardInteraction({
    super.key,
    required this.builder,
    this.onTap,
    this.semanticLabel,
  });

  /// 内容构建器（`hovered` 用于切换阴影与其它 hover 态）。
  final Widget Function(BuildContext context, bool hovered) builder;

  /// 点击回调（null 则不响应；动效仍保留）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  State<AylaCardInteraction> createState() => _AylaCardInteractionState();
}

class _AylaCardInteractionState extends State<AylaCardInteraction> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    // translate：hover → -2px；按下复位 0（CSS `:active { translate: 0 0 }`）
    final double dy = reduceMotion
        ? 0
        : (_pressed
            ? 0
            : (_hovered ? -2 : 0));
    // scale：按下 .99（200ms）
    final double scale = reduceMotion || !_pressed ? 1.0 : 0.99;

    // CSS `translate` 是**像素位移**（不影响布局、不改变自身坐标系原点），
    // 故用 Transform.translate 而非 AnimatedSlide（后者 offset 是自身尺寸百分比）。
    Widget content = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: dy),
      duration: reduceMotion
          ? Duration.zero
          : AylaDurations.auroraqua, // translate / box-shadow 300ms
      curve: AylaCurves.auroraqua,
      builder: (BuildContext context, double v, Widget? child) {
        return Transform.translate(offset: Offset(0, v), child: child);
      },
      child: AnimatedScale(
        duration: reduceMotion
            ? Duration.zero
            : AylaDurations.button, // scale 200ms
        curve: AylaCurves.auroraqua,
        scale: scale,
        child: widget.builder(context, _hovered),
      ),
    );

    if (widget.semanticLabel != null) {
      content = Semantics(
        button: widget.onTap != null,
        label: widget.semanticLabel,
        child: content,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: content,
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// B3 卡片族全量（窄屏 · 卡片布局 + 列表布局 + 状态角标）。
@Preview(
  group: 'Cards',
  name: '群卡片族（窄屏 375 · 卡片/列表/角标）',
  size: Size(375, 1000),
  wrapper: previewTheme,
)
Widget previewGroupCardsNarrow() {
  // ⚠️ 预览用**外部占位图 URL**（picsum.photos）呈现 `object-fit: cover` 的真实观感；
  // 真实数据来自后端媒体接口（`/api/v1/media/<id>/` 短时签名），签名链路属
  // 媒体批次——届时替换 URL 来源即可，组件无需改动。
  const String imgA = 'https://picsum.photos/seed/ayla-live/600/450';
  const String imgB = 'https://picsum.photos/seed/ayla-post/600/450';

  final List<GroupCarouselSlide> slides = <GroupCarouselSlide>[
    const GroupCarouselSlide.messageVoice(
      newMessageCount: 12,
      voiceRooms: <GroupSlideVoiceRoom>[
        GroupSlideVoiceRoom(name: '深夜电台', memberCount: 5),
        GroupSlideVoiceRoom(name: '作业互助', memberCount: 3),
      ],
    ),
    const GroupCarouselSlide.live(
      host: '小樱',
      title: '一起看星星',
      cover: imgA, // 有封面 → 图片
    ),
    const GroupCarouselSlide.post(
      title: '周末去哪玩',
      body: '大家周末有空吗？想去海边看日落，顺便拍点照片。',
      image: imgB, // 有图 → 图片
      hasUnread: true,
    ),
    const GroupCarouselSlide.game(name: '你画我猜', memberCount: 4),
  ];

  // 无封面/无图 → 验证渐变占位分支（`.group-carousel-fallback-*`）
  const List<GroupCarouselSlide> noImageSlides = <GroupCarouselSlide>[
    GroupCarouselSlide.messageVoice(
      newMessageCount: 3,
      voiceRooms: <GroupSlideVoiceRoom>[],
    ),
    GroupCarouselSlide.live(host: '小蓝', title: '新番同步看'),
    GroupCarouselSlide.post(
      title: '今日手作',
      body: '做了一下午的小熊挂件。',
      hasUnread: false,
    ),
  ];

  return SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 12),
        // ---- 卡片布局（2 列）----
        AylaGroupGrid(
          children: <Widget>[
            AylaGroupCard(
              groupId: 'g1',
              title: '星海观测站',
              slides: slides,
              unread: 12,
              onOpen: () {},
              onTogglePin: (_) {},
            ),
            AylaGroupCard(
              groupId: 'g2',
              title: '这是一个非常长的群名称用来测试省略号',
              slides: slides.take(2).toList(),
              unread: 128,
              isPinned: true, // 置顶：卡外左上 pin
              onOpen: () {},
              onTogglePin: (_) {},
            ),
            AylaGroupCard(
              groupId: 'g3',
              title: '空状态群', // 无 slides → 回退头像
              slides: const <GroupCarouselSlide>[],
              onOpen: () {},
            ),
            AylaGroupCard(
              groupId: 'g4',
              title: '无封面占位',
              slides: noImageSlides, // 直播/帖子无图 → 走渐变占位分支
              unread: 3,
              onOpen: () {},
            ),
          ],
        ),
        const SizedBox(height: 16),
        // ---- 列表布局 ----
        AylaGroupList(
          children: <Widget>[
            AylaGroupListItem(
              groupId: 'g1',
              title: '星海观测站',
              status: const AvatarStatus(
                unread: 12,
                live: true,
                voice: true,
              ), // 两角标：右下(直播) + 右(语音)
              preview: '小樱：今晚一起吃饭吗',
              isPinned: true,
              onOpen: () {},
            ),
            AylaGroupListItem(
              groupId: 'g2',
              title: '作业互助',
              status: const AvatarStatus(unread: 3, voice: true), // 单角标
              memberCount: 8,
              onOpen: () {},
            ),
            AylaGroupListItem(
              groupId: 'g3',
              title: '新内容群',
              newEventText: '阿蓝 创建了语音房 深夜电台', // sub 转 pink 600
              memberCount: 5,
              onOpen: () {},
            ),
            AylaGroupListItem(
              groupId: 'g4',
              title: '静默群',
              memberCount: 2,
              onOpen: () {},
            ),
          ],
        ),
      ],
    ),
  );
}

/// B3 头像状态角标（三位置 + 优先级 + 桌游开关）。
@Preview(
  group: 'Cards',
  name: '头像状态角标（1/2/3 个 + 桌游开关关闭）',
  size: Size(420, 200),
  wrapper: previewTheme,
)
Widget previewAvatarStatusBadges() {
  Widget avatar(AvatarStatus s, String label) => SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            AvatarHalo(label: label, size: 44, online: true),
            AylaAvatarStatusBadges(status: s),
          ],
        ),
      );

  return Center(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 32,
      children: <Widget>[
        avatar(const AvatarStatus(live: true), '直播'), // → 右下
        avatar(const AvatarStatus(live: true, voice: true), '两个'), // → 右下+右
        avatar(
          const AvatarStatus(live: true, voice: true, game: true),
          '桌游关',
        ), // 桌游被 kShowGameStatus=false 过滤 → 只有 2 个
        avatar(const AvatarStatus(), '无'),
      ],
    ),
  );
}

/// B3 更多菜单（展开态由交互触发；此预览展示按钮本体与三档定位）。
@Preview(
  group: 'Cards',
  name: '更多菜单（⋯ 按钮 + 三档定位）',
  size: Size(320, 220),
  wrapper: previewTheme,
)
Widget previewConversationMoreMenu() {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 12,
      children: <Widget>[
        // 列表行定位（垂直居中）
        SizedBox(
          width: 280,
          height: 64,
          child: Stack(
            children: <Widget>[
              AylaGroupListItem(
                groupId: 'g',
                title: '列表行（⋯ 垂直居中）',
                memberCount: 3,
                onOpen: () {},
                onTogglePin: (_) {},
              ),
            ],
          ),
        ),
        // 卡片定位（右下角）
        SizedBox(
          width: 280,
          height: 90,
          child: Stack(
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0x8CFFFAFB),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xA6FFFFFF)),
                ),
                child: const SizedBox.expand(),
              ),
              AylaConversationMoreMenu(
                conversation: const AylaConversation(
                  id: 'g',
                  title: '卡片右下（⋯ bottom:10 right:8）',
                ),
                showDelete: false,
                align: ConversationMoreAlign.bottomRight,
                onTogglePin: (_) {},
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
