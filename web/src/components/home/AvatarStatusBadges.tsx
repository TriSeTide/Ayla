/**
 * AvatarStatusBadges —— 群头像状态角标（列表布局 + 宽屏侧栏，需求 R-H5 扩展）。
 *
 * 在头像右上角 / 右边 / 右下角竖向一列显示直播 / 语音 / 桌游小标签：
 * - 1 个 → 右下角；2 个 → 右下 + 右；3 个 → 右上 + 右 + 右下（从下往上填）；
 * - 桌游由 SHOW_GAME_STATUS 开关强制关闭（判断未实现，见 badges.ts）。
 * 纯展示（pointer-events:none），不拦截头像的点击跳转。
 */
import { badgeIcon, resolveAvatarBadges } from "./badges";

export function AvatarStatusBadges({
  status,
}: {
  status: { live?: boolean; voice?: boolean; game?: boolean };
}) {
  const badges = resolveAvatarBadges(status);
  if (badges.length === 0) return null;

  return (
    <>
      {badges.map((b) => {
        const Icon = badgeIcon(b.kind);
        if (!Icon) return null;
        return (
          <span
            key={b.kind}
            className={`avatar-status-badge avatar-status-${b.position} group-badge-${b.kind}`}
            aria-label={b.ariaLabel}
          >
            <Icon width={10} height={10} />
          </span>
        );
      })}
    </>
  );
}
