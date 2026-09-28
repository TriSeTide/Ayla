/// 群角色标签（web `.group-info-role` —— `GroupInfo.tsx:52–56` 的 `ROLE_LABEL` +
/// `styles/group.css 1734–1750`）。
///
/// ## 事实源
/// ```
/// GroupInfo.tsx 52–56  ROLE_LABEL = { owner: 群主, admin: 管理员, member: 成员 }
/// group.css 1734–1740  .group-info-role：flex none · padding 1px 8px · radius pill · Display 11
///   ⚠️ 该块**只**声明 `font-family: var(--font-display)` + `font-size: 11px`；
///   font-weight / letter-spacing / line-height **均未声明** ⇒ 全部继承 body
///   （base.css 29–32：`font-weight` 未声明 = 400、`line-height: 1.55`、ls normal）。
///   2026-09-28 修正：此前用 `t.timestamp`（utility = Space Grotesk / 12 / ls .3 / lh 1.4），
///   字体族与字距都不对 —— 已按上表逐值改回 display + 11 + w400 + lh 1.55。
/// group.css 1742–1745  .group-info-role-owner：background --sakura-300 · color --grape-700
/// group.css 1747–1750  .group-info-role-admin：background --ice-300 · color --indigo-700
/// ```
/// ⚠️ `member` **不渲染标签**（web：只有 `role !== "member"` 才出 chip；成员行/转让弹窗两处同规则）。
///
/// ## 公开面
/// `AylaGroupRole` · `AylaGroupRoleChip` · `kAylaGroupRoleLabels`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 群成员角色（web `ConversationMember["role"]`）。
enum AylaGroupRole { owner, admin, member }

/// 角色文案（web `ROLE_LABEL`）。
const Map<AylaGroupRole, String> kAylaGroupRoleLabels = <AylaGroupRole, String>{
  AylaGroupRole.owner: '群主',
  AylaGroupRole.admin: '管理员',
  AylaGroupRole.member: '成员',
};

/// 角色标签：`member` ⇒ 不渲染（web 同）；owner / admin 各有自己的底+字色。
class AylaGroupRoleChip extends StatelessWidget {
  const AylaGroupRoleChip({super.key, required this.role, this.label});

  /// 角色。
  final AylaGroupRole role;

  /// 文案覆盖（默认取 [kAylaGroupRoleLabels]）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (role == AylaGroupRole.member) return const SizedBox.shrink();
    final bool isOwner = role == AylaGroupRole.owner;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        // owner: --sakura-300 / --grape-700；admin: --ice-300 / --indigo-700
        color: isOwner ? AylaColors.sakura300 : AylaColors.ice300,
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        label ?? kAylaGroupRoleLabels[role]!,
        // `font-family: var(--font-display)`（group.css 1738）= Fredoka，
        // 其余全部继承 body（base.css 29–32）：400 / lh 1.55 / ls normal。
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          height: 1.55,
          color: isOwner ? AylaColors.grape700 : AylaColors.indigo700,
        ),
      ),
    );
  }
}
