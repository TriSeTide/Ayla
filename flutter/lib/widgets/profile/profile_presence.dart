/// 在线胶囊（`.profile-presence`）—— 他人主页身份行的状态标签。
///
/// ## 事实源
/// `web/src/styles/profile.css:558–570`：
/// ```
/// .profile-presence {
///   align-self: flex-start;
///   padding: 2px var(--sp-3);
///   border-radius: var(--radius-pill);
///   font-size: 12px;
///   font-weight: 600;
///   background: var(--ice-100);
///   color: var(--text-secondary);
/// }
/// .profile-presence.is-online { background: var(--sakura-300); color: var(--grape-700); }
/// ```
/// 调用点：`UserProfilePage.tsx:142–144`（唯一）；文案 = `useDisplayStatus(user)`，
/// Flutter 侧由调用方注入（后端 `display_status` 兜底），**本件不造默认文案**。
///
/// ## 来历
/// 2026-09-28 用户裁决，把 `user_profile_page.dart` 里的私有 `_PresenceChip` 提为公共件
/// （19 号 §7.5 第三批缺口清单里的 `AylaProfilePresence`）。
///
/// ## 公开面
/// `AylaProfilePresence` · 样张 `aylaProfilePresenceSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class AylaProfilePresence extends StatelessWidget {
  const AylaProfilePresence({
    super.key,
    required this.label,
    this.online = false,
  });

  /// 文案（web 由 `useDisplayStatus` 给：在线 / 离开 / 勿扰 / 离线）。
  final String label;

  /// 在线档（`.is-online`）：底 `--sakura-300` + 字 `--grape-700`；
  /// false ⇒ 底 `--ice-100` + 字 `--text-secondary`。
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3, // padding: 2px var(--sp-3)
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: online ? AylaColors.sakura300 : AylaColors.ice100,
        borderRadius: AylaRadii.pill, // --radius-pill
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ).copyWith(
          color: online ? AylaColors.grape700 : AylaColors.textSecondary,
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// 画布样张：在线 / 离线两档（`.is-online` 的底/字色对照）。
Widget aylaProfilePresenceSamples() {
  return Wrap(
    spacing: AylaSpacing.sp4,
    runSpacing: AylaSpacing.sp3,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: const <Widget>[
      AylaProfilePresence(label: '在线', online: true),
      AylaProfilePresence(label: '离开'),
      AylaProfilePresence(label: '勿扰'),
      AylaProfilePresence(label: '离线'),
    ],
  );
}