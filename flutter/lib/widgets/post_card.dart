/// 帖子卡族 —— AylaPostCard / AylaPostVideoCover。
///
/// 事实源（逐条对应，无自由发挥）：
/// - `Ayla/web/src/components/posts/PostCard.tsx`（157 行）
/// - `Ayla/web/src/components/posts/PostVideoCover.tsx`（51 行）
/// - `styles/posts.css:9–217`（.post-card 族全量）
/// - `styles/auroraqua.css:29–52`（卡片族 hover/active）· `658–680`（窄屏覆写）
/// - `styles/typed-result-cards.css:5,7`（.post-card-open / .post-card-video-placeholder）
/// - `utils/visibility.ts`（可见性标签）· `api/media.ts:12–14`（媒体路径）
///
/// 回读确认的关键事实（勿凭印象改）：
/// 1. `.post-card` = `--glass-bg` + `--glass-filter` + `--radius-card`(16)
///    + `--glass-shadow` + `1px --glass-border` + **`overflow: hidden`**（内容裁到圆角内）。
/// 2. hover 挂在**父级**：`.posts-feed-item:hover .post-card { translate: 0 -2px;
///    box-shadow: --glass-shadow-hover; filter: brightness(1.01) }`；
///    active 由 `.post-card-main:active` 触发 `translate: 0 0; scale: .99`。
/// 3. `.post-card-tag { color: var(--ice-600) }` —— **tokens.css 并不存在 `--ice-600`**
///    （只有 ice-100/300/500）→ 声明 invalid at computed-value time → `color` 回落为
///    **继承值**：`body { color: var(--text-primary) }` ⇒ 标签文字实为 text-primary。
///    故这里用 [AylaColors.textPrimary]，是继承语义的等价表达（不是“近似色”）。
/// 4. 「查看帖子」`.post-card-open` 的样式在 typed-result-cards.css:5：
///    12px + `--text-secondary`（不在 posts.css 里）。
/// 5. 时间格式 `PostCard.tsx:23–36`：刚刚 / N 分钟前 / N 小时前 / `zh-CN` 日期。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/media/media_signer.dart' show MediaVariant;
import '../core/models/post.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'primitives.dart' show AylaCapsuleTag, CapsuleTone;
import 'directory_controls.dart' show AylaFavoriteButton, FavoriteState;
import 'media_interaction.dart';
import 'resource_image.dart';

/// 帖子卡时间（web `PostCard.tsx:23–36` 逐条同源；非法/缺失返回空串）。
String aylaPostCardTime(String? iso, {DateTime? now}) {
  if (iso == null || iso.isEmpty) return '';
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final DateTime ref = now ?? DateTime.now();
  final DateTime local = parsed.toLocal();
  final int diff = ref.difference(local).inMilliseconds;
  if (diff < 60000) return '刚刚';
  if (diff < 3600000) return '${diff ~/ 60000} 分钟前';
  if (diff < 86400000) return '${diff ~/ 3600000} 小时前';
  // Chromium `toLocaleDateString("zh-CN")` 的等价形态（2026/9/20）
  return '${local.year}/${local.month}/${local.day}';
}

/// 帖子视频封面（`PostVideoCover.tsx`）：thumbnail 优先（签名缩略图秒开、
/// 零视频拉流），无海报帧才降级 [SignedVideo] 首帧预览。
///
/// ⚠️ 平台差异（记录在案，不是简化）：web 的 `warmUp` 会创建 **detached**
/// `<video>`（off-DOM）预热缓冲，详情页挂载即拉流、点开即播；Flutter 侧播放器是
/// widget（SignedVideo 当前只到“签名 + 状态机”契约，播放器接入点见
/// media_interaction.dart 注释），不存在可脱离视图预热的元素 → 本组件不提供 warmUp。
class AylaPostVideoCover extends StatelessWidget {
  const AylaPostVideoCover({
    super.key,
    required this.media,
    this.fit = BoxFit.cover,
    this.ariaLabel = '帖子视频',
    this.placeholder = false,
  });

  /// 媒体描述符。
  final AylaMediaDescriptor media;

  /// 填充方式（卡片格子 cover；详情页大图 contain）。
  final BoxFit fit;

  /// 可访问性标签。
  final String? ariaLabel;

  /// 无海报帧且处于信息流（web `previewOnly`）→ 渲染「视频」文字占位。
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    final String? thumb = media.thumbnail;
    if (thumb != null && thumb.isNotEmpty) {
      // variant: thumb → 签发 thumbnail 对象（不是 original）；alt="" = 装饰图
      return ResourceImage(
        src: thumb,
        alt: '',
        variant: MediaVariant.thumb,
        fit: fit,
      );
    }
    if (placeholder) {
      // `.post-card-video-placeholder`（typed-result-cards.css:7）
      return Container(
        constraints: const BoxConstraints(minHeight: 140),
        color: AylaColors.ice100,
        alignment: Alignment.center,
        child: const Text(
          '视频',
          style: TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            color: AylaColors.textSecondary,
          ),
        ),
      );
    }
    // 卡片格子是 1:1（`.post-card-img { aspect-ratio: 1/1 }`）
    return SignedVideo(
      mediaId: media.mediaId,
      ariaLabel: ariaLabel,
      aspectRatio: 1,
    );
  }
}

/// 帖子卡（`PostCard.tsx` + posts.css 9–217）。
///
/// **展示型组件**：收藏状态、分享入口、作者跳转全部由调用方注入（与 B4 的
/// `AylaFavoriteButton(state:, onToggle:)` 同一模式；服务层在页面批次接入）。
class AylaPostCard extends StatefulWidget {
  const AylaPostCard({
    super.key,
    required this.post,
    required this.onOpen,
    this.authorOnline,
    this.onAuthorTap,
    this.favoriteState = FavoriteState.notFavorited,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
    this.onShare,
    this.previewOnly = false,
    this.action,
  });

  /// 帖子数据。
  final AylaPost post;

  /// 打开详情（web `onOpen`：`.post-card-main` 与「查看帖子」都触发）。
  final VoidCallback onOpen;

  /// 作者实时在线（presence 运行事实；null = 用帖子内联的 author.online）。
  final bool? authorOnline;

  /// 点作者头像（web `goUserProfile`）。
  final VoidCallback? onAuthorTap;

  /// 收藏状态（页面注入）。
  final FavoriteState favoriteState;

  /// 收藏请求进行中。
  final bool favoriteBusy;

  /// 收藏操作失败文案（role=alert）。
  final String? favoriteError;

  /// 切换收藏（传入目标状态：true = 收藏；与 AylaFavoriteButton 同契约）。
  final ValueChanged<bool>? onToggleFavorite;

  /// 收藏状态加载失败 → 重试拉取。
  final VoidCallback? onRetryFavoriteStatus;

  /// 分享入口（页面注入：打开 ShareSheet）。
  final VoidCallback? onShare;

  /// Directory 卡不挂视频解码器（web `previewOnly`）。
  final bool previewOnly;

  /// 覆盖底排收藏位（web `action?: ReactNode`）。
  final Widget? action;

  @override
  State<AylaPostCard> createState() => _AylaPostCardState();
}

class _AylaPostCardState extends State<AylaPostCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaPost post = widget.post;
    final AylaPostAuthor? author = post.author;
    final String? authorName = author?.displayName ?? post.authorNickname;
    final bool authorOnline = widget.authorOnline ?? author?.online ?? false;
    final List<AylaMediaDescriptor> mediaList = <AylaMediaDescriptor>[
      for (final AylaPostImage img in post.images)
        if (img.media case final AylaMediaDescriptor m) m,
    ];
    final String body = post.body;
    final bool longBody = body.length > 120;
    final List<String> tags = aylaVisibilityLabels(
      visibility: post.visibility,
      allowedGroupNames: post.allowedGroupNames,
      groupName: post.groupName,
    );

    final Widget main = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpen,
      child: Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp4), // .post-card-main padding sp4
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // ---------- .post-card-head ----------
            //
            // 布局事实（2026-09-20 用户三次纠正后定稿，逐条对照 web）：
            //   `.post-card-head { display:flex; align-items:center; gap:sp3 }`
            //     → 头像 + 昵称靠左；
            //   `.post-card-time { margin-left: auto }`
            //     → **时间与标签被推到最右**（时间在左、标签在其右）；
            //   `.post-card-tags { display:flex; gap:sp1; flex-wrap:wrap }`
            //     → 常规宽度下时间与标签**同排一行**，内容真超宽时才折行。
            //
            // Flutter 侧两处坑（都实测踩过）：
            //   ① 把「时间+标签」做成 flex 子项（Flexible/Expanded）→ 只拿一份 flex 额度
            //      （约 50%），360 宽卡被迫折行（用户截图：「标签还是在换行」）；
            //   ② 组只排在昵称后面、没有 auto 语义 → 紧贴昵称、**不靠右**
            //      （用户指出「时间和标签是靠右的」）。
            // 故：昵称与右侧组之间放 Spacer（= CSS `margin-left:auto`），右侧组按
            // 「可用宽 − 左侧 − 昵称最小保留」显式给宽（LayoutBuilder，不参与 flex 分配），
            // 组内 WrapAlignment.end 右对齐、仅极端超宽兜底折行。
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints head) {
                const double nickReserve = 64; // 昵称最少保留 4 个汉字宽
                final double leftWidth = authorName != null
                    ? AvatarHalo.haloWidth * 2 + 36 + AylaSpacing.sp3
                    : 0;
                final double groupMax = math.max(
                  0,
                  head.maxWidth -
                      leftWidth -
                      (post.createdAt != null || tags.isNotEmpty
                          ? AylaSpacing.sp3
                          : 0) -
                      nickReserve,
                );
                return Row(
                  // ⚠️ 用 spaceBetween 而不是「昵称 + Spacer + 右侧组」：
                  // Flutter 的 flex 只按因子分配剩余空间，**loose 子项用不完的额度
                  // 不会转给别的子项**——实测昵称用不完的 18.7px 落在行尾，右侧组因此
                  // 贴不到卡片右缘（用户指出「时间和标签是靠右的」）。spaceBetween 把
                  // 全部剩余空间放进「左右两组之间」，右组右缘 = 行右缘，等价 CSS 的
                  // `margin-left: auto`。
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    // ---- 左组：头像 + 昵称（昵称可压缩成省略号） ----
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                if (authorName != null) ...<Widget>[
                  AvatarHalo(
                    label: authorName,
                    size: 36,
                    online: authorOnline,
                    resourceUrl: author?.avatar,
                    onTap: author == null ? null : widget.onAuthorTap,
                    semanticLabel: '查看 $authorName 的个人主页',
                  ),
                  const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
                ],
                if (authorName != null)
                  Flexible(
                    child: Text(
                      authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis, // .post-card-nick
                      style: t.label.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ),
                        ],
                      ),
                    ), // ---- 左组结束 ----
                    const SizedBox(width: AylaSpacing.sp3), // 最小间距（spaceBetween 之外）
                // ---- 右侧组：时间 + 可见性标签（靠右） ----
                //
                // 对齐 web 结构：`.post-card-head{display:flex;gap:sp3}` +
                // `.post-card-time{margin-left:auto}` + `.post-card-tags{display:flex;
                // gap:sp1;flex-wrap:wrap}`。
                //
                // ⚠️ 为什么不把时间/标签各做成一个 Flutter flex item：
                // **Flutter 的 Flex 先按 flex 因子分配剩余空间，CSS 则先按内容 basis
                // 排布、剩余才交给 auto margin**。各占一份额度时窄卡会把标签压成
                // 「一行一个」并让 Row 报 0.5px overflow（2026-09-20 用户实测指出
                // 「标签横向排列不换行」，测试复现）。改为「右侧组 = 一个 Expanded +
                // 组内 Wrap」后：宽卡单行右对齐；窄卡整组折行、不溢出。
                if (post.createdAt != null || tags.isNotEmpty) ...<Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: groupMax),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AylaSpacing.sp3, // 时间与标签之间
                      runSpacing: AylaSpacing.sp1,
                      children: <Widget>[
                        if (post.createdAt != null)
                          Text(
                            aylaPostCardTime(post.createdAt),
                            style: const TextStyle(
                              fontFamily: AylaFonts.utility,
                              fontFamilyFallback: AylaFonts.cjkFallback,
                              fontSize: 12,
                              color: AylaColors.textSecondary,
                            ),
                          ),
                        for (final String label in tags)
                          // 复用组件库胶囊（2026-09-20 用户要求）：tone=ice（ice-100 底 +
                          // text-primary 字），盒模型/字级按 .post-card-tag 覆写
                          // （posts.css 68–76：padding 2px 8px、Space Grotesk 11 w600）。
                          AylaCapsuleTag(
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
                            textHeight: 1.55, // 继承 body 行高
                          ),
                      ],
                    ),
                  ),
                ],
                  ],
                );
              },
            ),
            // ---------- .post-card-title ----------
            if (post.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2),
                child: Text(
                  post.title,
                  style: t.cardTitle.copyWith(
                    fontFamily: AylaFonts.display,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
            // ---------- .post-card-body（超 3 行折叠） ----------
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp2),
              child: Text(
                body,
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 15,
                  height: 1.55, // line-height: 1.55
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
            if (longBody)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                child: GestureDetector(
                  // web stopPropagation：展开/收起不触发打开详情
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? '收起' : '展开', // .post-card-fold
                    style: const TextStyle(
                      fontFamily: AylaFonts.body,
                      fontFamilyFallback: AylaFonts.cjkFallback,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AylaColors.ice500,
                    ),
                  ),
                ),
              ),
            if (mediaList.isNotEmpty) _mediaGrid(mediaList),
          ],
        ),
      ),
    );

    final Widget footer = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AylaSpacing.sp4,
          AylaSpacing.sp2, // padding: sp2 sp4 sp3
          AylaSpacing.sp4,
          AylaSpacing.sp3,
        ),
        child: Row(
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpen,
              child: const Text(
                '查看帖子', // .post-card-open：12px + --text-secondary
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
            if (post.commentCount != null) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp4), // gap: var(--sp-4)
              _stat('iconMessage', post.commentCount!),
            ],
            if (post.viewCount != null) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp4),
              _stat('iconEye', post.viewCount!),
            ],
            const Spacer(), // .post-card-fav { margin-left: auto }
            if (widget.action != null)
              widget.action!
            else
              AylaFavoriteButton(
                state: widget.favoriteState,
                compact: true, // compact：32×32 无文字、图标 16
                busy: widget.favoriteBusy,
                actionError: widget.favoriteError,
                onToggle: widget.onToggleFavorite,
                onRetryStatus: widget.onRetryFavoriteStatus,
              ),
            const SizedBox(width: AylaSpacing.sp4),
            AylaIconButton(
              // ⚠️ home.css:127 `.icon-btn-40 { border-radius: var(--radius-pill) }`
              // → **纯圆钮**（40×40 + pill = 正圆）。此前误写成 square（12 方角）
              // 是漏读：auroraqua.css:119–122 的 radius-input 覆写只作用于
              // `.narrow-topbar-more > .icon-btn-40` 与 `.top-nav-more > .top-nav-icon-btn`。
              size: 40,
              icon: AylaIcon(aylaIconByName('iconShare')!),
              onPressed: widget.onShare,
              semanticLabel: '分享帖子',
            ),
          ],
        ),
      ),
    );

    // 卡片本体：**复用库内「可交互卡」**（GlassCard(interactive: true)）——
    // hover 上浮 2px + 按下 scale .99 + 阴影升 --glass-shadow-hover（auroraqua 卡片族），
    // 与卡片族其它成员（群卡/群列表行）同一份实现。
    //
    // ⚠️ 2026-09-20 事故：此前自己拼 AylaCardInteraction + GlassSurface，并在 hover 外面套
    // `ColorFiltered(brightness 1.01)`（想对齐 web 的 `filter: brightness(1.01)`）→
    // **ColorFiltered 会建立离屏层，层内的 BackdropFilter 采样不到卡片背后的内容** →
    // 玻璃面退化成一块发白的半透明底（用户实测「鼠标悬停变白」）。
    // 结论：玻璃卡不要套 ColorFiltered/Opacity 一类会新建 layer 的祖先；
    // hover 一律走 GlassCard(interactive:)，不要再手搓。
    return GlassCard(
      interactive: true,
      radius: AylaRadii.rCard,
      padding: EdgeInsets.zero, // .post-card 自身无内边距（main/foot 各自带）
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AylaRadii.rCard), // overflow: hidden
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[main, footer],
        ),
      ),
    );
  }

  /// 底排统计（.post-card-stat：16px 图标 + Space Grotesk 12px）。
  Widget _stat(String iconName, int value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AylaIcon(
          aylaIconByName(iconName)!,
          size: 16,
          color: AylaColors.textSecondary,
        ),
        const SizedBox(width: AylaSpacing.sp1), // gap: var(--sp-1)
        Text(
          value.toString(),
          style: const TextStyle(
            fontFamily: AylaFonts.utility,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12,
            color: AylaColors.textSecondary,
          ),
        ),
      ],
    );
  }

  /// .post-card-images：1 图大图（contain / max-h 240）/ 多图 3 列九宫格（gap 4px）。
  Widget _mediaGrid(List<AylaMediaDescriptor> mediaList) {
    final List<AylaMediaDescriptor> items = mediaList.take(9).toList();
    if (items.length == 1) {
      final AylaMediaDescriptor m = items.first;
      final Widget cell = m.kind == AylaMediaKind.video
          ? AylaPostVideoCover(
              media: m,
              fit: BoxFit.contain,
              placeholder: widget.previewOnly,
            )
          : ResourceImage(
              src: m.thumbnail ?? mediaContentUrl(m.mediaId),
              alt: '帖子图片',
              variant: m.thumbnail != null ? MediaVariant.thumb : null,
              fit: BoxFit.contain,
            );
      return Padding(
        padding: const EdgeInsets.only(top: AylaSpacing.sp3), // margin-top: sp3
        child: ConstrainedBox(
          // .count-1 .post-card-img { aspect-ratio: auto; max-height: 240px }
          constraints: const BoxConstraints(maxHeight: 240),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            child: cell,
          ),
        ),
      );
    }
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < items.length; i += 3) {
      final List<Widget> cells = <Widget>[];
      for (int j = 0; j < 3; j++) {
        final int idx = i + j;
        cells.add(
          Expanded(
            child: idx < items.length
                ? AspectRatio(
                    aspectRatio: 1, // aspect-ratio: 1/1
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AylaRadii.rSm),
                      child: _gridCell(items[idx]),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        );
        if (j < 2) cells.add(const SizedBox(width: 4)); // gap: 4px
      }
      rows.add(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp3),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 4), // gap: 4px
            rows[i],
          ],
        ],
      ),
    );
  }

  /// 格子内容（视频：封面 + 居中 ▶ 角标；图片：签名缩略图）。
  Widget _gridCell(AylaMediaDescriptor m) {
    if (m.kind == AylaMediaKind.video) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AylaPostVideoCover(media: m, placeholder: widget.previewOnly),
          // .post-card-video-badge：居中 ▶、28px、白 92% + 深色投影
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Text(
                  '▶',
                  style: TextStyle(
                    fontSize: 28,
                    color: Color(0xEBFFFFFF), // rgba(255,255,255,.92)
                    shadows: <Shadow>[
                      Shadow(
                        color: Color(0x80000000), // rgba(0,0,0,.5)
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return ResourceImage(
      src: m.thumbnail ?? mediaContentUrl(m.mediaId),
      alt: '帖子图片',
      variant: m.thumbnail != null ? MediaVariant.thumb : null,
      fit: BoxFit.cover, // object-fit: cover
    );
  }
}

// ======================= 预览 =======================

/// 帖子卡三态样张：常规 / 长文折叠 / 九宫格 + 视频占位。
///
/// **单一来源**：组件画布（component_gallery）与 @Preview 都调用它，
/// 避免「样例数据两处各写一份」而漂移。
Widget aylaPostCardSamples() {
  AylaPostImage img(String id) => AylaPostImage(
        id: id.hashCode,
        media: AylaMediaDescriptor(
          mediaId: id,
          kind: AylaMediaKind.image,
          thumbnail: '/api/v1/media/$id/thumbnail',
        ),
      );
  const AylaPostAuthor author = AylaPostAuthor(
    id: 'u1',
    nickname: '星野遥',
    online: true,
  );
  // 三张样张卡（**宽度由容器决定**，与 web 一致：单列 ≤1024 / 两列 >1025）
  final Widget card1 = AylaPostCard(
    post: AylaPost(
      id: 1,
      author: author,
      title: '深夜电台的歌单',
      body: '今晚的歌单在这里，欢迎点歌。',
      visibility: AylaPostVisibility.public,
      allowedGroupNames: const <String>['深夜电台'],
      images: <AylaPostImage>[img('m-cover-1')],
      commentCount: 12,
      viewCount: 340,
      createdAt: DateTime.now()
          .subtract(const Duration(minutes: 8))
          .toIso8601String(),
    ),
    onOpen: () {},
    onAuthorTap: () {},
    onToggleFavorite: (bool value) {},
    onShare: () {},
  );
  final Widget card2 = AylaPostCard(
    post: AylaPost(
      id: 2,
      author: author,
      body: '这是一条很长的正文，用来验证三条折叠与「展开」按钮。' * 6,
      visibility: AylaPostVisibility.friends,
      commentCount: 3,
      viewCount: 20,
      createdAt: DateTime.now()
          .subtract(const Duration(hours: 5))
          .toIso8601String(),
    ),
    onOpen: () {},
    favoriteState: FavoriteState.favorited,
    onToggleFavorite: (bool value) {},
    onShare: () {},
  );
  final Widget card3 = AylaPostCard(
    post: AylaPost(
      id: 3,
      author: author,
      body: '九宫格 + 视频格子（无海报帧 → 占位）。',
      visibility: AylaPostVisibility.group,
      groupName: '深夜电台',
      images: <AylaPostImage>[
        img('m1'),
        img('m2'),
        img('m3'),
        AylaPostImage(
          id: 99,
          media: const AylaMediaDescriptor(
            mediaId: 'v1',
            kind: AylaMediaKind.video,
          ),
        ),
      ],
      commentCount: 0,
      createdAt: DateTime.now()
          .subtract(const Duration(days: 2))
          .toIso8601String(),
    ),
    onOpen: () {},
    previewOnly: true,
    onShare: () {},
  );

  // 与 web 一致的帖子流排列（design.md §12.18 / posts.css 654–691）：
  //   >1025px → 两列等宽瀑布流，内容轨道 max 1200，列间距 = 卡片纵向间距 = --sp-3(12)；
  //   ≤1024px → 单列。
  //   注：**列分配（较矮列优先）属页面层**（web `hooks/useMasonryColumns.ts`），
  //   样张固定分配即可；卡片宽度由列宽决定（1200 轨道两列 → 每列 570）。
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AylaSpacing.sp6, // .posts-feed padding: var(--sp-4) var(--sp-6)
      vertical: AylaSpacing.sp4,
    ),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (c.maxWidth < 1025) {
          return Column(
            children: <Widget>[
              card1,
              const SizedBox(height: AylaSpacing.sp3),
              card2,
              const SizedBox(height: AylaSpacing.sp3),
              card3,
            ],
          );
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200), // 内容轨道
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 列分配（样张固定分配，用户定稿）：**左列两张小的、右列一张大的**
                // —— 常规卡 + 长文折叠卡在左，九宫格+视频的大卡在右，两列高度更接近。
                // web 真实分配是「较矮列优先」（hooks/useMasonryColumns.ts），属页面层能力。
                Expanded(
                  child: Column(
                    children: <Widget>[
                      card1,
                      const SizedBox(height: AylaSpacing.sp3),
                      card2,
                    ],
                  ),
                ),
                const SizedBox(width: AylaSpacing.sp3), // 列间距 --sp-3
                Expanded(child: Column(children: <Widget>[card3])),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 帖子卡三态预览。
@Preview(
  group: 'Cards',
  name: 'AylaPostCard 常规 / 长文折叠 / 九宫格+视频',
  size: Size(1300, 1000),
  wrapper: previewScope,
)
Widget aylaPostCardPreview() => aylaPostCardSamples();
