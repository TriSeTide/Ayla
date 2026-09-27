/// 搜索结果的用户行（web `pages/SearchPage.tsx:391–408` + `styles/search.css` 107–176）。
///
/// ## 事实源
/// ```
/// search.css 107–119  .search-row：flex · align-items center · gap sp3 · padding sp2 sp3 ·
///                     radius-input 12 · background --glass-bg · 1px --glass-border ·
///                     backdrop-filter --glass-filter（blur 24 + saturate 1.4）
/// search.css 121–129  .search-row-title：14 / 600 / --text-primary / 单行省略
/// search.css 131–137  .search-row-copy：column · gap sp1 · flex 1 · min-width 0
/// search.css 140–149  .search-row-main：**透明按钮**（无底无边）· align-self stretch ·
///                     align-items flex-start · justify-content center · padding 0 · radius-sm
/// search.css 172–176  .search-row-action：margin-left auto · flex none · --grape-700 · 13px
///                     （**用户行未用**，留 [trailing] 槽位供其它结果行复用）
/// tsx 391–408         结构：Avatar(36 / online / 头像点击=去个人主页 / aria-label「查看 {名} 的个人主页」)
///                     + 按钮（标题 = 昵称‖用户名；副行 = signature，**有才渲染**；点击 = 开资料浮层）
/// ```
/// ## 登记（两处，勿当遗漏）
/// - `.search-row-sub` **在任何 CSS 里都没有定义** ⇒ 照实渲染（继承父级字号/颜色），不自行发明样式；
/// - auroraqua 539–545 的 `.search-row { background: var(--surface) }` 位于
///   `@supports not (backdrop-filter…)` 兜底块内 ⇒ **Flutter 恒有模糊，该兜底不适用**（保持玻璃材质）。
///
/// ## 公开面
/// `AylaSearchUserRow`
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';

/// 搜索结果的用户行：头像（可点）+ 昵称/签名（可点开资料）+ 可选尾部槽位。
class AylaSearchUserRow extends StatelessWidget {
  const AylaSearchUserRow({
    super.key,
    required this.nickname,
    required this.username,
    this.signature,
    this.avatarUrl,
    this.online = false,
    this.onOpenProfile,
    this.onTap,
    this.trailing,
  });

  /// 昵称（空 ⇒ 回退用户名，web `nickname || username`）。
  final String nickname;

  /// 用户名（昵称缺失时的回退）。
  final String username;

  /// 签名（**null / 空 ⇒ 不渲染副行**）。
  final String? signature;

  /// 头像资源地址。
  final String? avatarUrl;

  /// 在线状态（web `presenceOnline(...)`）。
  final bool online;

  /// 点头像：去 TA 的个人主页（web `goUserProfile`）。
  final VoidCallback? onOpenProfile;

  /// 点正文：开资料浮层（web `setSelectedUser`）。
  final VoidCallback? onTap;

  /// 尾部槽位（`.search-row-action`：`margin-left auto` / `--grape-700` / 13px）—— 群行等复用。
  final Widget? trailing;

  /// 显示名（`nickname || username`）。
  String get displayName => nickname.isEmpty ? username : nickname;

  /// 头像直径（web `size={36}`）。
  static const double avatarSize = 36;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? sub = signature;
    return AylaGlassSurface(
      radiusOverride: BorderRadius.circular(AylaRadii.rInput), // border-radius: var(--radius-input)
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      child: Row(
        children: <Widget>[
          AylaAvatarHalo(
            label: displayName,
            size: avatarSize,
            online: online,
            resourceUrl: avatarUrl,
            onTap: onOpenProfile,
            semanticLabel: '查看 $displayName 的个人主页',
          ),
          const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
          Expanded(
            // `.search-row-copy`（column · gap sp1 · flex 1 · min-width 0）+
            // `.search-row-main`（透明按钮：无底/无边、内容左对齐且纵向居中）
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyStrong.copyWith(
                      fontSize: 14,
                      color: AylaColors.textPrimary,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AylaSpacing.sp1), // gap: var(--sp-1)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.body, // `.search-row-sub` 无定义 ⇒ 照实继承
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp2),
            trailing!,
          ],
        ],
      ),
    );
  }
}
