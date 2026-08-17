import { useLocation, useNavigate } from "react-router-dom";
import { IconMic, IconVideo } from "../components/icons";
import { useSessionActivityStore, type ActivitySession } from "../stores/sessionActivity";

function statusLabel(status: string) {
  if (status === "connected") return "已连接";
  if (status === "reconnecting") return "重连中…";
  if (status === "connecting") return "连接中…";
  if (status === "failed") return "连接失败";
  return status;
}

function isActive(session: ActivitySession | null) {
  return session?.status === "connected" || session?.status === "reconnecting" || session?.status === "connecting";
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
  const voice = useSessionActivityStore((s) => s.voiceSession);
  const live = useSessionActivityStore((s) => s.liveSession);
  return (
    <>
      {isActive(voice) && pathname !== voice?.sourceRoute && <ActivityButton session={voice!} />}
      {isActive(live) && pathname !== live?.sourceRoute && <ActivityButton session={live!} />}
    </>
  );
}
