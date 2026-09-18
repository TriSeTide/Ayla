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
import '../widgets/loading.dart';
import '../widgets/primitives.dart';
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
            source: '.btn：gap 8 · min-h 40 · padding 0 24 · radius 12 · 14px/700/ls .2 · 200ms',
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
            source: '.glass-bg .55 · blur 24 saturate 1.4 · 1px 白边 .65 · 16px 圆角 · 8/32 阴影 · 顶沿内高光',
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
            source: 'padding 12×16 · radius 12 · --glass-bg + 亮边 · focus 辉光边 · placeholder slate-500',
            child: SizedBox(
              width: 374,
              child: _Rows(
                children: <Widget>[
                  _InputSample(label: '常态（认证卡内：indigo .3 描边）', onGlassBorder: true),
                  _InputSample(
                    label: 'focus（#F796FF 边 + 辉光）',
                    autofocus: true,
                    onGlassBorder: true,
                  ),
                  _InputSample(label: '密码类型', obscure: true, text: '12345678', onGlassBorder: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- AvatarHalo ----------
          _Section(
            title: 'AvatarHalo（app.css .avatar-halo 312–380 / base.css halo-breathe）',
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

          // ---------- TabBadge ----------
          _Section(
            title: 'TabBadge（shell.css .tab-badge 579–593）',
            source: 'min-w 16 · h 16 · padding 0 4 · pink-500 底 · Fredoka 11 · top -4 / right -12 · >99 → 99+',
            child: _Row(
              children: <Widget>[
                _Slot(label: '1', child: _BadgeHost(count: 1)),
                _Slot(label: '12', child: _BadgeHost(count: 12)),
                _Slot(label: '150 → 99+', child: _BadgeHost(count: 150)),
              ],
            ),
          ),
          const SizedBox(height: AylaSpacing.sp8),

          // ---------- 加载族 ----------
          _Section(
            title: 'Skeleton + Spinner + FullScreenLoader（base.css 515–574）',
            source: 'spinner 18px/800ms · skeleton radius 8 + frost-pulse .55↔.9 1600ms · loader 品牌 40px 渐变字',
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
            title: 'Batch 2 基元（LayoutSwitch / SegmentedTab / CapsuleTag / ScrollingText）',
            source: 'home.css .layout-switch 182–206 · messages.css .messages-tab 24–37 · '
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

          // ---------- 排版阶梯 ----------
          _Section(
            title: 'Typography（design.md §3 九级）',
            source: 'Display=Fredoka / Body=Nunito / Utility=Space Grotesk，CJK 回退链',
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
            style: AylaTextStyles.light.timestamp
                .copyWith(color: AylaColors.textSecondary),
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
