/**
 * LiveHostAvatar —— 直播间主播头像（F4 增强）。
 *
 * 直播间头部展示主播头像（点击进主播个人主页）；
 * 头像资料用 ensureUser 懒拉（缓存于 api/users，昵称/头像/状态）；
 * 无资料时回退首字符光环（owner_nickname）。
 */
import { useEffect, useState } from "react";
import type { UserPublic } from "../../api/types";
import { ensureUser, getCachedUser } from "../../api/users";
import { Avatar } from "../Avatar";
import { usePresenceOnline } from "../../utils/displayStatus";
import { goUserProfile } from "../../utils/navigation";

export function LiveHostAvatar({
  ownerId,
  ownerNickname,
  size = 36,
}: {
  ownerId: string;
  ownerNickname: string | null;
  size?: number;
}) {
  const [host, setHost] = useState<UserPublic | null>(() =>
    ownerId ? getCachedUser(ownerId) : null,
  );

  useEffect(() => {
    if (!ownerId || host) return;
    let cancelled = false;
    void ensureUser(ownerId).then((u) => {
      if (!cancelled && u) setHost(u);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ownerId]);

  const label = host?.nickname || host?.username || ownerNickname || "主播";
  const hostOnline = usePresenceOnline(host);

  return (
    <Avatar
      label={label}
      size={size}
      online={hostOnline}
      imageUrl={host?.avatar || null}
      onClick={() => ownerId && goUserProfile(null, ownerId)}
      ariaLabel={`查看主播 ${label} 的个人主页`}
    />
  );
}