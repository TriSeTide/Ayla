import { useNavigate, useLocation } from "react-router-dom";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { IconMic, IconVideo } from "../components/icons";

function statusLabel(status: string) {
  if (status === "connected") return "已连接";
  if (status === "reconnecting") return "重连中…";
  if (status === "connecting") return "连接中…";
  if (status === "failed") return "连接失败";
  return status;
}

/** 跨页面媒体会话的轻量回返入口；不拥有或销毁媒体资源。 */
export function SessionActivityIndicator() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const voice = useSessionActivityStore((s) => s.voiceSession);
  const live = useSessionActivityStore((s) => s.liveSession);
  const session = voice?.status === "connected" || voice?.status === "reconnecting" || voice?.status === "connecting"
    ? voice
    : live?.status === "connected" || live?.status === "reconnecting" || live?.status === "connecting"
      ? live
      : null;

  if (!session || pathname === session.sourceRoute) return null;
  const target = session.sourceRoute || (session.kind === "voice" ? "/voice" : `/live/${session.sessionId}`);
  return (
    <button
      type="button"
      className="session-activity-indicator"
      onClick={() => navigate(target)}
      aria-label={`返回${session.kind === "voice" ? "语音房" : "直播间"}${session.title}`}
    >
      <span className="session-activity-icon">{session.kind === "voice" ? <IconMic width={18} height={18} /> : <IconVideo width={18} height={18} />}</span>
      <span className="session-activity-copy">
        <strong>{session.title}</strong>
        <small>{statusLabel(session.status)} · 返回</small>
      </span>
    </button>
  );
}
