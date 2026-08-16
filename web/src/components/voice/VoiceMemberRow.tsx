/**
 * VoiceMemberRow —— 单个语音成员（M5-3 §2 / §4.6）。
 *
 * - 昵称/头像来自用户资料懒拉缓存（api/users ensureUser），未命中回退首字符；
 * - 静音标记：应用层 voice.state muted（媒体事实以 LiveKit 为准，两者语义见 §4.3）；
 * - 行尾统一「操作区」（所有成员行同一水平线，上下等距）：
 *   1. 开关按钮——自己行 = 麦克风按钮（一键禁音/一键恢复，媒体层 toggleMic）；
 *      远端行 = 喇叭按钮（一键静音/一键恢复，本地播放 locallyMuted）；
 *   2. 覆盖式音量条 VoiceVolumeMeter（自己麦克风与远端播放同一样式）；
 * - 音量条三层结构（下→上）：底层轨道双色填充（滑块左边 indigo = 设定音量、右边
 *   浅色）→ 中层跳动条（`--glow-500 → --ice-500` 渐变，宽度随实时说话音量伸缩）→
 *   上层 slider（透明轨道 + indigo 圆把手）；
 *   - 自己条目：设定 = 本地麦克风音量（0~100），跳动随 localAudioLevel；
 *   - 远端条目：设定 = 本地播放音量（0~100），跳动随 member.audioLevel；
 * - 爱莉条目（isElysia）：状态只渲染中性技术标签（"通话中/输出中/接收中"），
 *   禁止主观化文案（主体性铁律 M5-3 硬约束）。
 */
import { useEffect, useState } from "react";
import type { CSSProperties } from "react";
import type { UserPublic } from "../../api/types";
import { ensureUser, getCachedUser } from "../../api/users";
import { useVoiceStore } from "../../stores/voice";
import type { VoiceMemberState } from "../../stores/voice";
import { Avatar } from "../Avatar";
import { IconMic, IconMicOff, IconSpeaker, IconSpeakerOff } from "../icons";

/**
 * VoiceVolumeMeter —— 覆盖式音量条（自己与远端成员共用）。
 *
 * 三层结构（下 → 上）：
 * 1. `.voice-meter-track`：底层轨道，双色填充（滑块左边 `--indigo-700` = 设定音量
 *    volume、右边浅色）——"滑块左边始终有颜色"；
 * 2. `.voice-meter-fill`：中层跳动条（`--glow-500 → --ice-500` 渐变），宽度 = 实时
 *    说话音量 level 0~1，**覆盖在轨道上方**左右伸缩跳动（静音 0）；
 * 3. slider：最上层，轨道透明（不遮跳动条）+ `--indigo-700` 圆把手可见。
 */
function VoiceVolumeMeter({
  volume,
  level,
  speaking,
  onVolumeChange,
  ariaLabel,
}: {
  /** 设定音量 0~100（滑块位置 + 轨道左边填充宽度） */
  volume: number;
  /** 实时说话音量 0~1（跳动条宽度） */
  level: number;
  /** 正在说话（跳动条辉光） */
  speaking: boolean;
  onVolumeChange: (volume: number) => void;
  ariaLabel: string;
}) {
  /** 说话音量显示映射指数：livekit 音量原始值偏小（人声常驻 0.1~0.3），
   *  直接线性映射跳动条只有 10%~30% 宽度。开 0.4 次方放大低音量敏感度：
   *  普通说话 ~40%~62%、大声 ~76%+、最大声 100%，才有"麦克风那么大"的跳动幅度。 */
  const DISPLAY_EXP = 0.4;
  const levelPct = Math.round(
    Math.min(1, Math.pow(Math.max(0, Math.min(1, level)), DISPLAY_EXP)) * 100,
  );
  const volumePct = Math.round(Math.max(0, Math.min(100, volume)));
  return (
    <span className={`voice-meter ${speaking ? "is-speaking" : ""}`}>
      {/* 底层轨道：双色填充（滑块左边 indigo = 设定音量，右边浅色） */}
      <span
        className="voice-meter-track"
        style={{ "--fill": `${volumePct}%` } as CSSProperties}
        aria-hidden="true"
      />
      {/* 中层跳动条：覆盖在轨道上方（另一种颜色，随实时说话音量左右伸缩） */}
      <span
        className="voice-meter-fill"
        style={{ width: `${levelPct}%` }}
        aria-hidden="true"
      />
      {/* 最上层 slider：透明轨道（不遮跳动条）+ 可见圆把手 */}
      <input
        type="range"
        className="voice-meter-slider"
        min={0}
        max={100}
        value={volume}
        aria-label={ariaLabel}
        onChange={(e) => onVolumeChange(Number(e.target.value))}
      />
    </span>
  );
}

export function VoiceMemberRow({
  member,
  isSelf,
  isElysia,
  elysiaLabel,
  onVolumeChange,
  onLocalVolumeChange,
  onToggleMic,
  onToggleMemberMuted,
}: {
  member: VoiceMemberState;
  isSelf: boolean;
  /** 爱莉条目（profile.user.id 命中）；只影响渲染标签与光环 */
  isElysia: boolean;
  /** 爱莉中性技术标签（"通话中"/"输出中"/"接收中"/null）；非爱莉条目忽略 */
  elysiaLabel?: string | null;
  onVolumeChange: (userId: string, volume: number) => void;
  /** 本地麦克风音量 0~100（自己说话别人听到的响度） */
  onLocalVolumeChange: (volume: number) => void;
  /** 自己：一键禁音/一键恢复（媒体层 toggleMic） */
  onToggleMic: () => void;
  /** 远端成员：一键静音/一键恢复（本地播放 locallyMuted） */
  onToggleMemberMuted: (userId: string) => void;
}) {
  const [user, setUser] = useState<UserPublic | null>(() => getCachedUser(member.user_id));
  // 自己的麦克风实时音量（0~1，未开麦为 0）——跳动条伸缩
  const localAudioLevel = useVoiceStore((s) => (isSelf ? s.localAudioLevel : 0));
  // 自己的麦克风音量设定（0~100，100 = 原始）
  const localVolume = useVoiceStore((s) => (isSelf ? s.localVolume : 100));
  // 自己的麦克风是否开启（媒体层事实，麦克风按钮状态）
  const micEnabled = useVoiceStore((s) => (isSelf ? s.micEnabled : true));

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
  const localSpeaking = localAudioLevel > 0.02;
  const remoteSpeaking = member.audioLevel > 0.02;

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
        <div className="voice-member-topline">
          <span className="voice-member-name">
            {displayName}
            {isSelf && <span className="voice-self-tag">我</span>}
          </span>
        </div>
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
      {/* 行尾统一操作区（所有成员行同一水平线）：开关按钮 + 音量条 */}
      <span className="voice-member-actions">
        {isSelf ? (
          <button
            type="button"
            className={`voice-meter-toggle ${micEnabled ? "" : "is-off"}`}
            onClick={onToggleMic}
            aria-pressed={micEnabled}
            aria-label={micEnabled ? "一键禁音" : "一键恢复"}
            title={micEnabled ? "一键禁音" : "一键恢复"}
          >
            {micEnabled ? <IconMic width={15} height={15} /> : <IconMicOff width={15} height={15} />}
          </button>
        ) : (
          <button
            type="button"
            className={`voice-meter-toggle ${member.locallyMuted ? "is-off" : ""}`}
            onClick={() => onToggleMemberMuted(member.user_id)}
            aria-pressed={member.locallyMuted}
            aria-label={`${displayName} ${member.locallyMuted ? "恢复声音" : "静音"}`}
            title={`${displayName} ${member.locallyMuted ? "恢复声音" : "静音"}`}
          >
            {member.locallyMuted ? (
              <IconSpeakerOff width={15} height={15} />
            ) : (
              <IconSpeaker width={15} height={15} />
            )}
          </button>
        )}
        {isSelf ? (
          <VoiceVolumeMeter
            volume={localVolume}
            level={localAudioLevel}
            speaking={localSpeaking}
            ariaLabel="我的麦克风音量"
            onVolumeChange={onLocalVolumeChange}
          />
        ) : (
          <VoiceVolumeMeter
            volume={member.volume}
            // 本地静音时跳动条归零（静音=不听他说话，说话跳动指示一并停）
            level={member.locallyMuted ? 0 : member.audioLevel}
            speaking={!member.locallyMuted && remoteSpeaking}
            ariaLabel={`${displayName} 的音量`}
            onVolumeChange={(v) => onVolumeChange(member.user_id, v)}
          />
        )}
      </span>
    </div>
  );
}
