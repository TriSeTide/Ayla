/**
 * VoiceMemberRow —— 单个语音成员（M5-3 §2 / §4.6）。
 *
 * - 昵称/头像来自用户资料懒拉缓存（api/users ensureUser），未命中回退首字符；
 * - 静音标记：应用层 voice.state muted（媒体事实以 LiveKit 为准，两者语义见 §4.3）；
 * - 音量滑条：仅远端成员展示，本地播放偏好 0~100，不落库；
 * - 爱莉条目（isElysia）：状态只渲染中性技术标签（"通话中/输出中/接收中"），
 *   禁止主观化文案（主体性铁律 M5-3 硬约束）。
 */
import { useEffect, useState } from "react";
import type { UserPublic } from "../../api/types";
import { ensureUser, getCachedUser } from "../../api/users";
import type { VoiceMemberState } from "../../stores/voice";
import { Avatar } from "../Avatar";
import { IconMic } from "../icons";

export function VoiceMemberRow({
  member,
  isSelf,
  isElysia,
  elysiaLabel,
  onVolumeChange,
}: {
  member: VoiceMemberState;
  isSelf: boolean;
  /** 爱莉条目（profile.user.id 命中）；只影响渲染标签与光环 */
  isElysia: boolean;
  /** 爱莉中性技术标签（"通话中"/"输出中"/"接收中"/null）；非爱莉条目忽略 */
  elysiaLabel?: string | null;
  onVolumeChange: (userId: string, volume: number) => void;
}) {
  const [user, setUser] = useState<UserPublic | null>(() => getCachedUser(member.user_id));

  useEffect(() => {
    if (user) return;
    let cancelled = false;
    void ensureUser(member.user_id).then((u) => {
      if (!cancelled && u) setUser(u);
    });
    return () => {
      cancelled = true;
    };
  }, [member.user_id, user]);

  const displayName = user?.nickname || user?.username || member.user_id.slice(0, 6);

  return (
    <div className="voice-member-row">
      <Avatar
        label={displayName}
        size={32}
        online
        isElysia={isElysia}
        imageUrl={user?.avatar || null}
      />
      <div className="voice-member-main">
        <span className="voice-member-name">
          {displayName}
          {isSelf && <span className="voice-self-tag">我</span>}
        </span>
        <span className="voice-member-sub">
          {isElysia && elysiaLabel ? (
            <span className="voice-elysia-state">{elysiaLabel}</span>
          ) : member.muted ? (
            <span className="voice-muted-tag">
              <IconMic width={11} height={11} /> 已静音
            </span>
          ) : (
            "在频道中"
          )}
        </span>
      </div>
      {!isSelf && (
        <input
          type="range"
          className="voice-volume-slider"
          min={0}
          max={100}
          value={member.volume}
          aria-label={`${displayName} 的音量`}
          onChange={(e) => onVolumeChange(member.user_id, Number(e.target.value))}
        />
      )}
    </div>
  );
}
