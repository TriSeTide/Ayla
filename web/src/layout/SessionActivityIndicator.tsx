import { useLocation, useNavigate } from "react-router-dom";
import { IconMic, IconVideo } from "../components/icons";
import { useSessionActivityStore, type ActivitySession } from "../stores/sessionActivity";
import { useAuthStore } from "../stores/auth";

function statusLabel(status: string) {
  if (status === "connected") return "已连接";
  if (status === "reconnecting") return "重连中…";
  if (status === "connecting") return "连接中…";
  if (status === "failed") return "连接失败";
  return status;
}

function ActivityButton({ session }: { session: ActivitySession }) {
  const navigate = useNavigate();
  const isVoice = session.kind === "voice";
  const target = session.sourceRoute || (isVoice ? "/voice" : `/live/start/${session.sessionId}`);
  return (
    <button
      type="button"
      className={`session-activity-indicator ${isVoice ? "is-voice" : "is-live"}`}
      onClick={() => navigate(target)}
      aria-label={`返回${isVoice ? "语音房" : "开播界面"}${session.title}`}
    >
      <span className="session-activity-icon">
        {isVoice ? <IconMic width={18} height={18} /> : <IconVideo width={18} height={18} />}
      </span>
      <span className="session-activity-copy">
        <strong>{session.title}</strong>
        <small>{statusLabel(session.status)} · 返回</small>
      </span>
    </button>
  );
}

/** 跨页面媒体会话的轻量回返入口；语音和直播各占独立浮层位置。 */
export function SessionActivityIndicator() {
  const { pathname } = useLocation();
  const storedVoice = useSessionActivityStore((s) => s.voiceSession);
  const storedLive = useSessionActivityStore((s) => s.liveSession);
  const currentUser = useAuthStore((s) => s.currentUser);
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
  return (
    <>
      {currentUser?.is_in_voice && voice && !onVoiceRoom && <ActivityButton session={voice} />}
      {currentUser?.is_live && live && !onLiveConsole && <ActivityButton session={live} />}
    </>
  );
}
