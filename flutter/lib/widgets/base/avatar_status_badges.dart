/// 群头像状态角标（`.avatar-status-badge` / `.group-badge-*`）。
///
/// **1:1 对照**（`home.css` 560–588 + `components/home/badges.ts` +
/// `AvatarStatusBadges.tsx`）：
///
/// ```
/// .avatar-status-badge { position:absolute; inline-flex; center;
///   width:16px; height:16px; border-radius:pill;
///   pointer-events:none;  /* 纯展示，不拦截头像点击 */
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/base/avatar_status_badges.dart` 一节）
/// ```
///
/// **槽位填充顺序**（`badges.ts` 109–114）：竖向一列、**从下往上填**
///   `bottom-right → middle-right → top-right`
/// 即 1 个 → 右下；2 个 → 右下 + 右；3 个 → 右下 + 右 + 右上。
///
/// **优先级**（`badges.ts` 133–135）：`live > voice > game`。
///
/// **桌游开关**：`SHOW_GAME_STATUS = false`（`badges.ts` 97；“是否有人在玩”
/// 判断未实现，先强制关闭显示；**保留完整实现，实现后置 true 即恢复**）。
///
/// ## 公开面
/// `AylaAvatarBadgeKind` · `AylaAvatarBadgePosition` · `AylaAvatarStatus` · `AylaAvatarStatusBadge` · `AylaAvatarStatusBadges`

library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';

/// 角标种类（`.group-badge-*`）。
enum AylaAvatarBadgeKind {
  /// 直播：`--glow-500` 底 + 白字（`IconVideo`）。
  live,

  /// 语音：`--ice-500` 底 + `--indigo-700` 字（`IconMic`）。
  voice,

  /// 桌游：`--sakura-300` 底 + `--grape-700` 字（`IconGame`）。
  game,
}

/// 头像角标槽位（`badges.ts` 100）。
enum AylaAvatarBadgePosition {
  /// 右下角（`right:-3px; bottom:-3px`）——第一个角标。
  bottomRight,

  /// 右边中点（`right:-3px; top:50%; translateY(-50%)`）——第二个。
  middleRight,

  /// 右上角（`right:-3px; top:-3px`）——第三个。
  topRight,
}

/// 群状态输入（`GroupStatus`；缺省视为无该状态）。
///
/// 注意 web 的 `GroupStatus` 含 **4 个字段**（badges.ts 18–23）：`unread` /
/// `live` / `voice` / `game`。其中 `unread` **不走头像角标**（角标只认
/// live/voice/game，见 [resolveAvatarBadges]）——它是**列表项自己的未读徽标**
/// 数据源（`GroupListItem.tsx` 57–61 用 `status.unread`）。此处保留该字段，
/// 供 [AylaGroupListItem] 读取，避免两处各传一遍。
class AylaAvatarStatus {
  const AylaAvatarStatus({
    this.unread,
    this.live = false,
    this.voice = false,
    this.game = false,
  });

  /// 未读数（>0 时列表项显示数字徽标；**不参与头像角标**）。
  final int? unread;

  /// 群内有直播。
  final bool live;

  /// 群内有语音房。
  final bool voice;

  /// 群内有桌游。
  final bool game;
}

/// 已解析的角标（种类 + 槽位）。
class AylaAvatarStatusBadge {
  const AylaAvatarStatusBadge({required this.kind, required this.position});

  /// 角标种类。
  final AylaAvatarBadgeKind kind;

  /// 所在槽位。
  final AylaAvatarBadgePosition position;
}

/// 桌游状态角标开关（`badges.ts` 97 `SHOW_GAME_STATUS`）。
///
/// “桌游房是否有人在玩”的判断尚未实现，先强制关闭显示。
/// **保留完整实现，实现后置 true 即恢复，勿删除桌游分支。**
const bool kShowGameStatus = false;

/// 从下往上填的槽位顺序（`badges.ts` 110–114 `AVATAR_POSITIONS`）。
const List<AylaAvatarBadgePosition> kAvatarBadgePositions = <AylaAvatarBadgePosition>[
  AylaAvatarBadgePosition.bottomRight,
  AylaAvatarBadgePosition.middleRight,
  AylaAvatarBadgePosition.topRight,
];

/// 解析头像状态角标（`resolveAvatarBadges`，badges.ts 127–141）。
///
/// 优先级 `live > voice > game`；位置按 [kAvatarBadgePositions] 从下往上填。
/// 桌游受 [kShowGameStatus] 开关控制。
List<AylaAvatarStatusBadge> resolveAvatarBadges(AylaAvatarStatus status) {
  final List<AylaAvatarBadgeKind> kinds = <AylaAvatarBadgeKind>[];
  if (status.live) kinds.add(AylaAvatarBadgeKind.live);
  if (status.voice) kinds.add(AylaAvatarBadgeKind.voice);
  if (kShowGameStatus && status.game) kinds.add(AylaAvatarBadgeKind.game);
  return <AylaAvatarStatusBadge>[
    for (int i = 0; i < kinds.length && i < kAvatarBadgePositions.length; i++)
      AylaAvatarStatusBadge(kind: kinds[i], position: kAvatarBadgePositions[i]),
  ];
}

/// 角标无障碍描述（`BADGE_ARIA`，badges.ts 116–120）。
String avatarBadgeAria(AylaAvatarBadgeKind kind) {
  switch (kind) {
    case AylaAvatarBadgeKind.live:
      return '群内有直播';
    case AylaAvatarBadgeKind.voice:
      return '群内有语音房';
    case AylaAvatarBadgeKind.game:
      return '群内有桌游';
  }
}

/// 角标图标（`badgeIcon`，badges.ts 47–58；**10×10** —— 见 `AvatarStatusBadges.tsx`
/// 30 行 `<Icon width={10} height={10} />`）。
AylaIconData avatarBadgeIcon(AylaAvatarBadgeKind kind) {
  switch (kind) {
    case AylaAvatarBadgeKind.live:
      return aylaIconByName('iconVideo')!;
    case AylaAvatarBadgeKind.voice:
      return aylaIconByName('iconMic')!;
    case AylaAvatarBadgeKind.game:
      return aylaIconByName('iconGame')!;
  }
}

/// 角标底色（`.group-badge-*`，home.css 320–333）。
({Color bg, Color fg}) avatarBadgeColors(AylaAvatarBadgeKind kind) {
  switch (kind) {
    case AylaAvatarBadgeKind.live:
      return (bg: AylaColors.glow500, fg: AylaColors.surface); // #fffafb
    case AylaAvatarBadgeKind.voice:
      return (bg: AylaColors.ice500, fg: AylaColors.indigo700);
    case AylaAvatarBadgeKind.game:
      return (bg: AylaColors.sakura300, fg: AylaColors.grape700);
  }
}

/// 群头像状态角标组（`AvatarStatusBadges.tsx`）。
///
/// 用法：放在头像的 `Stack` 中（外层需 `clipBehavior: Clip.none`，因为角标
/// 通过 `-3px` 越出头像边缘）。
class AylaAvatarStatusBadges extends StatelessWidget {
  const AylaAvatarStatusBadges({super.key, required this.status});

  /// 群状态。
  final AylaAvatarStatus status;

  @override
  Widget build(BuildContext context) {
    final List<AylaAvatarStatusBadge> badges = resolveAvatarBadges(status);
    if (badges.isEmpty) return const SizedBox.shrink(); // badges.ts:16 `return null`

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        for (final AylaAvatarStatusBadge b in badges)
          _positioned(b),
      ],
    );
  }

  Widget _positioned(AylaAvatarStatusBadge b) {
    final ({Color bg, Color fg}) c = avatarBadgeColors(b.kind);
    final Widget dot = Semantics(
      label: avatarBadgeAria(b.kind),
      child: Container(
        width: 16, // width: 16px
        height: 16, // height: 16px
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: AylaRadii.pill, // border-radius: var(--radius-pill)
        ),
        child: AylaIcon(
          avatarBadgeIcon(b.kind),
          size: 10, // AvatarStatusBadges.tsx:30 `<Icon width={10} height={10}/>`
          color: c.fg,
        ),
      ),
    );
    // pointer-events:none（纯展示，不拦截头像点击）→ IgnorePointer
    final Widget ignored = IgnorePointer(child: dot);

    // 三档定位（home.css 574–588）。注意 web 是**相对头像**的 absolute：
    // 故这里也返回 Positioned，由调用方放进头像 Stack。
    switch (b.position) {
      case AylaAvatarBadgePosition.bottomRight:
        // `.avatar-status-bottom-right { right:-3px; bottom:-3px }`
        return Positioned(right: -3, bottom: -3, child: ignored);
      case AylaAvatarBadgePosition.middleRight:
        // `.avatar-status-middle-right { right:-3px; top:50%;
        //   transform: translateY(-50%) }` → 垂直居中于头像
        return Positioned.fill(
          right: -3,
          child: Align(alignment: Alignment.centerRight, child: ignored),
        );
      case AylaAvatarBadgePosition.topRight:
        // `.avatar-status-top-right { right:-3px; top:-3px }`
        return Positioned(right: -3, top: -3, child: ignored);
    }
  }
}
