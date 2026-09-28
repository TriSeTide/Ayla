/// 个人主页资料卡族（web `pages/ProfilePage.tsx:154–180` / `UserProfilePage.tsx` +
/// `app.css 241–248 / 2657–2695` + `profile.css 14–16 / 44–52 / 142–171 / 584–591 / 623–625`）。
///
/// ## 事实源
/// ```
/// app.css 241–248  .solid-card：**--glass-bg + --glass-filter + --glass-shadow + 1px --glass-border +
///                  radius-card 16**（注意：名字叫 solid，实际是**玻璃卡** ⇒ 复用 AylaGlassCard）
/// app.css 2657–2662 .profile-card { padding: sp8; column; gap: sp6 }
/// profile.css 48   （≥769 且处于 .profile-page-split 内）.profile-card { padding: sp4; gap: sp4 } ⇒ [compact]
/// app.css 2664–2668 .profile-identity { flex · align-items center · gap: sp4 }
/// profile.css 51   （≥769）.profile-identity { flex-wrap: wrap }
/// profile.css 14–16 .profile-card-back { flex: none }（返回键在卡内、与头像昵称同一行）
/// app.css 2670–2689 .profile-names { column · gap sp1 · min-width 0 }
///                  .profile-nickname { Display 28 / 600 / letter-spacing −0.3 }
///                  .profile-username { Utility 13 / letter-spacing 0.3 / --text-secondary }（文案带 `@` 前缀）
/// profile.css 623  .profile-share-right { margin-left: auto }（分享键置右）
/// profile.css 142  .profile-avatar-block { column · align-items center · gap sp2 }
/// profile.css 150  .profile-avatar-btn { flex 1 1 0 · 12px · padding sp1 sp2 · min-height 28 · nowrap }
/// profile.css 163  .profile-avatar-hint { 12 / --text-secondary } · 168 .profile-avatar-error { 12 / --destructive }
/// ProfilePage.tsx 178–209  头像操作区**三个动作**的真实文案：`更换头像`（file label）· `隐私设置`（button）·
///                  `我的收藏`（Link，**带 IconHeart 15 前置图标**，走 `.profile-favorites-btn` 同盒模型）；
///                  hint 文案 = **「新头像将在保存后生效」**，**仅当 `avatarPreview` 存在（已选新图）时才渲染**；
///                  error 行带 **`role="alert"`**
/// profile.css 584  .profile-avatar-actions { flex · wrap · align-items center · gap sp1 ·
///                  **padding-left: calc(40px + sp4)**（与头像左缘对齐：返回键 40 + identity 间距 16）
/// ```
///
/// ## 机制差异（登记）
/// ① `.profile-identity` 在 ≥769 是 `flex-wrap: wrap`，而 `.profile-share-right` 用 `margin-left: auto`
///    **把分享键推右** —— Flutter 的 `Wrap` 没有 auto-margin 语义 ⇒ 本件用 `Row` + `Spacer`
///    （昵称/用户名可省略号收缩，不会溢出）；需要换行的窄档由调用方自行拆行。
/// ② `.profile-avatar-actions` 同为 `flex-wrap`；本件按 **一行等宽**（`Expanded` 等价 `flex: 1 1 0`）实现
///    —— 三个按钮已按 web 收窄（12px / padding sp1 sp2 / min-h 28），实测一行放得下。
///
/// ## 公开面
/// `AylaProfileCard` · `AylaProfileSidebarHeight` · `AylaProfileIdentity` · `AylaProfileAvatarActions`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';

/// 资料卡容器（`.solid-card .profile-card`）：玻璃卡 + 内距/间距两档 + 侧栏铺满档。
class AylaProfileCard extends StatelessWidget {
  const AylaProfileCard({
    super.key,
    required this.children,
    this.compact = false,
    this.gap,
    this.fillHeight = false,
  });

  /// 卡内区块（identity / avatar-actions / 表单 / 签名…由调用方装配）。
  final List<Widget> children;

  /// ≥769 且处于双栏布局时的紧凑档（`padding: sp4; gap: sp4`）。
  final bool compact;

  /// 卡内区块间距；null = 按 [compact] 推导（sp4 / sp6）。
  ///
  /// 侧栏模式要传 **sp6**（`profile.css:115–119`：
  /// `.profile-page-split:has(.profile-main) .profile-side .profile-card { gap: var(--sp-6) }`）
  /// —— 它与内距（`padding: sp4`）是**两个独立维度**：侧栏档是「sp4 内距 + sp6 间距」，
  /// 既有的 `compact`（sp4 + sp4）表达不了 ⇒ 单列一个覆盖参数（纯增量，默认 null
  /// 时既有调用点逐像素不变）。
  final double? gap;

  /// 铺满父级给的高度，并把多余空间**分配到区块之间**（间隙自适应）。
  ///
  /// 表达 web 侧栏档的三条规则之和（`profile.css:114–127`）：
  /// `.profile-card { flex: 1 0 auto }` + `.profile-form { flex: 1 }` +
  /// `.profile-actions { margin-top: auto }` ⇒ 卡片被撑到侧栏高、留白落在表单与操作区之间。
  ///
  /// 实现：`Column(mainAxisSize: min, mainAxisAlignment: spaceBetween)` ——
  /// **实测**（`ConstrainedBox(minHeight: X)` 内）会得到 `height = max(内容高, X)`，
  /// 并把 `max(内容高, X) − 内容高` 平均分配到子项之间；内容本身比 X 高时退化为普通排列。
  /// ⇒ 调用方只需用 `ConstrainedBox(minHeight: …)` 给出下限（见
  /// `pages/profile_support.dart` 的 `aylaProfileSidebarScroll`）。
  ///
  /// ⚠️ 想让留白**只**落在表单与操作区之间（与 web 逐条一致）时，调用方把
  /// 「上半区（identity + avatar-actions + form）」包成一个子项、操作区作第二个子项 ——
  /// 见 `ProfilePage` / `UserProfilePage` 的侧栏装配。
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = EdgeInsets.all(
      compact ? AylaSpacing.sp4 : AylaSpacing.sp8,
    );
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          fillHeight ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
      spacing: gap ?? (compact ? AylaSpacing.sp4 : AylaSpacing.sp6),
      children: children,
    );

    if (fillHeight) {
      // ⚠️ 为什么不能只靠父级的 `ConstrainedBox(minHeight: …)`：
      // [AylaGlassCard] 的卡面是 `DecoratedBox > Stack`，而 `Stack` 默认
      // `StackFit.loose` ⇒ 非定位子项拿到的是**放松后**的约束（minHeight 被丢掉）
      // ⇒ 本 Column 的 `space-between` 无从分配剩余空间。
      // 实测（2026-09-28）：外层 `ConstrainedBox(minHeight: 976)` 时卡片确为 976 高，
      // 但本 Column 仍是 525 的内容高。
      // ⇒ 由侧栏把可用高度经 [AylaProfileSidebarHeight] 显式注入（页面层
      // `aylaProfileSidebarScroll` 提供；无注入时退化为普通排列，不抛错）。
      final double? available = AylaProfileSidebarHeight.maybeOf(context);
      if (available != null) {
        final double inner =
            (available - padding.vertical).clamp(0.0, double.infinity);
        content = ConstrainedBox(
          constraints: BoxConstraints(minHeight: inner),
          child: content,
        );
      }
    }

    return AylaGlassCard(padding: padding, child: content);
  }
}

/// 侧栏可用高度注入（[AylaProfileCard.fillHeight] 的搭档）。
///
/// 页面层的 `aylaProfileSidebarScroll` 用它把「侧栏可视高度」传给卡片：
/// 卡片的父级 `AylaGlassSurface` 内部有 `Stack`（`StackFit.loose`）⇒ 约束被放松，
/// 卡片拿不到 `minHeight` 也拿不到有界的 `maxHeight`（在滚动视图内为 ∞）
/// ⇒ 只能由外部显式注入。
class AylaProfileSidebarHeight extends InheritedWidget {
  const AylaProfileSidebarHeight({
    super.key,
    required this.available,
    required super.child,
  });

  /// 侧栏可视高度（已扣除底部呼吸 margin）。
  final double available;

  /// 读当前注入值（无注入 → null）。
  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AylaProfileSidebarHeight>()
      ?.available;

  @override
  bool updateShouldNotify(AylaProfileSidebarHeight oldWidget) =>
      oldWidget.available != available;
}

/// 身份行：返回键 + 头像块 + 昵称/用户名 + 右侧分享槽位。
class AylaProfileIdentity extends StatelessWidget {
  /// 可见文案（web 原文「分享我的主页」；**开放给调用方**，默认值 = web 文案）。
  final String actionLabel;
  const AylaProfileIdentity({
    super.key,
    this.actionLabel = '分享我的主页',
    required this.displayName,
    required this.username,
    this.avatarUrl,
    this.avatarOverride,
    this.online = false,
    this.onBack,
    this.share,
    this.avatarSize = 64,
  });

  /// 展示名（昵称）。
  final String displayName;

  /// 用户名（渲染为 `@username`，web 同）。
  final String username;

  /// 头像地址。
  final String? avatarUrl;

  /// 在线状态。
  final bool online;

  /// 返回键（`.icon-btn-40 profile-card-back`；null ⇒ 不渲染）。
  final VoidCallback? onBack;

  /// 右侧分享槽位（`.profile-card-share.profile-share-right`，`margin-left: auto`）；
  /// 通常传 `AylaShareButton(size: 40, label: actionLabel)`。
  final Widget? share;

  /// 头像**即时预览**（`ImageProvider`，如 `MemoryImage(本地字节)`）。
  ///
  /// 事实源：`ProfilePage.tsx:168` 的 `imageUrl={avatarPreview ?? (currentUser.avatar || null)}`
  /// —— web 用 `URL.createObjectURL(file)` 的 objectURL 覆盖真实头像；Flutter 侧没有 objectURL，
  /// 由调用方交一个本地 `ImageProvider`（通常是 `MemoryImage(bytes)`）。
  ///
  /// null（默认）⇒ 行为与加该参数之前**逐像素一致**（走 [avatarUrl]）。
  final ImageProvider? avatarOverride;

  /// 头像直径（web `size={64}`）。
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Row(
      children: <Widget>[
        if (onBack != null) ...<Widget>[
          AylaIconButton(
            icon: AylaIcon(aylaIconByName('iconBack')!, size: 20),
            semanticLabel: '返回',
            onPressed: onBack,
          ),
          const SizedBox(width: AylaSpacing.sp4), // gap: var(--sp-4)
        ],
        // `.profile-avatar-block`（column · center · gap sp2）：本行只放头像
        AylaAvatarHalo(
          label: displayName,
          size: avatarSize,
          online: online,
          resourceUrl: avatarUrl,
          // 本地待上传头像优先于真实 URL（web `avatarPreview ?? currentUser.avatar`）
          previewImage: avatarOverride,
        ),
        const SizedBox(width: AylaSpacing.sp4), // gap: var(--sp-4)
        Expanded(
          // `.profile-names`：column · gap sp1 · min-width 0（Flutter：可收缩 + 省略号）
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.pageTitle.copyWith(
                  fontSize: 28, // Display 28 / 600
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: AylaSpacing.sp1), // gap: var(--sp-1)
              Text(
                '@$username',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.timestamp.copyWith(
                  fontSize: 13, // Utility 13 / ls .3
                  letterSpacing: 0.3,
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        if (share != null) ...<Widget>[
          const SizedBox(width: AylaSpacing.sp3),
          share!, // `.profile-share-right { margin-left: auto }`（Row 里由 Expanded 承担推右）
        ],
      ],
    );
  }
}

/// 头像操作行：等宽按钮 + 提示/错误行（`.profile-avatar-actions`）。
class AylaProfileAvatarActions extends StatelessWidget {
  const AylaProfileAvatarActions({
    super.key,
    required this.actions,
    this.hint,
    this.error,
  });

  /// 按钮（**按内容宽排列 + 可折行**，见 [build] 的说明）。
  ///
  /// 库内范本 = `AylaGlassButton(variant: ghost, fontSize: 12, minHeight: 28)`。
  ///
  /// ⚠️ **不要再传 `expand: true`**（2026-09-28 用户实报「三个按钮文字不全」后订正）：
  /// web `.profile-avatar-actions` 是 `display:flex; flex-wrap:wrap; gap: var(--sp-1)`
  /// （`profile.css:584–591`）⇒ 按钮**按内容宽**排在一条可折行的流里；此前本件用
  /// `Expanded` 给「等宽槽位」，在 280–340 宽的侧栏里把每个按钮压到 1/3 ⇒ 文案被省略成
  /// 「更…」「隐…」（截图实测）。
  final List<Widget> actions;

  /// 预览提示（`.profile-avatar-hint`：12 / secondary）。**web 原文 = 「新头像将在保存后生效」**，
  /// 且 web 只在**已选新头像**时渲染 ⇒ 由调用方按该条件决定是否传（不要当格式/大小说明用）。
  final String? hint;

  /// 校验错误（`.profile-avatar-error`：12 / destructive）。
  final String? error;

  /// 左内距 = `calc(40px + sp4)`（与头像左缘对齐）。
  static const double indent = 40 + AylaSpacing.sp4;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? hintText = hint;
    final String? errorText = error;
    return Padding(
      padding: const EdgeInsets.only(left: indent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp1,
        children: <Widget>[
          if (actions.isNotEmpty)
            // web `.profile-avatar-actions { display: flex; flex-wrap: wrap; align-items: center;
            // gap: var(--sp-1) }`（`profile.css:584–591`）⇒ **内容宽 + 可折行**，不是等宽槽位。
            // Flutter 的等价物是 `Wrap`（`Row` + `Expanded` 会按 flex 分配把文字压到省略号）。
            Wrap(
              spacing: AylaSpacing.sp1, // gap: var(--sp-1)（4px，web 的收窄值）
              runSpacing: AylaSpacing.sp1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          if (hintText != null)
            Text(
              hintText,
              style: t.timestamp.copyWith(
                fontSize: 12,
                color: AylaColors.textSecondary,
              ),
            ),
          if (errorText != null)
            // web：`<span className="profile-avatar-error" role="alert">`
            Semantics(
              liveRegion: true,
              child: Text(
                errorText,
                style: t.timestamp.copyWith(
                  fontSize: 12,
                  color: AylaColors.destructive,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
