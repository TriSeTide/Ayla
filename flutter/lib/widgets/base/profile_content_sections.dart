/// 个人主页内容分区（ProfileContentSections.tsx 211 行 + profile.css 174–380）。
///
/// ## 事实源
/// ── 外层 `.profile-mine`：透明 wrapper（column · gap sp4 · min-width 0）——**不叠卡片**，
/// 每类内容一张独立玻璃卡（design.md §4 的材料纪律）
/// ── `.profile-content-card`（私有 ContentCard 外壳）：column · gap sp3 · padding sp4 ·
/// radius-card 16 · glass-bg · 1px 边 · blur24 sat1.4 · --glass-shadow；
/// head = flex space-between gap sp3；title = inline-flex gap sp2 · **14/700** · text-primary，
/// 其 svg **--ice-500**
/// ── `.profile-media-row`：直播/语音并排（flex gap sp4；两张卡 flex 1 1 0 + min-width 0）；
/// **≤768 改 column**
/// ── 直播卡：title「正在直播」+ badge `.profile-live-badge`（pill · padding 2×sp2 · --pink-500 底 ·
/// --surface 字 · display 11/500 · ls .8）；行 = 封面 **88×50**（radius-input · cover；无封面时
/// ice-100 底 + --ice-500 的 IconVideo **20**）+ 标题 14/700 省略 + 副行 12 secondary
/// 「{owner_nickname || 展示名} 正在直播」
/// ── 语音卡：title「正在语音」+ badge `.profile-voice-count`（utility 12 secondary；
/// **仅 member_count > 0**）；行 = **36×36** 图标块（ice-100 底 · radius-input · IconMic
/// **18** · --ice-500）+ 名称 + 副行「{owner_nickname || 展示名} 的语音房」
/// ── 帖子卡：title「帖子」+ badge `.profile-content-count`（utility 12 secondary；仅 >0）；
/// loading = 3 条**高 44** 骨架（.skeleton：radius-sm + glass-bg + 1px 边 + frost-pulse 呼吸）；
/// error = `.profile-content-empty` 13px secondary（role=alert）；空态「还没有发帖」(mine) /
/// 「暂无帖子」；列表 gap sp2，行 = 标题（post.title 或正文前 40 · 14/700 省略）+ 副行
/// （标题存在时正文前 40 + 「 · 」（有 created_at 时）+ formatTime）；末尾「更多帖子」
/// （btn-ghost · **align-self flex-start** · min-height **36** · padding 0 sp4）
/// ── 桌游卡：title「正在玩的桌游」+ `.profile-game-placeholder`（row gap sp3 · padding sp3 ·
/// radius-input · rgba(255,250,251,.4) 底 · 13px secondary · IconGame **28** --ice-500）+
/// 「桌游玩法即将上线」
/// ── `.profile-content-row`（三处共用）：row gap sp3 · padding sp2 sp3 · radius-input ·
/// 底 rgba(255,250,251,.4) · 1px 透明边 · hover → 底 rgba(157,191,230,.18) + 边 glass-border（180ms）
/// ── formatTime（tsx 27–40）：<1min 刚刚 / <1h N 分钟前 / <24h N 小时前 / 否则日期（zh-CN ⇒ 2026/9/25）
///
/// ## 装配口径
/// web 组件内直接调 api（getLiveChannel / getVoiceChannel / listPosts）+ Link 跳转；
/// Flutter 侧沿用注入范式：三个数据源与跳转全部由页面层注入（[onOpenLive] / [onOpenVoice] /
/// [onOpenPost] / [onMorePosts]），组件不自持请求。
///
/// ## 公开面
/// `AylaProfileLiveData` · `AylaProfileVoiceData` · `AylaProfilePostItem` · `AylaProfileContentCard` · `AylaProfileContentSections` · 样张 `aylaProfileContentSectionsSamples()`

library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'loading.dart' show AylaSkeleton;
import 'resource_image.dart';

/// web formatTime（tsx 27–40）逐条同源。
///
/// 日期档 web 是 `toLocaleDateString("zh-CN")`（形如 `2026/9/25`）⇒ 这里按同格式拼。
String aylaProfileFormatTime(String iso, {DateTime? now}) {
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final int diff = (now ?? DateTime.now()).difference(parsed).inMilliseconds;
  if (diff < 60000) return '刚刚';
  if (diff < 3600000) return '${diff ~/ 60000} 分钟前';
  if (diff < 86400000) return '${diff ~/ 3600000} 小时前';
  return '${parsed.year}/${parsed.month}/${parsed.day}';
}

/// 直播条目投影（web `LiveChannelDescriptor` 的展示子集）。
class AylaProfileLiveData {
  const AylaProfileLiveData({
    required this.id,
    required this.title,
    this.cover,
    this.ownerNickname,
  });

  final String id;
  final String title;
  final String? cover;
  final String? ownerNickname;
}

/// 语音条目投影（web `VoiceChannelDescriptor` 的展示子集）。
class AylaProfileVoiceData {
  const AylaProfileVoiceData({
    required this.id,
    required this.name,
    this.ownerNickname,
    this.memberCount = 0,
  });

  final String id;
  final String name;
  final String? ownerNickname;
  final int memberCount;
}

/// 帖子条目投影（web `Post` 的展示子集）。
class AylaProfilePostItem {
  const AylaProfilePostItem({
    required this.id,
    this.title,
    this.body = '',
    this.createdAt,
  });

  final String id;
  final String? title;
  final String body;
  final String? createdAt;
}

/// `.profile-content-card` —— 内容卡外壳（web 私有 ContentCard）。
class AylaProfileContentCard extends StatelessWidget {
  const AylaProfileContentCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.badge,
  });

  /// 头部图标（web 传 16×16 的图标；颜色由 title 的 `--ice-500` 统一给）。
  final Widget icon;

  final String title;

  /// 尾部徽标（LIVE / 人数 / 麦数）。
  final Widget? badge;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaGlassSurface(
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard, // --glass-filter
      shadow: AylaShadows.glass, // --glass-shadow
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          Row(
            spacing: AylaSpacing.sp3, // gap: var(--sp-3)
            children: <Widget>[
              Expanded(
                child: Row(
                  spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                  children: <Widget>[
                    icon,
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // .profile-content-title：14/700 text-primary
                        style: t.body.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AylaColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null) badge!,
            ],
          ),
          child,
        ],
      ),
    );
  }
}

/// .profile-mine —— 个人主页内容分区（顺序：直播/语音 → 帖子 → 桌游占位）。
class AylaProfileContentSections extends StatelessWidget {
  /// 可见文案（web 原文「更多帖子」；**开放给调用方**，默认值 = web 文案）。
  final String actionLabel;
  const AylaProfileContentSections({
    super.key,
    this.actionLabel = '更多帖子',
    required this.displayName,
    this.live,
    this.voice,
    this.posts = const <AylaProfilePostItem>[],
    this.postsLoading = false,
    this.postsError,
    this.mine = false,
    this.onOpenLive,
    this.onOpenVoice,
    this.onOpenPost,
    this.onMorePosts,
  });

  /// 展示名（web owner.nickname || owner.username），用于「正在直播 / 的语音房」副行。
  final String displayName;

  /// 正在直播（最多 1 个；null = 不渲染该卡）。
  final AylaProfileLiveData? live;

  /// 正在语音（最多 1 个；null = 不渲染该卡）。
  final AylaProfileVoiceData? voice;

  /// 帖子（web 取前 3 条）。
  final List<AylaProfilePostItem> posts;
  final bool postsLoading;
  final String? postsError;

  /// 是否本人（决定空态文案与「更多帖子」目标，目标由调用方处理）。
  final bool mine;

  final ValueChanged<String>? onOpenLive;
  final ValueChanged<String>? onOpenVoice;
  final ValueChanged<String>? onOpenPost;
  final VoidCallback? onMorePosts;

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width <= 768;
    final Widget? liveCard = live == null ? null : _liveCard(context);
    final Widget? voiceCard = voice == null ? null : _voiceCard(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4, // .profile-mine { gap: var(--sp-4) }
      children: <Widget>[
        // .profile-media-row：宽屏并排（各 flex 1 1 0）；≤768 改单列
        if (liveCard != null && voiceCard != null)
          if (narrow)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: AylaSpacing.sp4,
              children: <Widget>[liveCard, voiceCard],
            )
          else
            // ⚠️ 必须 stretch：web 的 .profile-media-row 是 flex 行（默认 align-items: stretch）
            //    ⇒ 两张卡**等高、底部对齐**；用 start 会让矮的那张按内容高、底边错开。
            // ⚠️ 等高靠 IntrinsicHeight（web 的 flex 行默认 align-items: stretch）：
            //    竖向无界父级（SingleChildScrollView）下 CrossAxisAlignment.stretch 不可靠，
            //    实测两卡底边仍错开。IntrinsicHeight 会把两卡拉到同一高度。
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: AylaSpacing.sp4,
                children: <Widget>[
                  Expanded(child: liveCard),
                  Expanded(child: voiceCard),
                ],
              ),
            )
        else if (liveCard != null)
          liveCard
        else if (voiceCard != null)
          voiceCard,
        _postsCard(context),
        _gameCard(context),
      ],
    );
  }

  /// 直播卡（tsx 113–135）。
  Widget _liveCard(BuildContext context) {
    final AylaProfileLiveData data = live!;
    final String owner =
        (data.ownerNickname ?? '').isNotEmpty ? data.ownerNickname! : displayName;

    return AylaProfileContentCard(
      icon: AylaIcon(
        aylaIconByName('iconVideo')!,
        size: 16,
        color: AylaColors.ice500, // .profile-content-title svg
      ),
      title: '正在直播',
      badge: const _LiveBadge(),
      child: _ProfileContentRow(
        onTap: onOpenLive == null ? null : () => onOpenLive!(data.id),
        children: <Widget>[
          // 封面 88×50（无封面 → ice-100 底 + IconVideo 20）
          ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            child: SizedBox(
              width: 88,
              height: 50,
              child: (data.cover ?? '').isNotEmpty
                  ? AylaResourceImage(src: data.cover!, alt: '', fit: BoxFit.cover)
                  : ColoredBox(
                      color: AylaColors.ice100,
                      child: Center(
                        child: AylaIcon(
                          aylaIconByName('iconVideo')!,
                          size: 20,
                          color: AylaColors.ice500,
                        ),
                      ),
                    ),
            ),
          ),
          Expanded(
            child: _rowCopy(context, data.title, '$owner 正在直播'),
          ),
        ],
      ),
    );
  }

  /// 语音卡（tsx 137–157）。
  Widget _voiceCard(BuildContext context) {
    final AylaProfileVoiceData data = voice!;
    final String owner =
        (data.ownerNickname ?? '').isNotEmpty ? data.ownerNickname! : displayName;

    return AylaProfileContentCard(
      icon: AylaIcon(
        aylaIconByName('iconMic')!,
        size: 16,
        color: AylaColors.ice500,
      ),
      title: '正在语音',
      // badge 仅 member_count > 0（tsx 141–143）
      badge: data.memberCount > 0
          ? _CountBadge('${data.memberCount} 人在麦')
          : null,
      child: _ProfileContentRow(
        onTap: onOpenVoice == null ? null : () => onOpenVoice!(data.id),
        children: <Widget>[
          // 36×36 图标块（ice-100 底 + IconMic 18）
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AylaColors.ice100,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
            ),
            child: AylaIcon(
              aylaIconByName('iconMic')!,
              size: 18,
              color: AylaColors.ice500,
            ),
          ),
          Expanded(child: _rowCopy(context, data.name, '$owner 的语音房')),
        ],
      ),
    );
  }

  /// 行内文案（标题 14/700 省略 + 副行 12 secondary 省略）。
  Widget _rowCopy(BuildContext context, String title, String sub) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2, // gap: 2px
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AylaColors.textPrimary,
          ),
        ),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.body.copyWith(
            fontSize: 12,
            color: AylaColors.textSecondary,
          ),
        ),
      ],
    );
  }

  /// 帖子卡（tsx 162–197）：loading / error / 空态 / 列表 + 更多帖子。
  Widget _postsCard(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    final Widget body;
    if (postsLoading) {
      // 3 条高 44 的骨架（.skeleton：radius-sm + glass-bg + 1px 边 + frost-pulse）
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: const <Widget>[
          AylaSkeleton(height: 44),
          AylaSkeleton(height: 44),
          AylaSkeleton(height: 44),
        ],
      );
    } else if ((postsError ?? '').isNotEmpty) {
      body = Text(
        postsError!,
        // .profile-content-empty：13px secondary
        style: t.body.copyWith(fontSize: 13, color: AylaColors.textSecondary),
      );
    } else if (posts.isEmpty) {
      body = Text(
        mine ? '还没有发帖' : '暂无帖子', // tsx 176
        style: t.body.copyWith(fontSize: 13, color: AylaColors.textSecondary),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // 列表 + 更多键之间的容器间距（卡片 gap sp3）
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp2, // .profile-posts-list { gap: var(--sp-2) }
            children: <Widget>[
              for (final AylaProfilePostItem post in posts) _postRow(context, post),
            ],
          ),
          // 更多帖子（align-self flex-start + min-height 36 + padding 0 sp4）
          Align(
            alignment: Alignment.centerLeft,
            child: AylaGlassButton(
              label: actionLabel,
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 36,
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
              onPressed: onMorePosts,
            ),
          ),
        ],
      );
    }

    return AylaProfileContentCard(
      icon: AylaIcon(
        aylaIconByName('iconPost')!,
        size: 16,
        color: AylaColors.ice500,
      ),
      title: '帖子',
      badge: posts.isNotEmpty ? _CountBadge(posts.length.toString()) : null,
      child: body,
    );
  }

  /// 帖子行（tsx 181–189）：标题或正文前 40 + 副行（正文前 40 · 时间）。
  Widget _postRow(BuildContext context, AylaProfilePostItem post) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool hasTitle = (post.title ?? '').isNotEmpty;
    final String head = hasTitle ? post.title! : _slice(post.body, 40);
    final String time = (post.createdAt ?? '').isNotEmpty
        ? aylaProfileFormatTime(post.createdAt!)
        : '';
    final String sub = hasTitle ? _slice(post.body, 40) : '';
    final String subLine = sub.isNotEmpty && time.isNotEmpty
        ? '$sub · $time'
        : (sub.isNotEmpty ? sub : time);

    return _ProfileContentRow(
      onTap: onOpenPost == null ? null : () => onOpenPost!(post.id),
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: <Widget>[
              Text(
                head,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.body.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AylaColors.textPrimary,
                ),
              ),
              if (subLine.isNotEmpty)
                Text(
                  subLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 桌游占位卡（tsx 200–208）。
  Widget _gameCard(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaProfileContentCard(
      icon: AylaIcon(
        aylaIconByName('iconGame')!,
        size: 16,
        color: AylaColors.ice500,
      ),
      title: '正在玩的桌游',
      child: Container(
        padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
        decoration: BoxDecoration(
          color: const Color(0x66FFFAFB), // rgba(255,250,251,.4)
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
        ),
        child: Row(
          spacing: AylaSpacing.sp3, // gap: var(--sp-3)
          children: <Widget>[
            AylaIcon(
              aylaIconByName('iconGame')!,
              size: 28, // IconGame 28
              color: AylaColors.ice500,
            ),
            Expanded(
              child: Text(
                '桌游玩法即将上线',
                style: t.body.copyWith(
                  fontSize: 13,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// web `post.body.slice(0, 40)`。
  static String _slice(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}

/// `.profile-live-badge`：LIVE 徽标（pill · --pink-500 底 · --surface 字 · display 11/500 · ls .8）。
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp2,
        vertical: 2,
      ),
      decoration: const BoxDecoration(
        color: AylaColors.pink500,
        borderRadius: AylaRadii.pill,
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.8,
          color: AylaColors.surface,
        ),
      ),
    );
  }
}

/// `.profile-voice-count` / `.profile-content-count`：utility 12 secondary。
class _CountBadge extends StatelessWidget {
  const _CountBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: AylaFonts.utility,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 12,
        color: AylaColors.textSecondary,
      ),
    );
  }
}

/// `.profile-content-row`（三处共用）：玻璃行 + hover（底 ice 蓝 .18 + 边 glass-border，180ms）。
class _ProfileContentRow extends StatefulWidget {
  const _ProfileContentRow({required this.children, this.onTap});

  final List<Widget> children;
  final VoidCallback? onTap;

  @override
  State<_ProfileContentRow> createState() => _ProfileContentRowState();
}

class _ProfileContentRowState extends State<_ProfileContentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AylaDurations.fast, // --dur-fast 180ms
          curve: AylaCurves.easeOut,
          padding: const EdgeInsets.symmetric(
            vertical: AylaSpacing.sp2,
            horizontal: AylaSpacing.sp3,
          ),
          decoration: BoxDecoration(
            // 静息 rgba(255,250,251,.4) → hover rgba(157,191,230,.18)
            color: _hovered
                ? const Color(0x2E9DBFE6)
                : const Color(0x66FFFAFB),
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            border: Border.all(
              color: _hovered ? AylaColors.glassBorder : Colors.transparent,
            ),
          ),
          child: Row(
            spacing: AylaSpacing.sp3, // gap: var(--sp-3)
            children: widget.children,
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// 个人主页内容分区样张。
///
/// 单档：全内容（直播 + 语音并排 + 3 帖 + 桌游占位）。
///
/// ⚠️ loading / error / 空态**不在画布上重复摆档**（组件每档都会渲染「帖子」与「正在玩的桌游」
/// 两张卡，多摆会显得像多余的卡）—— 这三种状态由定向测试覆盖（骨架 3×44、error 文案、两档空态文案）。
Widget aylaProfileContentSectionsSamples() => const _ProfileSectionsDemo();

class _ProfileSectionsDemo extends StatelessWidget {
  const _ProfileSectionsDemo();

  static const List<AylaProfilePostItem> _posts = <AylaProfilePostItem>[
    AylaProfilePostItem(
      id: 'p1',
      title: '周末的雪山行记',
      body: '一路向北，雪线以下全是雾凇……',
      createdAt: '2026-09-25T10:00:00Z',
    ),
    AylaProfilePostItem(
      id: 'p2',
      title: '深夜电台歌单',
      body: '这周循环的三首。',
      createdAt: '2026-09-24T22:30:00Z',
    ),
    AylaProfilePostItem(
      id: 'p3',
      body: '只有正文的一条帖子，标题缺失时取正文前 40 字作为标题行。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 720,
          child: AylaProfileContentSections(
            displayName: '爱莉',
            live: const AylaProfileLiveData(
              id: 'l1',
              title: '爱莉的直播间',
              ownerNickname: '爱莉',
            ),
            voice: const AylaProfileVoiceData(
              id: 'v1',
              name: '深夜电台',
              ownerNickname: '爱莉',
              memberCount: 3,
            ),
            posts: _posts,
            mine: true,
            onOpenLive: _noopId,
            onOpenVoice: _noopId,
            onOpenPost: _noopId,
            onMorePosts: _noop,
          ),
        ),
      ],
    );
  }
}

void _noop() {}

void _noopId(String id) {}
