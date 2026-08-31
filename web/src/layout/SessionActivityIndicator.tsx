import { useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { IconMic, IconVideo } from "../components/icons";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { useAuthStore } from "../stores/auth";

/** 拖动判定阈值：pointer 位移超过该值视为拖动而非点击（px） */
const DRAG_THRESHOLD = 5;
/** 悬浮球控制组高度（球/把手均为 44px），用于 clamp 底部边界 */
const GROUP_HEIGHT = 44;
/** 组可拖到的视口边缘最小间距（px），避免被拖出屏幕外 */
const DRAG_MARGIN = 8;

/** 跨页面媒体会话的悬浮球控制组：语音 + 直播 + 收起把手三个按钮。点击收起：
 *  把手完整贴住屏幕右缘、语音/直播球滑出淡隐（CSS 动画）；再点把手恢复展开。
 *  把手支持上下拖动：pointer 位移超过 DRAG_THRESHOLD 即进入拖动，实时移动整组
 *  的固定 top（clamp 在视口内），拖动结束抑制随后的 click 以免误触收起/展开。 */
export function SessionActivityIndicator() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const storedVoice = useSessionActivityStore((s) => s.voiceSession);
  const storedLive = useSessionActivityStore((s) => s.liveSession);
  const currentUser = useAuthStore((s) => s.currentUser);
  const [collapsed, setCollapsed] = useState(false);
  // 用户拖动后的绝对 top（px）；null = 未拖动，走 CSS 默认（宽屏 80px / 窄屏 calc）
  const [topPx, setTopPx] = useState<number | null>(null);
  const groupRef = useRef<HTMLDivElement>(null);
  // 拖动会话：active=正在拖动；moved=位移已超阈值（判定为拖动而非点击）
  const dragRef = useRef({ active: false, moved: false, startClientY: 0, startTop: 0 });
  // 拖动结束后置 true，让随后触发的合成 click 只消费标记、不切换收起态
  const suppressClickRef = useRef(false);

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

  // 把手拖动：pointer down 记录起点与当前组 top，捕获指针以便移出把手仍能收到 move/up
  const onTogglePointerDown = (e: ReactPointerEvent<HTMLButtonElement>) => {
    // 仅主按键触发拖拽（鼠标左键）；触摸/触控笔无 button 概念，直接通过
    if (e.pointerType === "mouse" && e.button !== 0) return;
    const group = groupRef.current;
    if (!group) return;
    const el = e.currentTarget;
    if (typeof el.setPointerCapture === "function") {
      el.setPointerCapture(e.pointerId);
    }
    dragRef.current = {
      active: true,
      moved: false,
      startClientY: e.clientY,
      startTop: group.getBoundingClientRect().top,
    };
  };

  const onTogglePointerMove = (e: ReactPointerEvent<HTMLButtonElement>) => {
    const drag = dragRef.current;
    if (!drag.active) return;
    const dy = e.clientY - drag.startClientY;
    // 未超阈值前不判定为拖动，也不移动（保留点击语义）
    if (!drag.moved && Math.abs(dy) < DRAG_THRESHOLD) return;
    drag.moved = true;
    const maxTop = Math.max(DRAG_MARGIN, window.innerHeight - GROUP_HEIGHT - DRAG_MARGIN);
    const nextTop = Math.min(Math.max(drag.startTop + dy, DRAG_MARGIN), maxTop);
    setTopPx(nextTop);
  };

  const onTogglePointerUp = (e: ReactPointerEvent<HTMLButtonElement>) => {
    const drag = dragRef.current;
    if (!drag.active) return;
    drag.active = false;
    // 若本次是拖动（位移超阈值），抑制随后的合成 click，避免误触收起/展开
    suppressClickRef.current = drag.moved;
    if (typeof e.currentTarget.releasePointerCapture === "function") {
      e.currentTarget.releasePointerCapture(e.pointerId);
    }
  };

  const onToggleClick = () => {
    // 拖动结束后的合成 click：仅消费抑制标记，不切换收起态
    if (suppressClickRef.current) {
      suppressClickRef.current = false;
      return;
    }
    setCollapsed((v) => !v);
  };

  // 没有任何活动态时不渲染
  if (!showVoice && !showLive) return null;

  // 收起/展开共用同一结构：is-collapsed 驱动 CSS 向右半贴边滑出动画（shell.css）
  return (
    <div
      ref={groupRef}
      className={`session-activity-group${collapsed ? " is-collapsed" : ""}`}
      style={topPx != null ? { top: topPx } : undefined}
    >
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
        onClick={onToggleClick}
        onPointerDown={onTogglePointerDown}
        onPointerMove={onTogglePointerMove}
        onPointerUp={onTogglePointerUp}
        onPointerCancel={onTogglePointerUp}
        aria-label={collapsed ? "展开媒体控制" : "收起媒体控制"}
        aria-expanded={!collapsed}
      >
        <span className="session-activity-toggle-icon">›</span>
      </button>
    </div>
  );
}
