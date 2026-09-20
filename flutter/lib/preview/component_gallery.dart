/// 组件库审核画布（Batch 1：材料基元 + 基元组件）。
///
/// 用途（用户 2026-09-18 定）：**逐个组件审核**，而不是先看整页。
/// 本文件提供一张「大画面」预览卡，把当前批次组件按 web 原始尺寸并排
/// 铺开，供用户在预览器里逐项对照 web 审核。
///
/// 排布纪律：
/// - 每个组件区上方标出其 **web 选择器 + 数值来源文件**，便于对照；
/// - 组件一律用真实尺寸（不缩放、不留白填充），宽屏按 web CSS 像素原值
///   （Windows 125% 口径：web CSS px = Flutter 逻辑 px）；
/// - 本画布只含组件，不含页面。
///
/// 当前批次事实源（全部来自 web 源码，非旧实现）：
/// - `app.css` `.btn/.btn-primary/.btn-glow/.btn-ghost/.field/.glass-card/.avatar*`
/// - `auroraqua.css`（交互/覆写/sweep）
/// - `base.css`（spinner/skeleton/fullscreen-loader/frost-pulse/halo-breathe）
/// - `shell.css` `.tab-badge`
/// - `tokens.css` / `design.md` §2/§3/§4/§6/§7.3
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import '../widgets/avatar_halo.dart';
import '../widgets/avatar_status_badges.dart';
import '../widgets/dialogs.dart';
import '../widgets/directory_controls.dart';
import '../widgets/privacy_sheet.dart';
import '../widgets/profile_and_filters.dart';
import '../widgets/group_card.dart';
import '../widgets/media_interaction.dart';
import '../core/media/media_signer.dart';
import '../core/net/dio_client.dart';
import '../widgets/resource_image.dart';
import '../widgets/loading.dart';
import '../widgets/comments.dart';
import '../widgets/image_viewer.dart';
import '../widgets/post_card.dart';
import '../widgets/post_editor.dart';
import '../widgets/primitives.dart';
import '../widgets/reveal.dart';
import '../widgets/tab_badge.dart';

/// 审核画布尺寸（单张大画面；宽度 1800 容纳四列组件与 12 列图标，
/// 高度按内容收紧——图标区 + 排版区结束约在 1450，余量留到 1700）。
const Size kGallerySize = Size(1800, 1700);

/// 组件库审核画布。
class ComponentGallery extends StatelessWidget {
  const ComponentGallery({super.key});

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AylaSpacing.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Ayla Flutter 组件库 · Batch 1（材料基元）', style: t.pageTitle),
          const SizedBox(height: AylaSpacing.sp2),
          Text(
            '对照 web：tokens.css/app.css/auroraqua.css/base.css/shell.css · Windows 125% 口径',
            style: t.caption.copyWith(color: AylaColors.textSecondary),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- GlassButton ----------
          _Section(
            title: 'GlassButton（app.css .btn 21–67 / auroraqua.css 54–166）',
            source:
                '.btn：gap 8 · min-h 40 · padding 0 24 · radius 12 · 14px/700/ls .2 · 200ms',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 登录页主 CTA：.auth-submit（width 100% / 44 高 / btn-glow）
                _Slot(
                  label: '登录主 CTA（.auth-submit 44 · btn-glow）',
                  width: 374,
                  child: GlassButton(
                    label: '登录',
                    variant: GlassButtonVariant.glow,
                    minHeight: 44,
                    expand: true,
                    onPressed: () {},
                  ),
                ),
                const SizedBox(height: AylaSpacing.sp6),
                _Row(
                  children: <Widget>[
                    _Slot(
                      label: 'pending（disabled .55）',
                      width: 220,
                      child: GlassButton(
                        label: '登录中…',
                        variant: GlassButtonVariant.glow,
                        minHeight: 44,
                        expand: true,
                        onPressed: null,
                      ),
                    ),
                    _Slot(
                      label: 'ghost（.auth-switch-link\nmin-w 72 / 44）',
                      child: GlassButton(
                        label: '注册',
                        variant: GlassButtonVariant.ghost,
                        minHeight: 44,
                        minWidth: 72,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        onPressed: () {},
                      ),
                    ),
                    _Slot(
                      label: 'primary（40 高）',
                      child: GlassButton(label: '登录', onPressed: () {}),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- GlassCard ----------
          _Section(
            title: 'GlassCard（app.css .glass-card 230–248）',
            source:
                '.glass-bg .55 · blur 24 saturate 1.4 · 1px 白边 .65 · 16px 圆角 · 8/32 阴影 · 顶沿内高光',
            child: _Row(
              children: <Widget>[
                _Slot(
                  label: '静态卡（padding 16）',
                  width: 300,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('静态玻璃卡', style: t.cardTitle),
                        const SizedBox(height: AylaSpacing.sp2),
                        Text(
                          '--glass-bg .55 / blur 24 / 16 圆角 / 8·32 阴影',
                          style: t.caption.copyWith(
                            color: AylaColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _Slot(
                  label: '可交互（hover 上浮 2px）',
                  width: 300,
                  child: GlassCard(
                    interactive: true,
                    onTap: () {},
                    child: Text('可交互玻璃卡', style: t.cardTitle),
                  ),
                ),
                _Slot(
                  label: 'strong 弹层底（.78）',
                  width: 300,
                  child: GlassCard(
                    strong: true,
                    radius: AylaRadii.rPanel,
                    shadow: AylaShadows.modal,
                    child: Text('strong 弹层卡', style: t.cardTitle),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- GlassInput ----------
          // 尺寸口径:登录认证卡内宽 440 − 卡内沿 32×2 = 374（.auth-submit
          // 满宽字段与它同宽,故样张统一按 374 呈现,不缩成窄列）。
          _Section(
            title: 'GlassInput（app.css .field 70–88 / auroraqua.css 502–523）',
            source:
                'padding 12×16 · radius 12 · --glass-bg + 亮边 · focus 辉光边 · placeholder slate-500',
            child: SizedBox(
              width: 374,
              child: _Rows(
                children: <Widget>[
                  _InputSample(
                    label: '常态（认证卡内：indigo .3 描边）',
                    onGlassBorder: true,
                  ),
                  _InputSample(
                    label: 'focus（#F796FF 边 + 辉光）',
                    autofocus: true,
                    onGlassBorder: true,
                  ),
                  _InputSample(
                    label: '密码类型',
                    obscure: true,
                    text: '12345678',
                    onGlassBorder: true,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- AvatarHalo ----------
          _Section(
            title:
                'AvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）',
            source: '2.5px 锥形渐变环 conic 210° · 离线 --ice-100 · 爱莉 3.2s 呼吸辉光',
            child: _Row(
              children: <Widget>[
                _Slot(
                  label: '40 爱莉在线（呼吸 + 辉光）',
                  child: const AvatarHalo(
                    label: '爱莉',
                    size: 40,
                    online: true,
                    core: AvatarCore.elysia,
                  ),
                ),
                _Slot(
                  label: '40 在线',
                  child: const AvatarHalo(label: '在线', size: 40, online: true),
                ),
                _Slot(
                  label: '40 离线',
                  child: const AvatarHalo(label: '离线', size: 40),
                ),
                _Slot(
                  label: '36 在线（窄屏顶栏）',
                  child: const AvatarHalo(label: '在线', size: 36, online: true),
                ),
                _Slot(
                  label: '24 在线（群卡底行）',
                  child: const AvatarHalo(label: '群', size: 24, online: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- TabBadge（三档规格，2026-09-20 审查 R8 合并） ----------
          _Section(
            title:
                'TabBadge（shell.css .tab-badge 579–593 · home.css .group-badge 302–317 · messages.css .messages-tab-badge 43–55）',
            source:
                'tab：min 16 / padding 0 4 / Fredoka 11 w500 / 绝对 top -4 right -12 · '
                'groupBadge：16 / Fredoka 11 w400 / 行内 · messages：18 / Space Grotesk 11 / 行内 + glow · >99 → 99+',
            child: _Row(
              children: <Widget>[
                _Slot(label: 'tab：1', child: _BadgeHost(count: 1)),
                _Slot(label: 'tab：12', child: _BadgeHost(count: 12)),
                _Slot(label: 'tab：150 → 99+', child: _BadgeHost(count: 150)),
                _Slot(
                  label: 'groupBadge（.group-badge-unread）',
                  child: const TabBadge(
                    count: 8,
                    metrics: TabBadgeMetrics.groupBadge,
                    placement: TabBadgePlacement.inline,
                  ),
                ),
                _Slot(
                  label: 'messages（.messages-tab-badge + glow）',
                  child: const TabBadge(
                    count: 120,
                    metrics: TabBadgeMetrics.messages,
                    placement: TabBadgePlacement.inline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 帖子卡族（B5） ----------
          _Section(
            title:
                'AylaPostCard / AylaPostVideoCover（PostCard.tsx + posts.css 9–217 + typed-result-cards.css 5,7）',
            source:
                'glass-bg + 16 圆角 + overflow hidden · hover（父级）translate -2px + shadow-hover + brightness 1.01 · active scale .99 · 正文 15/1.55 三行折叠 · 1 图 contain max-h 240 / 多图 3 列 gap 4 · 底排：查看帖子(12 secondary) + 统计(Space Grotesk 12) + 收藏(compact) + 分享(纯圆钮 40) · 排列：>1025 两列瀑布（轨道 1200 / 列距 12）/ <=1024 单列',
            child: aylaPostCardSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 发帖编辑器（B5） ----------
          _Section(
            title:
                'AylaPostEditor（PostEditor.tsx + posts.css 219–418 + auroraqua.css 105–166）',
            source:
                '三形态：常规 / 群内 collapsible 收起 / 展开 · padding sp3（collapsible sp2 sp3）· 展开 max-height min(90vh,1000px) · 收起钮 32 圆 · 标题 min-h 40 · 正文 展开 rows4/min-h 64、收起 单行 40 · 媒体块 128 方角（web --radius-md 未定义）、移除钮 28 圆 · 进度条 4px pill pink-500 · 图片/视频钮 glass 亮边 + hover glow（glowHover）· 可见性复用 AylaVisibilitySelector（群内 lockGroup）',
            child: aylaPostEditorSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 评论族（B5） ----------
          _Section(
            title:
                'AylaCommentList / AylaCommentComposer（CommentList.tsx + CommentComposer.tsx + posts.css 420–583）',
            source:
                '评论项：padding sp3 sp4 + 底部 1px 亮边 · 头像 32 · 昵称 14/700 · 时间 utility 11（zh-CN）· 回复提示 12 · 正文 14 · 操作行 12/600（回复 / 作者可删除，删除色 --destructive）· 图片 2 列 gap sp1 max-w 280（单图 200）、4:3 cover、方角（web --radius-md 未定义）· 输入：padding sp3 sp4 + 上边框 · 行 gap sp3 align-end · 工具钮 40（AylaToolButton，12 圆角）· 待发图 64px + 18px × · 底部滑入 250ms',
            child: aylaCommentSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 查看器（B5） ----------
          _Section(
            title:
                'AylaImageViewer（ImageViewer.tsx + app.css 1459–1836 + auroraqua.css 55–94）',
            source:
                '遮罩 --overlay-dim-strong + blur(8)（无 saturate）· 入场 opacity 180ms --ease-out · 关闭钮 40 圆 · 舞台 max min(92vw,1200) / 82vh · 图片 contain + radius-input + --surface + --card-shadow · 导航 44 圆（blur12 saturate1.4，禁用 0.35）· 操作条 pill 玻璃（blur18）+ 计数（Space Grotesk 12/ls.5）+ 保存（IconDownload 16）· 失败提示 bottom 76 · 横滑阈值 1/3 或 300px/s+40px（useSwipeCommit）· 条目 enter x=±40% 250ms · 样张走 embedded（嵌入画布不做 backdrop 模糊，避免糊宿主页面）',
            child: aylaImageViewerSamples(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 入场动画（2026-09-20 审查 R7：公共件） ----------
          _Section(
            title: 'AylaRevealItem / AylaRevealScope（base.css .reveal-item · auroraqua.css 8–26 · useListEntryMotion）',
            source:
                'opacity 0→1 + 下 20px · 300ms --auroraqua-ease-out · stagger 50ms（cap 300）· reduced-motion 直接到位 · enabled:false 不挂动画',
            child: _Row(
              children: <Widget>[
                _Slot(
                  label: '下入 20px · stagger 0/50/100ms',
                  width: 300,
                  child: AylaRevealScope(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: AylaSpacing.sp2,
                      children: <Widget>[
                        for (int i = 0; i < 3; i++)
                          AylaRevealItem(
                            index: i,
                            child: Text(
                              '条目 $i（delay ${i * 50}ms）',
                              style: t.caption,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _Slot(
                  label: '上入 20px（offset 0,-20）',
                  width: 300,
                  child: AylaRevealItem(
                    offset: const Offset(0, -AylaRevealMotion.distance),
                    child: Text('上入样张', style: t.caption),
                  ),
                ),
                _Slot(
                  label: 'enabled:false（滚动恢复/历史节点）',
                  width: 300,
                  child: const AylaRevealItem(
                    enabled: false,
                    child: Text('直接显示，不挂动画', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 加载族 ----------
          _Section(
            title: 'Skeleton + Spinner + FullScreenLoader（base.css 515–574）',
            source:
                'spinner 18px/800ms · skeleton radius 8 + frost-pulse .55↔.9 1600ms · loader 品牌 40px 渐变字',
            child: _Row(
              children: <Widget>[
                _Slot(
                  label: '骨架行（44 头像 + 两行）',
                  width: 260,
                  child: const _SkeletonSample(),
                ),
                _Slot(
                  label: 'spinner md / sm',
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      LoadingSpinner(),
                      SizedBox(width: AylaSpacing.sp3),
                      LoadingSpinner(size: 14),
                    ],
                  ),
                ),
                _Slot(
                  label: 'FullScreenLoader（无卡片）',
                  width: 300,
                  child: SizedBox(
                    height: 220,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AylaRadii.rCard),
                      child: const FullScreenLoader(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 图标库（全量 47 个） ----------
          _Section(
            title: 'Icon 图标库（web components/icons.tsx 全量 47 个）',
            source: 'viewBox 24 · 2px 描边 · round cap/join · 默认 18px · 实心特例已还原',
            child: Wrap(
              spacing: AylaSpacing.sp4,
              runSpacing: AylaSpacing.sp6,
              crossAxisAlignment: WrapCrossAlignment.start,
              children: <Widget>[
                for (final AylaIconData icon in kAylaIcons)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AylaIcon(icon, size: 18, color: AylaColors.indigo700),
                      const SizedBox(height: AylaSpacing.sp1),
                      SizedBox(
                        width: 110,
                        child: Text(
                          icon.name,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.timestamp.copyWith(
                            color: AylaColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- B2 展示型基元 ----------
          _Section(
            title:
                'Batch 2 基元（LayoutSwitch / SegmentedTab / CapsuleTag / ScrollingText）',
            source:
                'home.css .layout-switch 182–206 · messages.css .messages-tab 24–37 · '
                'd:§4 胶囊 · base.css .scroll-text 724–758（marquee）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Row(
                  children: <Widget>[
                    _Slot(
                      label: 'LayoutSwitch（点击切换·胶囊 300ms 迁移）',
                      child: const _LayoutSwitchDemo(),
                    ),
                  ],
                ),
                const SizedBox(height: AylaSpacing.sp6),
                const SizedBox(width: 420, child: _TabsDemo()),
                const SizedBox(height: AylaSpacing.sp4),
                const Wrap(
                  spacing: AylaSpacing.sp2,
                  runSpacing: AylaSpacing.sp2,
                  children: <Widget>[
                    AylaCapsuleTag('数字生命'),
                    AylaCapsuleTag('持续记忆'),
                    AylaCapsuleTag('历史搜索', tone: CapsuleTone.ice),
                    AylaCapsuleTag('玻璃胶囊', tone: CapsuleTone.glass),
                    AylaCapsuleTag('LIVE', tone: CapsuleTone.pink),
                    AylaCapsuleTag('实底', tone: CapsuleTone.indigo),
                  ],
                ),
                const SizedBox(height: AylaSpacing.sp4),
                const SizedBox(
                  width: 300,
                  child: AylaScrollingText(
                    text: '长文本 marquee 滚动验证：这是一段超出容器的文本，用来核对来回滚动与停顿时序',
                  ),
                ),
                const SizedBox(height: AylaSpacing.sp4),
                const SizedBox(
                  width: 260,
                  child: AylaScrollingTags(
                    children: <Widget>[
                      AylaCapsuleTag('公开'),
                      AylaCapsuleTag('好友可见', tone: CapsuleTone.ice),
                      AylaCapsuleTag('指定群可见', tone: CapsuleTone.glass),
                      AylaCapsuleTag('我的收藏', tone: CapsuleTone.pink),
                      AylaCapsuleTag('更多标签', tone: CapsuleTone.indigo),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- B3 卡片族（窄屏组件） ----------
          _Section(
            title:
                'GroupCard / GroupCarousel（home.css 224–503 + auroraqua 29–52）',
            source:
                '玻璃卡 16 圆角 · 4:3 轮播内嵌 8 · 3s/300ms · 指示点 4px · hover -2px + shadow-hover · active .99',
            child: const _GroupCardDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- B4 通用基元 ----------
          _Section(
            title: 'ResourceImage（ResourceImage.tsx + api/media.ts）',
            source:
                '签名链路（缓存至到期前 60s / 并发只签一次 / 原图 410 降级 thumb / thumb 410 过期）· alt="" 装饰图失败不提示',
            child: const _ResourceImageDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),
          _Section(
            title:
                'ConfirmDialog / AsyncState（ConfirmDialog.tsx + AsyncState.tsx）',
            source:
                'create-sheet 弹层复用（overlay .25 + glass-bg-strong + radius-panel 20 + modal 阴影）· 窄屏贴底 · 自动聚焦取消 · busy 禁全部关闭',
            child: const _DialogsDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),
          _Section(
            title:
                'PullToRefresh / SignedVideo（PullToRefresh.tsx + SignedVideo.tsx）',
            source:
                '阻尼 dampPull = maxPull*(1-e^-dy/90) · 阈值用原始 dy · 36 玻璃圆点三态 · thumbnail 不可作 video src',
            child: const _InteractionDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),
          _Section(
            title: '分页族 / 收藏按钮（DirectoryLoadMore + StablePaginationFooter + FavoriteButton）',
            source:
                'stable-pagination-footer min-h 80（最高高度锁定不塌缩）· 三点 6px ice-500 · favorite-toggle 36/pill/glass-bg-strong，选中转 pink+辉光',
            child: const _PaginationAndFavoriteDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),
          _Section(
            title: 'VisibilitySelector / 资料卡 / 筛选条 / 隐私设置',
            source:
                '公开↔好友互斥、群可见独立可叠加 · user-profile-card min(320,85vw)+sp6+modal 阴影 · directory-filters 224 侧栏 · privacy-sheet 60dvh 窄屏 + 两步换绑',
            child: const _DirectoryAndProfileDemo(),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 排版阶梯 ----------
          _Section(
            title: 'Typography（design.md §3 九级）',
            source:
                'Display=Fredoka / Body=Nunito / Utility=Space Grotesk，CJK 回退链',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Display Hero 40/600 · Ayla 爱莉', style: t.displayHero),
                Text('Page Title 28/600 · 语音大厅', style: t.pageTitle),
                Text('Card Title 20/500 · 静态玻璃卡', style: t.cardTitle),
                Text('Bubble / Body 15/400 · 聊天正文示例', style: t.body),
                Text('Body Strong 15/700 · 昵称加粗', style: t.bodyStrong),
                Text('Label / Button 14/700 · 登录按钮', style: t.label),
                Text('Caption 13/400 · 次要说明文字', style: t.caption),
                Text('Timestamp 12/400 · 21:10', style: t.timestamp),
                Text('MICRO TAG 11/500 · 新内容', style: t.microTag),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 布局切换演示（可点击，观察胶囊 300ms 迁移）。
class _LayoutSwitchDemo extends StatefulWidget {
  const _LayoutSwitchDemo();

  @override
  State<_LayoutSwitchDemo> createState() => _LayoutSwitchDemoState();
}

class _LayoutSwitchDemoState extends State<_LayoutSwitchDemo> {
  bool _isCard = true;

  @override
  Widget build(BuildContext context) {
    return AylaLayoutSwitch(
      isCard: _isCard,
      onChanged: (bool v) => setState(() => _isCard = v),
    );
  }
}

/// 选项卡迁移演示（可点击切换，观察共享胶囊 300ms 滑动）。
class _TabsDemo extends StatefulWidget {
  const _TabsDemo();

  @override
  State<_TabsDemo> createState() => _TabsDemoState();
}

class _TabsDemoState extends State<_TabsDemo> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return AylaSegmentedTabs(
      labels: const <String>['私信', '认证消息', '系统'],
      index: _i,
      badges: const <int>[0, 5, 0],
      onChanged: (int i) => setState(() => _i = i),
    );
  }
}

/// 分区（标题 + 来源 + 内容）。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.source,
    required this.child,
  });

  final String title;
  final String source;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: t.cardTitle),
        const SizedBox(height: AylaSpacing.sp1),
        Text(
          source,
          style: t.timestamp.copyWith(color: AylaColors.textSecondary),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        child,
      ],
    );
  }
}

/// 横向一排（每项自带标签）。
class _Row extends StatelessWidget {
  const _Row({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: children,
    );
  }
}

/// 纵向一列（输入样张用）。
class _Rows extends StatelessWidget {
  const _Rows({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: AylaSpacing.sp4),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 单个展位（下方小字标注；内容按自身内在尺寸渲染，有明确宽度才用 [width]）。
class _Slot extends StatelessWidget {
  const _Slot({required this.label, required this.child, this.width});

  final String label;
  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (width != null) SizedBox(width: width, child: child) else child,
        const SizedBox(height: AylaSpacing.sp2),
        SizedBox(
          width: width ?? 180,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AylaTextStyles.light.timestamp.copyWith(
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 徽标宿主（40px 玻璃方，模拟图标钮）。
class _BadgeHost extends StatelessWidget {
  const _BadgeHost({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(color: AylaColors.glassBorder),
              ),
            ),
          ),
          TabBadge(count: count),
        ],
      ),
    );
  }
}

/// 骨架行样张。
class _SkeletonSample extends StatelessWidget {
  const _SkeletonSample();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        AylaSkeleton(
          width: 44,
          height: 44,
          radius: AylaRadii.rPill,
          shape: BoxShape.circle,
        ),
        SizedBox(width: AylaSpacing.sp3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AylaSkeleton(width: 120, height: 14),
              SizedBox(height: AylaSpacing.sp2),
              AylaSkeleton(width: 200, height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// 输入样张。
class _InputSample extends StatefulWidget {
  const _InputSample({
    required this.label,
    this.autofocus = false,
    this.obscure = false,
    this.text = '',
    this.onGlassBorder = false,
  });

  final String label;
  final bool autofocus;
  final bool obscure;
  final String text;
  final bool onGlassBorder;

  @override
  State<_InputSample> createState() => _InputSampleState();
}

class _InputSampleState extends State<_InputSample> {
  late final TextEditingController _c = TextEditingController(
    text: widget.text,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(widget.label, style: AylaTextStyles.light.timestamp),
        const SizedBox(height: AylaSpacing.sp2),
        GlassInput(
          controller: _c,
          hintText: '用户名',
          autofocus: widget.autofocus,
          obscureText: widget.obscure,
          onGlassBorder: widget.onGlassBorder,
          minHeight: 44,
          textStyle: AylaTextStyles.light.label.copyWith(
            fontWeight: FontWeight.w400,
            color: AylaColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 组件库审核画布：**本次唯一启用的预览卡**。
@Preview(
  group: 'Gallery',
  name: '组件库（1800×1700 大画面）',
  size: Size(1800, 1700),
  wrapper: previewScope,
)
Widget componentGalleryPreview() => const ComponentGallery();

/// B3 卡片族样张：窄屏 2 列网格 + 列表（卡片族**仅 ≤768 生效**——HomePage
/// 在宽屏 `if (!isNarrow) return <Navigate to={/group/:id}/>`）。
class _GroupCardDemo extends StatelessWidget {
  const _GroupCardDemo();

  @override
  Widget build(BuildContext context) {
    // 预览用外部占位图（真实链路走后端媒体签名，属媒体批次）
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
      const GroupCarouselSlide.live(host: '小樱', title: '一起看星星', cover: imgA),
      const GroupCarouselSlide.post(
        title: '周末去哪玩',
        body: '大家周末有空吗？想去海边看日落，顺便拍点照片。',
        image: imgB,
        hasUnread: true,
      ),
      const GroupCarouselSlide.game(name: '你画我猜', memberCount: 4),
    ];

    const List<GroupCarouselSlide> noImage = <GroupCarouselSlide>[
      GroupCarouselSlide.messageVoice(
        newMessageCount: 3,
        voiceRooms: <GroupSlideVoiceRoom>[],
      ),
      GroupCarouselSlide.live(host: '小蓝', title: '新番同步看'),
    ];

    // 用 Wrap 而非 Row：测试视口（800 宽）下两列会溢出 46px（widget test 抓到）；
    // 画布 1800 宽时仍是并排两列。
    return Wrap(
      spacing: AylaSpacing.sp8,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // 窄屏列宽 375（卡片族设计基准）
        SizedBox(
          width: 375,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
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
                    title: '置顶的长群名测试省略号',
                    slides: noImage,
                    unread: 128,
                    isPinned: true,
                    onOpen: () {},
                    onTogglePin: (_) {},
                  ),
                ],
              ),
              AylaGroupList(
                children: <Widget>[
                  AylaGroupListItem(
                    groupId: 'g1',
                    title: '星海观测站',
                    status: const AvatarStatus(
                      unread: 12,
                      live: true,
                      voice: true,
                    ),
                    preview: '小樱：今晚一起吃饭吗',
                    isPinned: true,
                    onOpen: () {},
                  ),
                  AylaGroupListItem(
                    groupId: 'g2',
                    title: '作业互助',
                    status: const AvatarStatus(unread: 3, voice: true),
                    memberCount: 8,
                    onOpen: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
        // 空态 / 状态组合
        SizedBox(
          width: 375,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AylaGroupGrid(
                children: <Widget>[
                  AylaGroupCard(
                    groupId: 'g3',
                    title: '空状态群',
                    slides: const <GroupCarouselSlide>[],
                    onOpen: () {},
                  ),
                  AylaGroupCard(
                    groupId: 'g4',
                    title: '无图占位',
                    slides: noImage,
                    unread: 3,
                    onOpen: () {},
                  ),
                ],
              ),
              AylaGroupList(
                children: <Widget>[
                  AylaGroupListItem(
                    groupId: 'g3',
                    title: '新内容群',
                    newEventText: '阿蓝 创建了语音房 深夜电台',
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
        ),
      ],
    );
  }
}

// ======================= B4 通用基元素材 =======================

/// ResourceImage 全状态样张。
class _ResourceImageDemo extends StatelessWidget {
  const _ResourceImageDemo();

  @override
  Widget build(BuildContext context) {
    // ⚠️「原图已过期」角标只有签名链路能产生（original 410 → 降级 thumb 并置
    // originalExpired=true，api/media.ts 50–53）；外部 URL 永远看不到。
    // 故注入受控假 client，让 `expired-original` / `fully-expired` 两个 id
    // 走真实的降级/过期分支（同一代码路径，数据源可控）。
    MediaSigner.instance.attach(PreviewMediaClient());
    const String ok = 'https://picsum.photos/seed/ayla-ri/240/180';
    const String expiredOriginal = '/api/v1/media/expired-original/content';
    const String fullyExpired = '/api/v1/media/fully-expired/content';
    Widget cell(String label, Widget child) => SizedBox(
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(width: 200, height: 140, child: child),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      children: <Widget>[
        cell('正常（外部 URL 直连）', const ResourceImage(src: ok, alt: '示例图')),
        cell(
          '⭐ 原图已过期 → 缩略图 + 角标',
          const ResourceImage(
            src: expiredOriginal,
            alt: '图',
            expiredBadge: true,
          ),
        ),
        cell(
          '完全过期 → 「已过期」占位',
          const ResourceImage(src: fullyExpired, alt: '图'),
        ),
        cell('装饰图（alt="" → 过期不提示）', const ResourceImage(src: fullyExpired)),
      ],
    );
  }
}

/// ConfirmDialog + AsyncState 样张。
class _DialogsDemo extends StatelessWidget {
  const _DialogsDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // ConfirmDialog 需要占位画框（它是 overlay 式布局）
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            children: <Widget>[
              ConfirmDialog(
                title: '删除会话',
                message: '删除会话「小樱」？\n消息记录会保留。',
                onConfirm: () {},
                onClose: () {},
              ),
              const Positioned(
                left: 4,
                bottom: 4,
                child: Text(
                  'ConfirmDialog（默认）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            children: <Widget>[
              ConfirmDialog(
                title: '删除会话',
                message: '删除会话「小樱」？',
                busy: true,
                onConfirm: () {},
                onClose: () {},
              ),
              const Positioned(
                left: 4,
                bottom: 4,
                child: Text(
                  'ConfirmDialog（busy）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        // AsyncState 四态
        SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 高度需容纳：minHeight 96 + padding 32（loading/empty 足够）
              const SizedBox(
                height: 130,
                child: AylaAsyncState(status: AsyncStatus.loading),
              ),
              const Text('loading', style: TextStyle(fontSize: 11)),
              // error 态还需「文案 + gap sp3 + 重试按钮」→ 给足 210
              SizedBox(
                height: 210,
                child: AylaAsyncState(
                  status: AsyncStatus.error,
                  error: '网络连接失败',
                  onRetry: () {},
                ),
              ),
              const Text('error', style: TextStyle(fontSize: 11)),
              const SizedBox(
                height: 130,
                child: AylaAsyncState(status: AsyncStatus.empty),
              ),
              const Text('empty', style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

/// PullToRefresh / SignedVideo 样张。
class _InteractionDemo extends StatelessWidget {
  const _InteractionDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 375,
          height: 380,
          child: AylaPullToRefresh(
            isAtTop: () => true,
            onRefresh: () async =>
                Future<void>.delayed(const Duration(milliseconds: 600)),
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AylaSpacing.sp3),
              children: <Widget>[
                for (int i = 0; i < 6; i++)
                  Container(
                    margin: const EdgeInsets.only(bottom: AylaSpacing.sp2),
                    height: 48,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp3,
                    ),
                    decoration: BoxDecoration(
                      color: AylaColors.glassBg,
                      borderRadius: BorderRadius.circular(AylaRadii.rInput),
                      border: Border.all(color: AylaColors.glassBorder),
                    ),
                    child: Text('列表项 ${i + 1}（下拉刷新）'),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SignedVideo(mediaId: 'demo-1'),
              const SizedBox(height: 6),
              const Text(
                'SignedVideo（failed 态，可点重试）',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 预览用假签名 client（公开版，画布与 @Preview 复用）：
/// 按 media_id 前缀模拟后端 `:sign` 的分级过期行为。
class PreviewMediaClient implements DioClient {
  @override
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    final bool expiredOriginal = path.contains('expired-original');
    final bool fullyExpired = path.contains('fully-expired');
    if ((expiredOriginal && !isThumb) || fullyExpired) {
      throw const ApiException(410, 'media_expired');
    }
    return <String, dynamic>{
          'url':
              'https://picsum.photos/seed/ayla-${isThumb ? "thumb" : "orig"}/240/180',
          'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
        }
        as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}


// ======================= B4 剩余素材 =======================

/// 分页族 + 收藏按钮。
class _PaginationAndFavoriteDemo extends StatelessWidget {
  const _PaginationAndFavoriteDemo();

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, Widget child) => SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x22465B92)),
                ),
                child: child,
              ),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        );

    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        cell(
          'hasMore → 加载更多',
          AylaDirectoryLoadMore(
            loading: false, error: null, hasMore: true, invalidated: false,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          'loading → 三点',
          AylaDirectoryLoadMore(
            loading: true, error: null, hasMore: true, invalidated: false,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          'invalidated → 刷新中',
          AylaDirectoryLoadMore(
            loading: false, error: null, hasMore: true, invalidated: true,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          '历史控制：更早 + 返回最新',
          AylaHistoryControls(
            loading: false, error: null, hasMore: true, hasNewer: true,
            loadOlder: () async {}, returnLatest: () async {}, retry: () async {},
          ),
        ),
        SizedBox(
          width: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: AylaSpacing.sp3,
                runSpacing: AylaSpacing.sp3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  AylaFavoriteButton(
                    state: FavoriteState.notFavorited, onToggle: (_) {}),
                  AylaFavoriteButton(
                    state: FavoriteState.favorited, onToggle: (_) {}),
                  AylaFavoriteButton(
                    state: FavoriteState.unknown, onRetryStatus: () {}),
                  AylaFavoriteButton(
                    state: FavoriteState.error, onRetryStatus: () {}),
                  AylaFavoriteButton(
                    state: FavoriteState.favorited, compact: true, onToggle: (_) {}),
                ],
              ),
              const SizedBox(height: 6),
              const Text('FavoriteButton 五态（含 compact 32 圆钮）',
                  style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可见性选择器 + 资料卡 + 筛选条 + 隐私设置。
///
/// **有状态**：DirectoryFilters 两种形态都可点击/键盘切换（高亮 300ms 迁移）。
class _DirectoryAndProfileDemo extends StatefulWidget {
  const _DirectoryAndProfileDemo();

  @override
  State<_DirectoryAndProfileDemo> createState() =>
      _DirectoryAndProfileDemoState();
}

class _DirectoryAndProfileDemoState extends State<_DirectoryAndProfileDemo> {
  /// 宽屏侧栏选中项（点击/↑↓ 切换）。
  String _wideValue = 'posts';

  /// 窄屏顶栏选中项（点击/←→ 切换）。
  String _narrowValue = 'groups';

  @override
  Widget build(BuildContext context) {
    const List<({String id, String title})> groups =
        <({String id, String title})>[
      (id: 'g1', title: '星海观测站'),
      (id: 'g2', title: '作业互助'),
      (id: 'g3', title: '深夜电台'),
    ];
    const List<({String key, String label})> opts = <({String key, String label})>[
      (key: 'all', label: '全部'),
      (key: 'users', label: '用户'),
      (key: 'groups', label: '群聊'),
      (key: 'posts', label: '帖子'),
      (key: 'live', label: '直播间'),
      (key: 'games', label: '桌游室'),
    ];

    return Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 340,
          child: AylaVisibilitySelector(
            value: const VisibilitySelection(isPublic: true, group: true),
            onChange: (_) {},
            selectedGroupIds: const <String>['g1', 'g3'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        SizedBox(
          width: 340,
          child: AylaVisibilitySelector(
            value: const VisibilitySelection(group: true),
            onChange: (_) {},
            lockGroup: true,
            initialGroupId: 'g2',
            selectedGroupIds: const <String>['g2'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        // ---------- DirectoryFilters 宽屏侧栏（可交互） ----------
        SizedBox(
          height: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: 340,
                child: AylaDirectoryFilters(
                  label: '搜索结果分类',
                  options: opts,
                  value: _wideValue, // 可交互：点击 / ↑↓ / Home / End
                  onChange: (String v) => setState(() => _wideValue = v),
                  header: Column(
                    spacing: 2,
                    children: <Widget>[
                      Text('SEARCH',
                          style: TextStyle(
                            fontFamily: 'Fredoka',
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.4,
                            color: AylaColors.pink500,
                          )),
                      Text('搜索结果',
                          style: TextStyle(
                            fontFamily: 'Fredoka',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AylaColors.textPrimary,
                          )),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text('DirectoryFilters 宽屏侧栏（点击/↑↓ 切换 · 当前 $_wideValue）',
                  style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
        // ---------- DirectoryFilters 窄屏顶栏（可交互） ----------
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaDirectoryFilters(
                label: '搜索结果分类（窄屏顶栏）',
                options: opts,
                value: _narrowValue, // 可交互：点击 / ←→ 切换
                narrow: true,
                onChange: (String v) => setState(() => _narrowValue = v),
              ),
              const SizedBox(height: 8),
              Text(
                'DirectoryFilters 窄屏顶栏（无圆角·只下边框·点击/←→ 切换 · 当前 $_narrowValue）',
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 6),
              Container(
                height: 90,
                alignment: Alignment.center,
                child: const Text('内容区', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 340,
          height: 330,
          child: Stack(
            children: <Widget>[
              AylaUserProfileCard(
                nickname: '小樱',
                signature: '今天也要开开心心的',
                online: true,
                displayStatus: '在线',
              ),
              const Positioned(
                left: 0,
                bottom: 0,
                child: Text('UserProfileCard', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 340,
          height: 330,
          child: Stack(
            children: <Widget>[
              PrivacySheet(onClose: () {}, boundEmail: 'ayla@example.com'),
              const Positioned(
                left: 0,
                bottom: 0,
                child: Text('PrivacySheet（menu）', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
