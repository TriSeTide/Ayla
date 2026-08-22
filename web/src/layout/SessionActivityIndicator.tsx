import { useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { IconMic, IconVideo } from "../components/icons";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { useAuthStore } from "../stores/auth";

/** 跨页面媒体会话的悬浮球控制组：语音 + 直播 + 收起把手三个按钮。点击收起：
 *  把手完整贴住屏幕右缘、语音/直播球滑出淡隐（CSS 动画）；再点把手恢复展开。 */
export function SessionActivityIndicator() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const storedVoice = useSessionActivityStore((s) => s.voiceSession);
  const storedLive = useSessionActivityStore((s) => s.liveSession);
  const currentUser = useAuthStore((s) => s.currentUser);
  const [collapsed, setCollapsed] = useState(false);

  const voiceId = currentUser?.is_in_voice && currentUser.voice_room_id != null
    ? String(currentUser.voice_room_id)
    : null;
  const liveId = currentUser?.is_live && currentUser.live_room_id != null
    ? String(currentUser.live_room_id)
    : null;

  const voice = voiceId
    ? storedVoice?.sessionId === voiceId
      ? storedVoice
      : {
          kind: "voice" as const,
          sessionId: voiceId,
          sourceRoute: `/voice/${voiceId}`,
          owner: currentUser?.id ?? null,
          title: "语音房",
          status: "connected" as const,
          lastError: null,
          updatedAt: "",
        }
    : null;
  const live = liveId
    ? storedLive?.sessionId === liveId
      ? storedLive
      : {
          kind: "live" as const,
          sessionId: liveId,
          sourceRoute: `/live/start/${liveId}`,
          owner: currentUser?.id ?? null,
          title: "直播间",
          status: "connected" as const,
          lastError: null,
          updatedAt: "",
        }
    : null;

  // 语音房使用明确的 /voice/:id 路由；群内语音则仍隐藏在加入时记录的群场景路由。
  const onVoiceRoom = Boolean(
    voice && currentUser?.is_in_voice && String(currentUser.voice_room_id) === voice.sessionId &&
      (pathname === `/voice/${voice.sessionId}` || pathname === voice.sourceRoute),
  );
  // 直播浮层只在对应开播控制台隐藏；进入任何普通直播间都必须显示。
  const onLiveConsole = Boolean(
    live && currentUser?.is_live && String(currentUser.live_room_id) === live.sessionId &&
      pathname === `/live/start/${live.sessionId}`,
  );

  const showVoice = currentUser?.is_in_voice && voice && !onVoiceRoom;
  const showLive = currentUser?.is_live && live && !onLiveConsole;

  // 没有任何活动态时不渲染
  if (!showVoice && !showLive) return null;

  // 收起/展开共用同一结构：is-collapsed 驱动 CSS 向右半贴边滑出动画（shell.css）
  return (
    <div className={`session-activity-group${collapsed ? " is-collapsed" : ""}`}>
      {showVoice && voice && (
        <button
          type="button"
          className="session-activity-ball is-voice"
          onClick={() => navigate(voice.sourceRoute || `/voice/${voice.sessionId}`)}
          aria-label="返回语音房"
          title={voice.title}
        >
          <IconMic width={20} height={20} />
        </button>
      )}
      {showLive && live && (
        <button
          type="button"
          className="session-activity-ball is-live"
          onClick={() => navigate(live.sourceRoute || `/live/start/${live.sessionId}`)}
          aria-label="返回直播间"
          title={live.title}
        >
          <IconVideo width={20} height={20} />
        </button>
      )}
      <button
        type="button"
        className="session-activity-toggle"
        onClick={() => setCollapsed((v) => !v)}
        aria-label={collapsed ? "展开媒体控制" : "收起媒体控制"}
        aria-expanded={!collapsed}
      >
        <span className="session-activity-toggle-icon">›</span>
      </button>
    </div>
  );
}
