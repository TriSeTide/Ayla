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
/// `AylaProfileCard` · `AylaProfileIdentity` · `AylaProfileAvatarActions`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';

/// 资料卡容器（`.solid-card .profile-card`）：玻璃卡 + 内距/间距两档。
class AylaProfileCard extends StatelessWidget {
  const AylaProfileCard({super.key, required this.children, this.compact = false});

  /// 卡内区块（identity / avatar-actions / 表单 / 签名…由调用方装配）。
  final List<Widget> children;

  /// ≥769 且处于双栏布局时的紧凑档（`padding: sp4; gap: sp4`）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AylaGlassCard(
      padding: EdgeInsets.all(compact ? AylaSpacing.sp4 : AylaSpacing.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: compact ? AylaSpacing.sp4 : AylaSpacing.sp6,
        children: children,
      ),
    );
  }
}

/// 身份行：返回键 + 头像块 + 昵称/用户名 + 右侧分享槽位。
class AylaProfileIdentity extends StatelessWidget {
  const AylaProfileIdentity({
    super.key,
    required this.displayName,
    required this.username,
    this.avatarUrl,
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
  /// 通常传 `AylaShareButton(size: 40, label: '分享我的主页')`。
  final Widget? share;

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

  /// 按钮（每个占等宽一格；库内范本 = `AylaGlassButton(variant: ghost, fontSize: 12, minHeight: 28, **expand: true**)`）。
  ///
  /// ⚠️ **必须传 `expand: true`**：本件用 `Expanded` 给等宽**槽位**，而按钮内部视觉盒按内容宽度排
  /// ⇒ 不 expand 时文字/底色会偏向一侧（2026-09-25 用户实测「保存按钮左偏了」）。
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
            Row(
              spacing: AylaSpacing.sp1, // gap: var(--sp-1)
              children: <Widget>[
                for (final Widget action in actions) Expanded(child: action),
              ],
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
